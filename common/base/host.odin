package base

import "core:fmt"

// Host: everything the core knows about the machine it runs on. It is plain data and
// procedure values, filled in by the platform layer (`common/platform`, `client/platform`)
// once at start and handed down by the entry packages (`client/main`, `server/dedicated`);
// the core imports only base and never a platform package. Tests fill it with fakes.
//
// The services land one step at a time (docs/design.md, "The OS quarantine"): so far the boot
// information and the output (stdout and stderr).
Host :: struct {
	boot:   Boot_Info,
	output: Output_Service,
}

// Boot_Info: what the process was started with, read once at boot.
Boot_Info :: struct {
	args: []string, // argv[1:] (the program's own name is not in it)
}

Output_Stream :: enum {
	Out, // stdout
	Err, // stderr
}

// Output_Service: the process's stdout and stderr. The platform fills it; `output_install`
// makes it the process's one output, which the log writer and the crash and assertion
// paths (they have no Host to read it from) write through. Until one is installed, output
// is dropped. The procedures are contextless: the crash handlers call them.
Output_Service :: struct {
	write:    proc "contextless" (stream: Output_Stream, text: string),
	// Whether the stream is a terminal that shows colour.
	is_color: proc "contextless" (stream: Output_Stream) -> bool,
}

@(private = "file")
output: Output_Service

// output_install makes service the process's output (platform.boot does it).
output_install :: proc(service: Output_Service) {
	output = service
}

// out_write writes text to the stream, as one write.
out_write :: proc "contextless" (stream: Output_Stream, text: string) {
	if output.write != nil {output.write(stream, text)}
}

// out_is_color reports whether the stream is a terminal that shows colour.
out_is_color :: proc "contextless" (stream: Output_Stream) -> bool {
	return output.is_color != nil && output.is_color(stream)
}

// out_printfln writes one formatted line to the stream, as one write. It formats on the
// stack (a line over 1 KiB is cut), so the crash paths can use it.
out_printfln :: proc(stream: Output_Stream, format: string, args: ..any) {
	buf: [1024]u8
	text := fmt.bprintf(buf[:len(buf) - 1], format, ..args)
	buf[len(text)] = '\n'
	out_write(stream, string(buf[:len(text) + 1]))
}
