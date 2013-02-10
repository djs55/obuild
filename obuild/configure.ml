open Ext
open Helper
open Types
open Printf
open Filepath
open Gconf

exception ConfigChanged of string

let set_lib_profiling v () = gconf.conf_library_profiling <- v
let set_lib_debugging v () = gconf.conf_library_debugging <- v
let set_exe_profiling v () = gconf.conf_executable_profiling <- v
let set_exe_debugging v () = gconf.conf_executable_debugging <- v
let set_lib_native v () = gconf.conf_library_native <- v
let set_lib_bytecode v () = gconf.conf_library_bytecode <- v
let set_exe_native v () = gconf.conf_executable_native <- v
let set_exe_bytecode v () = gconf.conf_executable_bytecode <- v
let set_exe_as_obj v () = gconf.conf_executable_as_obj <- v

let set_build_examples v () = gconf.conf_build_examples <- v
let set_build_tests v () = gconf.conf_build_tests <- v
let set_build_benchs v () = gconf.conf_build_benchs <- v

let getDigestKV () =
    let digest = Project.digest () in
    [ ("obuild-digest", digest) ]

let generateMlFile project file flags =
    Utils.generateFile file (fun add ->
        add "(* autogenerated file by obuild. do not modify *)\n";
        add (sprintf "let project_version = \"%s\"\n" project.Analyze.project_file.Project.version);
        (* TODO escape name properly *)
        List.iter (fun (name, v) -> add (sprintf "let project_flag_%s = %b\n" name v)) flags;
    )

let generateCFile project file flags =
    Utils.generateFile file (fun add ->
        add "/* autogenerated file by obuild. do not modify */\n";
        add (sprintf "#define PROJECT_VERSION \"%s\"\n" project.Analyze.project_file.Project.version);
        (* TODO escape name properly *)
        List.iter (fun (name, v) ->
            add (sprintf "#define PROJECT_FLAG_%s %d\n" (String.uppercase name) (if v then 1 else 0))
        ) flags;
    )

let makeSetup digestKV project = hashtbl_fromList
    ( digestKV
    @ hashtbl_toList project.Analyze.project_ocamlcfg
    @ [ ("executable-profiling", string_of_bool gconf.conf_executable_profiling)
      ; ("executable-debugging", string_of_bool gconf.conf_executable_debugging)
      ; ("executable-native", string_of_bool gconf.conf_executable_native)
      ; ("executable-bytecode", string_of_bool gconf.conf_executable_bytecode)
      ; ("library-profiling", string_of_bool gconf.conf_library_profiling)
      ; ("library-debugging", string_of_bool gconf.conf_library_debugging)
      ; ("library-native", string_of_bool gconf.conf_library_native)
      ; ("library-bytecode", string_of_bool gconf.conf_library_bytecode)
      ; ("executable-as-obj", string_of_bool gconf.conf_executable_as_obj)
      ; ("build-benchs", string_of_bool gconf.conf_build_benchs)
      ; ("build-tests", string_of_bool gconf.conf_build_tests)
      ; ("build-examples", string_of_bool gconf.conf_build_examples)
      ]
    @ List.map (fun (flagname,flagval) -> ("flag-" ^ flagname, string_of_bool flagval)) gconf.conf_user_flags
    )

let sanityCheck setup =
    let (_: string) = Prog.getOcamlOpt () in
    let (_: string) = Prog.getOcamlC () in
    let (_: string) = Prog.getOcamlDep () in
    ()

let comparekvs reason setup l =
    List.iter (fun (k,v) ->
        try
            let v' = Hashtbl.find setup k in
            if v' <> v then
                raise (ConfigChanged reason)
        with Not_found ->
            raise (ConfigChanged reason)
    ) l

let comparekvs_hashtbl reason setup l =
    Hashtbl.iter (fun k v ->
        try
            let v' = Hashtbl.find setup k in
            if v' <> v then
                raise (ConfigChanged reason)
        with Not_found ->
            raise (ConfigChanged reason)
    ) l

let run projFile tweakFlags =
    Dist.checkOrCreate ();
    let digestKV = getDigestKV () in

    let flagsVal =
        List.map (fun flag ->
            let name = flag.Project.flag_name in
            let def  = flag.Project.flag_default in

            let override = ref None in
            List.iter (fun tw ->
                match tw with
                | ClearFlag s -> if s = name then override := Some false
                | SetFlag   s -> if s = name then override := Some true
            ) tweakFlags;

            match (!override, def) with
            | (None, None)   -> (name, false)
            | (None, Some v) -> (name, v)
            | (Some v, _)    -> (name, v)
        ) projFile.Project.flags
        in
    verbose Debug "  configure flag: [%s]\n" (Utils.showList "," (fun (n,v) -> n^"="^string_of_bool v) flagsVal);
    gconf.conf_user_flags <- flagsVal;

    let project = Analyze.prepare projFile in

    let currentSetup = makeSetup digestKV project in
    let actualSetup = try Some (Dist.read_setup ()) with _ -> None in
    let projectSystemChanged =
        match actualSetup with
        | None     -> true
        | Some stp ->
            (* TODO harcoded for now till we do all the checks. *)
            try comparekvs "setup" stp (hashtbl_toList currentSetup); (* FORCED should be false *) true
            with _ -> true
        in

    if projectSystemChanged then (
        (* write setup file *)
        verbose Verbose "configuration changed, deleting dist\n%!";
        Filesystem.removeDirContent (Dist.getDistPath ());

        verbose Verbose "Writing new setup\n%!";
        Dist.write_setup currentSetup;

        verbose Verbose "auto-generating configuration files\n%!";
        let autogenDir = Dist.createBuildDest Dist.Autogen in
        generateMlFile project (autogenDir </> fn "path_generated.ml") flagsVal;
        generateCFile project (autogenDir </> fn "obuild_macros.h") flagsVal;
    )

exception ConfigurationMissingKey of string
exception ConfigurationTypeMismatch of string * string * string

let check () =
    Dist.checkOrFail ();

    let setup = Dist.read_setup () in
    let ocamlCfg = Prog.getOcamlConfig () in
    let digestKV = getDigestKV () in

    comparekvs "digest" setup digestKV;
    comparekvs_hashtbl "ocaml config" setup ocamlCfg;

    let get_opt k =
        try Hashtbl.find setup k
        with Not_found -> raise (ConfigurationMissingKey k)
        in
    let bool_of_opt k =
        let v = get_opt k in
        try bool_of_string v
        with Failure _ -> raise (ConfigurationTypeMismatch (k,"bool",v))
        in

    Hashtbl.iter (fun k v ->
        if string_startswith "flag-" k then
            gconf.conf_user_flags <- (string_drop 5 k, bool_of_string v) :: gconf.conf_user_flags
    ) setup;

    (* load the environment *)
    set_lib_profiling (bool_of_opt "library-profiling") ();
    set_lib_debugging (bool_of_opt "library-debugging") ();
    set_lib_native (bool_of_opt "library-native") ();
    set_lib_bytecode (bool_of_opt "library-bytecode") ();

    set_exe_profiling (bool_of_opt "executable-profiling") ();
    set_exe_debugging (bool_of_opt "executable-debugging") ();
    set_exe_native (bool_of_opt "executable-native") ();
    set_exe_bytecode (bool_of_opt "executable-bytecode") ();

    set_exe_as_obj (bool_of_opt "executable-as-obj") ();

    set_build_examples (bool_of_opt "build-examples") ();
    set_build_benchs (bool_of_opt "build-benchs") ();
    set_build_tests (bool_of_opt "build-tests") ();

    let ver = string_split '.' (Hashtbl.find ocamlCfg "version") in
    (match ver with
    | major::minor::_-> if int_of_string major < 4 then gconf.conf_bin_annot <- false
    | _              -> gconf.conf_bin_annot <- false
    );

    ()