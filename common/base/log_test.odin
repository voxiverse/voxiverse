package base

import "core:log"
import "core:testing"

@(private = "file")
Captured :: struct {
	lines: [dynamic]string,
}

@(private = "file")
keep :: proc(data: rawptr, level: log.Level, tag: string, text: string) {
	c := (^Captured)(data)
	append(&c.lines, text)
}

// The session recording keeps the warnings and errors of the log (not the
// informational lines), and stops when it is taken off.
@(test)
test_log_capture_takes_warnings_and_errors :: proc(t: ^testing.T) {
	sink: Log_Sink
	logger := log_sink_init(&sink, nil, .Fatal, "test") // (nothing on the console)
	got: Captured
	defer delete(got.lines)
	testing.expect(t, log_sink_of(logger) == &sink)
	testing.expect(t, log_sink_of(log.nil_logger()) == nil)
	log_set_capture(&sink, keep, &got)
	context.logger = logger
	log.info("an informational line")
	log.warn("a warning")
	log.error("an error")
	log_set_capture(&sink, nil, nil)
	log.warn("after")
	testing.expect_value(t, len(got.lines), 2)
	if len(got.lines) == 2 {
		testing.expect_value(t, got.lines[0], "a warning")
		testing.expect_value(t, got.lines[1], "an error")
	}
}
