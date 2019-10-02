module Types = struct
	type command_failed = Command_failed of (int option * string)
	type fd_spec = Inherit | Pipe | Fd of Unix.file_descr | DevNull
	type process = {
		stdin:  (Unix.file_descr, string) result;
		stdout: (Unix.file_descr, string) result;
		stderr: (Unix.file_descr, string) result;
	}
end
open Types

let string_of_command_failed (Command_failed (_, desc)) = desc ^ " failed"

module Internal = struct
	let chunk_stream fd =
		let len = 1024 in
		Stream.from (fun _ ->
			let buf = Bytes.create len in
			try
				match Unix.read fd buf 0 len with
					| 0 -> None
					| bytes_read -> Some (Bytes.sub buf 0 bytes_read)
			with Unix.Unix_error (Unix.EINTR, _, _) -> None (* TODO correct? *)
		)
	
	type bg_collector = {
		_th: Thread.t;
		_result: string ref;
	}

	let rec waitpid_with_retry flags pid =
		let open Unix in
		try waitpid flags pid
		with Unix_error (EINTR, _, _) -> waitpid_with_retry flags pid

	let pid_result ~desc pid =
		match waitpid_with_retry [ WUNTRACED ] pid with
			| (_pid, WEXITED 0) -> Ok ()
			| (_pid, WEXITED n) -> Error (Command_failed (Some n, desc))
			| (_pid, _) -> Error (Command_failed (None, desc))

	let print_desc ~print cmd: string =
		let desc = String.concat " " cmd in
		if print || Util.verbose () then prerr_endline (" + " ^ desc);
		desc

	let assert_success result = match result with
		| Ok x -> x
		| Error e -> failwith (string_of_command_failed e)
end

let join_result out = function
	| Ok () -> Ok out
	| Error e -> Error e

let join_exn out = function
	| Ok () -> out
	| Error e -> failwith (string_of_command_failed e)

let join_opt result = function
	| Ok () -> Some result
	| Error _ -> None

let join_success_bool () = function
	| Ok () -> true
	| Error _ -> false

let assert_fd : (Unix.file_descr, string) result -> Unix.file_descr = function
	| Ok fd -> fd
	| Error msg -> failwith msg

let file_contents fd =
	let buf = ref Bytes.empty in
	Internal.chunk_stream fd |> Stream.iter (fun chunk -> buf := Bytes.cat !buf chunk);
	Bytes.to_string !buf |> String.trim

let stdout_contents proc =
	file_contents (proc.stdout |> assert_fd)

let file_contents_in_bg fd =
	let result = ref "" in
	let thread = Thread.create (fun () ->
		result := file_contents fd
	) () in
	Internal.({ _th = thread; _result = result })

let join_bg bg =
	let open Internal in
	Thread.join bg._th;
	!(bg._result)

let run (type block_ret) (type ret)
	?(print=true)
	?(stdin=Inherit)
	?(stdout=Inherit)
	?(stderr=Inherit)
	~(join: block_ret -> (unit, command_failed) result -> ret)
	~(block: process -> block_ret)
	(cmd: string list)
	: ret =
	let desc = Internal.print_desc ~print cmd in
	let no_fd name : (Unix.file_descr, string) result = Error
		(Printf.sprintf "%s of process %s is not a pipe" name desc) in

	let close_after_fork = ref [] in
	let close_finally = ref [] in
	let prefix ref fd = ref := fd :: !ref in

	let mkfd name (inherited:Unix.file_descr) (spec:fd_spec) = match spec with
		| Inherit -> (inherited, no_fd name)
		| DevNull when Util.verbose () -> (inherited, no_fd name)
		| Pipe ->
			let (r,w) = Unix.pipe ~cloexec:true () in
			if inherited == Unix.stdin
				then (
					prefix close_after_fork r;
					(r, Ok w)
				)
				else (
					prefix close_after_fork w;
					(w, Ok r)
				)
		| Fd fd ->
				(* assume passed FDs assume ownership, and should not outlive the process *)
				prefix close_finally fd;
				(fd, no_fd name)
		| DevNull ->
			let fd = Unix.openfile "/dev/null" [ O_RDWR] 0600 in
			prefix close_after_fork fd;
			(fd, no_fd name)
	in
	let (stdin_fd, proc_stdin) = mkfd "stdin" Unix.stdin stdin in
	let (stdout_fd, proc_stdout) = mkfd "stdout" Unix.stdout stdout in
	let (stderr_fd, proc_stderr) = mkfd "stderr" Unix.stderr stderr in
	let process = {
		stdin = proc_stdin;
		stdout = proc_stdout;
		stderr = proc_stderr;
	} in
	let cleanup ref =
		let fds = !ref in
		ref := [];
		fds |> List.iter Unix.close
	in
	try
		let pid = Unix.create_process (List.hd cmd) (Array.of_list cmd) stdin_fd stdout_fd stderr_fd in
		cleanup close_after_fork;
		let block_result = block process in
		let pid_result = Internal.pid_result ~desc pid in
		let result = join block_result pid_result in
		cleanup close_finally;
		result
	with e -> (
		cleanup close_after_fork;
		cleanup close_finally;
		raise e
	)

(* Handy shortcuts *)
let run_exn = run ~join:join_exn

let run_unit = run ~block:ignore
let run_unit_exn = run_unit ~join:join_exn
let run_unit_result = run_unit ~join:join_result

let run_output = run ~stdout:Pipe ~block:stdout_contents
let run_output_exn = run_output ~join:join_exn
let run_output_result = run_output ~join:join_result
let run_output_opt = run_output ~join:join_opt