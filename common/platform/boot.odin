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
		boot = {args = os.args[1:] if len(os.args) > 0 else nil},
		output = {write = output_write, is_color = output_is_color},
		entropy = crypto.rand_bytes,
	}
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
