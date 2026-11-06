package platform_common

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:terminal"

import "common:base"

// Package platform_common (the folder is common/platform; client/platform already holds the name
// `platform`, and two packages of one name cannot be linked together).

// boot fills host from the operating system. It is called once, first thing in the
// entry packages' main (client/main, server/dedicated), which pass the host down; nothing
// else reads the process's start-up state. The strings are the process's own (they live
// as long as it does).
boot :: proc(host: ^base.Host) {
	host^ = {
		boot = {
			args = os.args[1:] if len(os.args) > 0 else nil,
			env = read_env(),
			pid = os.get_pid(),
			cpu_count = os.get_processor_core_count(),
			dirs = read_dirs(),
			machine = read_machine(),
		},
		clock = {
			thread_cpu_us = thread_cpu_us,
			ticks = ticks,
			profile_now = when_linux_profile_now(),
		},
		file = {lock = lock_file, unlock = unlock_file},
		output = {write = output_write, is_color = output_is_color},
		entropy = crypto.rand_bytes,
	}
	base.boot_install(host.boot)
	base.output_install(host.output)
	base.entropy_install(host.entropy)
	base.clock_install(host.clock)
	base.file_install(host.file)
}

@(private = "file")
stream_file :: proc "contextless" (stream: base.Output_Stream) -> ^os.File {
	return os.stdout if stream == .Out else os.stderr
}

@(private = "file")
output_write :: proc "contextless" (stream: base.Output_Stream, text: string) {
	context = runtime.default_context()
	os.write_string(stream_file(stream), text)
}

@(private = "file")
output_is_color :: proc "contextless" (stream: base.Output_Stream) -> bool {
	context = runtime.default_context()
	return terminal.color_enabled && terminal.is_terminal(stream_file(stream))
}

@(private = "file")
env_maybe :: proc(name: string) -> Maybe(string) {
	value, set := os.lookup_env(name, runtime.heap_allocator())
	return value if set else nil
}

@(private = "file")
env_string :: proc(name: string) -> string {
	return os.get_env(name, runtime.heap_allocator())
}

// read_env reads the variables the game cares about; the strings live as long as the process.
@(private = "file")
read_env :: proc() -> base.Env {
	return {
		validation = env_maybe("VX_VALIDATION"),
		packs = env_maybe("VX_PACKS"),
		settings = env_maybe("VX_SETTINGS"),
		saves = env_maybe("VX_SAVES"),
		state_dir = env_maybe("VX_STATE_DIR"),
		log_debug = env_string("VX_LOG") == "debug",
		break_on_error = env_string("VX_BREAK") == "1",
		pad_ignore = env_string("SDL_GAMECONTROLLER_IGNORE_DEVICES"),
		pad_ignore_except = env_string("SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT"),
	}
}

@(private = "file")
dir_or_empty :: proc(dir: string, err: os.Error) -> string {
	return dir if err == nil else ""
}

// read_dirs asks the OS for the folders once; the strings live as long as the process.
@(private = "file")
read_dirs :: proc() -> base.Dirs {
	a := runtime.heap_allocator() // not the context one: a test's tracking allocator would call it a leak
	exe, exe_err := os.get_executable_directory(a)
	data, data_err := os.user_data_dir(a)
	config, config_err := os.user_config_dir(a)
	home, home_err := os.user_home_dir(a)
	return {
		exe = dir_or_empty(exe, exe_err),
		data = dir_or_empty(data, data_err),
		config = dir_or_empty(config, config_err),
		home = dir_or_empty(home, home_err),
	}
}

// read_machine asks the OS what the machine is, once; the strings live as long as the process.
@(private = "file")
read_machine :: proc() -> base.Machine_Facts {
	cpu, cores, threads, os_name := machine_facts()
	return {cpu = cpu, cores = cores, threads = threads, os = os_name}
}

// when_linux_profile_now is the trace clock where the platform has one of its own (Linux
// reads CLOCK_MONOTONIC_RAW through libc, much cheaper than spall's system call); nil elsewhere.
@(private = "file")
when_linux_profile_now :: proc() -> proc "contextless" () -> u64 {
	when ODIN_OS == .Linux {return profile_now} else {return nil}
}
