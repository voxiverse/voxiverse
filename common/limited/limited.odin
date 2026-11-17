// Package limited runs a command under a time limit. The build driver's `test`
// uses it, and so does tests/ (which tests it): it is its own package so that
// both can.
package limited

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// COLLECTIONS: the `-collection:` flags every first-party `odin` run takes (see the driver's
// own comment in main.odin); here so tests/ can pass them to the fixtures it builds.
COLLECTIONS :: []string {
	"-collection:client=client",
	"-collection:server=server",
	"-collection:common=common",
	"-collection:games=games",
	"-collection:generated=build/generated",
}

Run_Result :: enum {
	Ok,
	Failed, // exited nonzero, or could not start
	Timed_Out,
	Interrupted, // a stop signal arrived: it stopped itself, or was killed with its children
}

// stop_requested is set from the signal handler (signal_posix.odin, signal_windows.odin)
// and read by run_parallel's loop, so a Ctrl-C costs the run its jobs, not the driver:
// without it the driver dies first and leaves what it started running.
@(private = "file")
stop_requested: b32

// request_stop is what the signal handler does. It is also how smoke tests the
// interruption path: the test runner has handlers of its own in that process, so a
// real signal there would stop the run instead of the job.
request_stop :: proc "contextless" () {
	intrinsics.atomic_store(&stop_requested, true)
}

// clear_stop forgets an interrupt; a real run never does.
clear_stop :: proc "contextless" () {
	intrinsics.atomic_store(&stop_requested, false)
}

// interrupted reports whether a stop signal has arrived.
interrupted :: proc "contextless" () -> bool {
	return intrinsics.atomic_load(&stop_requested) != false
}

// run_limited is run with a time limit: a command still going at the limit is killed
// together with everything it started.
run_limited :: proc(cmd: []string, limit: time.Duration) -> Run_Result {
	desc := os.Process_Desc {
		command = cmd,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("build: could not start '%s': %v", cmd[0], err)
		return .Failed
	}
	state, werr := os.process_wait(child, limit)
	if werr == nil {
		return .Ok if state.exited && state.exit_code == 0 else .Failed
	}
	kill_tree(child.pid)
	_, _ = os.process_wait(child, 30 * time.Second) // a process the OS is still tearing down (a crash report) is not waited for forever
	return .Timed_Out
}

// capture executes cmd and returns its stdout; ok is false if it failed or
// couldn't start (silently: callers decide whether that is an error).
capture :: proc(cmd: []string) -> (output: string, ok: bool) {
	state, stdout, stderr, err := exec(os.Process_Desc{command = cmd}, context.allocator)
	delete(stderr)
	if err != nil {return "", false}
	return string(stdout), state.exited && state.exit_code == 0
}

// exec runs desc to its end and returns what it wrote to stdout and stderr, as
// os.process_exec does, without its lost output: process_exec stops reading a pipe
// when poll says the writer hung up and nothing waits, but Linux polls a pipe without
// a lock, so a child that writes and exits between the two looks (now and then, under
// load) like one that wrote nothing: `git tag --list` exited 0 and its tags were never
// read. Here a hang-up is read too, until the read itself says the pipe is empty.
// When stop is given and becomes true while it runs, the child is killed with its
// children (it then ends as a failure). hidden: no console window for it on Windows (a
// windowed program's child: start_hidden).
exec :: proc(
	desc: os.Process_Desc,
	allocator := context.allocator,
	stop: ^b32 = nil,
	hidden := false,
) -> (
	state: os.Process_State,
	stdout, stderr: []u8,
	err: os.Error,
) {
	assert(desc.stdout == nil && desc.stderr == nil, "exec captures stdout and stderr")
	out_r, out_w := os.pipe() or_return
	defer os.close(out_r)
	err_r, err_w := os.pipe() or_return
	defer os.close(err_r)
	child: os.Process
	{
		defer os.close(out_w)
		defer os.close(err_w)
		d := desc
		d.stdout, d.stderr = out_w, err_w
		if hidden {
			child = start_hidden(d) or_return
		} else {
			child = os.process_start(d) or_return
		}
	}
	out := make([dynamic]u8, allocator)
	errs := make([dynamic]u8, allocator)
	Pipe :: struct {
		r:    ^os.File,
		into: ^[dynamic]u8,
		done: bool,
	}
	pipes := [2]Pipe{{out_r, &out, false}, {err_r, &errs, false}}
	buf: [4096]u8
	killed := false
	for !pipes[0].done || !pipes[1].done {
		if stop != nil && !killed && intrinsics.atomic_load(stop) {
			kill_tree(child.pid) // (its pipes close: the loop reads to their end)
			killed = true
		}
		read_any := false
		for &p in pipes {
			if p.done {continue}
			// (true: data; Broken_Pipe: the writer hung up, but data may still wait)
			has, perr := os.pipe_has_data(p.r)
			if !has && perr == nil {continue}
			n, rerr := os.read(p.r, buf[:])
			if n > 0 {append(p.into, ..buf[:n])}
			if rerr != nil {p.done = true} 	// EOF: every writer closed and nothing left
			read_any = true
		}
		if !read_any {time.sleep(time.Millisecond)}
	}
	state, err = os.process_wait(child)
	return state, out[:], errs[:], err
}

// command_line: args as one Windows command line, which the C runtime's parsing (and
// CommandLineToArgvW) splits back into the same arguments: an argument with a space, a
// tab or a quote (or none) is quoted, its quotes escaped, and the backslashes before a
// quote, the closing one included, doubled (start_hidden's; os.process_start has its own).
command_line :: proc(args: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for arg, i in args {
		if i > 0 {strings.write_byte(&b, ' ')}
		if arg != "" && !strings.contains_any(arg, " \t\"") {
			strings.write_string(&b, arg)
			continue
		}
		strings.write_byte(&b, '"')
		backslashes := 0
		for c in transmute([]u8)arg {
			switch c {
			case '\\':
				backslashes += 1
			case '"':
				for _ in 0 ..< 2 * backslashes + 1 {strings.write_byte(&b, '\\')}
				strings.write_byte(&b, '"')
				backslashes = 0
			case:
				for _ in 0 ..< backslashes {strings.write_byte(&b, '\\')}
				strings.write_byte(&b, c)
				backslashes = 0
			}
		}
		for _ in 0 ..< 2 * backslashes {strings.write_byte(&b, '\\')}
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// start starts cmd and does not wait for it: a program that goes on after this one
// ends (the game restarting into its update). Its standard streams go nowhere.
start :: proc(cmd: []string) -> bool {
	_, err := os.process_start(os.Process_Desc{command = cmd})
	if err != nil {
		fmt.eprintfln("could not start '%s': %v", cmd[0], err)
		return false
	}
	return true
}

// Job is one command of run_parallel's.
Job :: struct {
	cmd:       []string,
	limit:     time.Duration, // killed with its children at this (0: no limit)
	log:       string, // its stdout and stderr until it ends (a file run_parallel overwrites)
	errors:    string, // its stderr instead, when set
	quiet:     bool, // its log is not printed (the caller reads it)
	poll:      proc(data: rawptr), // when set, called with poll_data about every 10 ms while the job runs, and once more when it has ended
	poll_data: rawptr,
	status:    ^int, // when set, told the exit status the job ended with (on POSIX a kill is its signal number; -1: none, it was killed at its limit or never started)
}

// Job_Done is told each job's end, in the order they end, after its output is printed.
Job_Done :: #type proc(data: rawptr, index: int, result: Run_Result, seconds: f64)

// run_parallel runs jobs, at most width at once, starting them in the order given. A
// job's output goes to its log and is printed whole when it ends, so no two
// interleave; then done hears of it. results[i] is jobs[i]'s. A stop request (a
// signal, see install_stop_signals) kills what is running, children and all: each of
// those is reported Interrupted to done, and every job not yet started is Interrupted.
run_parallel :: proc(
	jobs: []Job,
	width: int,
	done: Job_Done = nil,
	data: rawptr = nil,
	allocator := context.allocator,
) -> (
	results: []Run_Result,
) {
	Running :: struct {
		index:   int,
		process: os.Process,
		started: time.Tick,
	}
	results = make([]Run_Result, len(jobs), allocator)
	running := make([dynamic]Running, context.temp_allocator)
	next := 0
	for next < len(jobs) || len(running) > 0 {
		if interrupted() {
			for r in running {kill_tree(r.process.pid)}
			for r in running {
				_, _ = os.process_wait(r.process)
				results[r.index] = .Interrupted
				if done != nil {
					done(
						data,
						r.index,
						.Interrupted,
						time.duration_seconds(time.tick_since(r.started)),
					)
				}
			}
			for i in next ..< len(jobs) {results[i] = .Interrupted}
			break
		}
		for next < len(jobs) && len(running) < max(width, 1) {
			job := jobs[next]
			if job.status != nil {job.status^ = -1}
			if p, ok := job_start(job); ok {
				append(&running, Running{next, p, time.tick_now()})
			} else {
				results[next] = .Failed
				job_finish(job)
				if done != nil {done(data, next, .Failed, 0)}
			}
			next += 1
		}
		ended := false
		for i := 0; i < len(running); i += 1 {
			r := running[i]
			job := jobs[r.index]
			result: Run_Result
			if job.poll != nil {job.poll(job.poll_data)}
			state, werr := os.process_wait(r.process, 0)
			if job.status != nil {job.status^ = state.exit_code if werr == nil else -1}
			if werr == nil {
				result = .Ok if state.exited && state.exit_code == 0 else .Failed
			} else if job.limit > 0 && time.tick_since(r.started) > job.limit {
				kill_tree(r.process.pid)
				_, _ = os.process_wait(r.process)
				result = .Timed_Out
			} else {
				continue
			}
			results[r.index] = result
			job_finish(job)
			if job.poll != nil {job.poll(job.poll_data)}
			if done != nil {
				done(data, r.index, result, time.duration_seconds(time.tick_since(r.started)))
			}
			unordered_remove(&running, i)
			i -= 1
			ended = true
		}
		if !ended && len(running) > 0 {time.sleep(10 * time.Millisecond)}
	}
	return
}

// job_start starts job with its output in its log.
@(private = "file")
job_start :: proc(job: Job) -> (os.Process, bool) {
	// Windows hands a child only the handles opened inheritable: without it the job's
	// output went nowhere there (every file "needed formatting"). Elsewhere the handle
	// is copied onto the child's stdout, so the flag is left off.
	flags := os.File_Flags{.Write, .Create, .Trunc}
	when ODIN_OS == .Windows {flags += {.Inheritable}}
	out, err := os.open(job.log, flags)
	if err != nil {
		fmt.eprintfln("build: could not write '%s': %v", job.log, err)
		return {}, false
	}
	defer os.close(out)
	errors := out
	if job.errors != "" {
		errors, err = os.open(job.errors, flags)
		if err != nil {
			fmt.eprintfln("build: could not write '%s': %v", job.errors, err)
			return {}, false
		}
	}
	// (Closed once the child has its copies; a defer inside the `if` would close it
	// before the start.)
	defer if errors != out {os.close(errors)}
	child, serr := os.process_start(
		os.Process_Desc{command = job.cmd, stdout = out, stderr = errors},
	)
	if serr != nil {
		fmt.eprintfln("build: could not start '%s': %v", job.cmd[0], serr)
		return {}, false
	}
	return child, true
}

// job_finish prints a finished job's log (and errors) in one piece, unless it is quiet.
@(private = "file")
job_finish :: proc(job: Job) {
	if job.quiet {return}
	for path in ([]string{job.log, job.errors}) {
		if path == "" {continue}
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err == nil && len(data) > 0 {os.write(os.stdout, data)}
	}
}
