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
		},
		output = {write = output_write, is_color = output_is_color},
		entropy = crypto.rand_bytes,
	}
	base.boot_install(host.boot)
	base.output_install(host.output)
	base.entropy_install(host.entropy)
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
	value, set := os.lookup_env(name, context.allocator)
	return value if set else nil
}

@(private = "file")
env_string :: proc(name: string) -> string {
	return os.get_env(name, context.allocator)
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
