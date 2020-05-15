module JSON = Yojson.Basic
module OPAM = OpamFile.OPAM
module Version = OpamPackage.Version
module Name = OpamPackage.Name
open Util

let getenv k =
	try Unix.getenv k
	with Not_found as e ->
		Printf.eprintf "Missing environment variable: %s\n" k;
		raise e

type env = {
	vars : Vars.env;
	opam : OpamFile.OPAM.t;
	opam_src: [`File of string | `Dir of string];
	pkgname : Name.t;
}

let string_of_dir = OpamFilename.Dir.to_string

let destDir () = OpamFilename.Dir.of_string (getenv "out")

let binDir dest =
	let open OpamFilename.Op in
	dest / "bin"

let assert_string_var = let open OpamVariable in function
	| Some (S s) -> s
	| other -> failwith ("Expected string, got " ^ (Option.to_string string_of_variable_contents other))

let vardir ~vars ~dest name =
	Vars.path_var ~env:vars ~prefix:dest ~scope:None name |> assert_string_var
		|> OpamFilename.Dir.of_string

let outputDirs ~vars dest = [ binDir dest; vardir ~vars ~dest "stublibs"; vardir ~vars ~dest "lib" ]

let opam_path = function
	| `File path -> path
	| `Dir path -> Filename.concat path "opam"

let opam_file_path src name =
	match src with
	| `File _ -> None
	| `Dir path -> Some (Filename.concat path name)

let unexpected_json desc j =
	failwith ("Unexpected " ^ desc ^ ": " ^ (JSON.to_string j))

let load_env () =
	let open Vars in
	let destDir = destDir () in
	let self_name = ref None in
	let self_version = ref None in
	let packages = ref Name.Map.empty in

	let add_package name impl =
		debug " - package %s: %s\n" name (match impl with
			| Absent -> "absent"
			| Provided -> "provided"
			| Installed { path; version } ->
				Printf.sprintf "%s (%s)"
					(Option.to_string string_of_dir path)
					(Option.to_string Version.to_string version)
		);
		packages := Name.Map.add (Name.of_string name) impl !packages
	in

	let json = JSON.from_string (getenv "opamEnv") in
	(* TODO when we can use structuredAttrs *)
	(* let json = JSON.from_file ".attrs.json" |> JSON.Util.member "opamEnv" in *)
	debug "Using opamEnv: %s\n" (JSON.to_string json);
	let () = match json with
		| `Assoc pairs -> begin
			pairs |> List.iter (function
					| "deps", `Assoc (attrs) -> begin
						debug "adding packages from opamEnv\n";
						attrs |> List.iter (fun (pkgname, value) ->
							match value with
								| `Null -> add_package pkgname Absent

									(* Bool is used for base packages, which have no corresponding path *)
								| `Bool b -> add_package pkgname (if b then Provided else Absent)

								| `Assoc attrs -> (
									let path = ref None in
									let version = ref None in
									attrs |> List.iter (fun (key, value) ->
										match (key, value) with
											| "path", `String value -> path := Some value
											| "version", `String value -> version := Some (Version.of_string value)
											| "version", `Null -> version := None
											| _, other -> unexpected_json ("deps." ^ pkgname) other
									);
									add_package pkgname (Installed {
										(* path is optional in the type, but by `invoke` time all paths
										 * should be defined *)
										path = Some (!path
											|> Option.or_failwith "missing `path` in deps"
											|> OpamFilename.Dir.of_string);
										version = !version;
									})
								)

								| other -> unexpected_json "deps value" other
						)
					end
					| "deps", other -> unexpected_json "deps" other

					| "name", `String name -> self_name := Some name;
					| "name", other -> unexpected_json "name" other

					| "version", `String version -> self_version := Some (Version.of_string version);
					| "version", other -> unexpected_json "version" other

					| other, _ -> failwith ("unexpected opamEnv key: " ^ other)
			)
		end
		| other -> unexpected_json "toplevel" other
	in

	let self_opam_src = let path = Unix.getenv "opamSrc" in
		if Sys.is_directory path then (`Dir path) else (`File path) in
	let self = !self_name |> Option.or_failwith "self name not specified" |> Name.of_string in
	let self_impl = Vars.{
		path = Some destDir;
		version = Some (!self_version |> Option.or_failwith "self version not specified");
	} in
	let ocaml_version =
		(match Name.Map.find (Name.of_string "ocaml") !packages with
			| Installed impl -> impl.version
			| _other -> None
		) |> Option.or_failwith "ocaml version not provided"
	in
	let opam =
		let path = opam_path self_opam_src in
		Printf.eprintf "Loading %s\n" path;
		Opam_metadata.load_opam path
	in
	{
		vars = Vars.({
			ocaml_version;
			prefix = Some destDir;
			packages = !packages |> Name.Map.add self (Installed self_impl);
			self = self;
			vars = Opam_metadata.init_variables ();
		});
		pkgname = self;
		opam_src = self_opam_src;
		opam;
	}

let resolve commands vars =
	commands |> OpamFilter.commands (Vars.lookup vars)

let run env get_commands =
	let commands = resolve (get_commands env.opam) env.vars in
	commands |> List.iter (fun args ->
		match args with
			| [] -> ()
			| _ :: _ -> (
				let quit code = prerr_endline "Command failed."; exit code in
				match Lwt_main.run (Cmd.run_unit_result Cmd.exec_none args) with
					| Ok () -> ()
					| Error (`command_failed (Some code, _)) -> quit code
					| Error (`command_failed (None, _)) -> quit 1
			)
	)

let ensure_dir_exists d =
	if not (OpamFilename.exists_dir d) then (
		Printf.eprintf "creating %s\n" (OpamFilename.Dir.to_string d);
		OpamFilename.mkdir d;
	)

let remove_empty_dir d =
	if OpamFilename.dir_is_empty d then (
		Printf.eprintf "removing empty dir %s\n" (OpamFilename.Dir.to_string d);
		OpamFilename.rmdir d;
	)

let execute_install_file env =
	let name = env.pkgname in
	let install_file_path = (Name.to_string name ^ ".install") in
	if (Sys.file_exists install_file_path) then (
		prerr_endline ("Installing from " ^ install_file_path);
		let dest = destDir () in
		Lwt_main.run (Cmd.run_unit_exn Cmd.exec_none ~print:true [ "opam-installer";
			"--prefix"; string_of_dir dest;
			"--libdir"; vardir ~vars:env.vars ~dest "lib" |> string_of_dir;
			install_file_path ]
		)
	) else (
		prerr_endline "no .install file found!";
	)

let fixup_lib_dir ~dest env =
	(* Some packages assume $out/lib, even though opam and findlib
	 * have lib set to $out/lib/ocaml/$OCAML_VERSION/site-lib.
	 * It's tedious to fix up all the packages, so just massage
	 * any package which installs directly into lib/.
	 *)
	let open OpamFilename.Op in
	let name = env.pkgname |> Name.to_string in
	let lib_base = dest / "lib" in
	let incorrect_lib_dest = lib_base / name in

	let lib_dir = vardir ~vars:env.vars ~dest "lib" in
	let expected_lib_dest = lib_dir / name in

	let expected_s = OpamFilename.Dir.to_string expected_lib_dest in
	let incorrect_s = OpamFilename.Dir.to_string incorrect_lib_dest in
	(* awkward prefix check removes the false positive for the `ocaml` library,
	 * since lib/ocaml looks like a bad path _and_ nothing gets installed into
	 * lib/ocaml/version/site-lib/ocaml *)
	if not (OpamStd.String.starts_with ~prefix:incorrect_s expected_s) then (
		if not (OpamFilename.exists_dir expected_lib_dest) then (
			Printf.eprintf "expected libdir %s is not present, checking for faulty install in %s...\n"
				expected_s incorrect_s;
			if (OpamFilename.exists_dir incorrect_lib_dest) then (
				Printf.eprintf "found! moving %s -> %s\n" incorrect_s expected_s;
				OpamFilename.move_dir ~src:incorrect_lib_dest ~dst:expected_lib_dest
			)
		)
	)

let isdir path =
	let open Unix in
	try (stat path).st_kind = S_DIR
	with Unix_error(ENOENT, _, _) -> false

let apply_patches env =
	(* extracted from OpamAction.prepare_package_build *)
	let opam = env.opam in
	let filter_env = Vars.lookup env.vars in

	let patches = OpamFile.OPAM.patches opam in

	let subst_patches, subst_others =
	List.partition (fun f -> List.mem_assq f patches)
		(OpamFile.OPAM.substs opam)
	in

	let apply_substs path =
		Printf.eprintf "Applying substitutions to: %s\n" (OpamFilename.Base.to_string path);
		OpamFilter.expand_interpolations_in_file (filter_env) path
	in

	let iter_patches f =
		List.fold_left (fun acc (base, filter) ->
			let fail e =
				OpamStd.Exn.fatal e;
				OpamFilename.Base.to_string base :: acc
			in
			let filename_str = (OpamFilename.Base.to_string base) in
			if OpamFilter.opt_eval_to_bool (filter_env) filter
			then (
				Printf.eprintf "applying patch: %s\n" filename_str;
				if List.mem base subst_patches
					then apply_substs base;
				let result = try f filename_str with e -> Some e in
				match result with
					| Some (e: exn) -> fail e
					| None -> acc
				)
			else (
				Printf.eprintf "skipping patch: %s\n" filename_str;
				acc
			)
		) [] patches in

	(* Apply the patches *)
	let patching_errors =
		iter_patches (fun filename ->
			OpamSystem.patch ~dir:(Sys.getcwd ()) filename |> OpamProcess.Job.run
		)
	in

	if patching_errors <> [] then (
		let msg =
			Printf.sprintf "These patches didn't apply:\n%s"
				(OpamStd.Format.itemize (fun x -> x) patching_errors)
		in
		failwith msg
	);

	(* Apply remaining substitutions *)
	List.iter apply_substs subst_others

let patch env =
	(* copy all files into ./ if present *)
	opam_file_path env.opam_src "files"
		|> Option.filter Sys.file_exists
		|> Option.may (fun files_path ->
		let contents = Sys.readdir files_path
			|> Array.map (Filename.concat files_path) in
		Lwt_main.run (Cmd.(run_unit_exn exec_none) (List.concat [
			[ "cp"; "-r"; "--no-preserve=mode"; "--dereference" ];
			Array.to_list contents;
			[ "./" ]
                ])
                );
                Lwt_main.run (Cmd.(run_unit_exn exec_none) (["chmod"; "-R"; "+w"; "."]))
	);
	apply_patches env

let build env =
	let dest = destDir () in
	ensure_dir_exists dest;
	outputDirs ~vars:env.vars dest |> List.iter ensure_dir_exists;
	run env OPAM.build

let install env =
	run env OPAM.install;
	execute_install_file env;
	let dest = destDir () in
	fixup_lib_dir ~dest env;
	outputDirs ~vars:env.vars dest |> List.iter remove_empty_dir

let dump env =
	let dump desc get_commands =
		let commands = resolve (get_commands env.opam) env.vars in
		Printf.printf "# %s:\n" desc;
		commands |> List.iter (fun args ->
			Printf.printf "+ %s\n" (String.concat " " args)
		)
	in
	dump "build" OPAM.build;
	dump "install" OPAM.install

let main idx args =
	let action = try Some (Array.get args (idx+1)) with Not_found -> None in
	let action = match action with
		| Some "patch" -> patch
		| Some "build" -> build
		| Some "install"-> install
		| Some "dump"-> dump
		| Some other -> failwith ("Unknown action: " ^ other)
		| None -> failwith "No action given"
	in
	Unix.putenv "PREFIX" (destDir () |> OpamFilename.Dir.to_string);
	action (load_env ())

