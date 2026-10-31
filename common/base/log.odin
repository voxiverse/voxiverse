package base

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"

// Logging. Every line says when (seconds since start), how bad, which
// thread, and what; messages use key=value pairs for anything a reader might
// filter on:
//
//	console:    3.214 INFO  server    started seed=24301 view=12x6 workers=2
//	            3.215 WARN  mesh 2    chunk dropped pos=[1,6,4] (client/world.odin:240)
//	file:       3.214512 | INFO | server | started seed=24301 view=12x6 workers=2 | server/server.odin:105
//
// One Log_Sink per process owns the outputs (console, file, and a listener
// such as the in-game console); a lock keeps lines whole when threads log at
// once. Each thread logs through its own tagged logger, so nobody types
// "server:" prefixes:
//
//	tagged: base.Log_Tag
//	context.logger = base.log_retag(&tagged, context.logger, "server")
//
// (Under the test runner context.logger is the runner's; log_retag leaves it.)

Log_Sink :: struct {
	mutex:         sync.Mutex,
	start:         time.Tick,
	file:          ^os.File,
	console_level: log.Level,
	color:         bool, // console is a terminal that shows colour
	// Also receives every line (the in-game console). Called with the sink
	// locked: it must not log.
	listener:      proc(data: rawptr, level: log.Level, tag: string, text: string),
	listener_data: rawptr,
	// Also receives every warning and error (the session recording). Called
	// with the sink locked, never from the crash handler: it must not log.
	capture:       proc(data: rawptr, level: log.Level, tag: string, text: string),
	capture_data:  rawptr,
	root:          Log_Tag, // the creating thread's tagged logger
	// Set by the crash handler: the crashing thread may hold the lock, so
	// from here on lines are written without it (best effort).
	crashing:      bool,
}

// Log_Tag is a thread's tagged logger state; it must outlive the logger made
// from it (keep it in the thread's own long-lived state).
Log_Tag :: struct {
	sink: ^Log_Sink,
	tag:  string,
}

// log_sink_init opens the outputs and returns the logger for the calling
// thread, tagged tag. file may be nil (console only).
log_sink_init :: proc(
	s: ^Log_Sink,
	file: ^os.File,
	console_level: log.Level,
	tag: string,
) -> log.Logger {
	s^ = {
		start         = time.tick_now(),
		file          = file,
		console_level = console_level,
		color         = terminal.color_enabled && terminal.is_terminal(os.stderr),
	}
	if file != nil {
		now := time.now()
		y, mon, d := time.date(now)
		h, min, sec := time.clock(now)
		fmt.fprintfln(
			file,
			"log started %04d-%02d-%02d %02d:%02d:%02d UTC (times are seconds since then)",
			y,
			mon,
			d,
			h,
			min,
			sec,
		)
	}
	s.root = {s, tag}
	return tagged_logger(&s.root)
}

// log_set_listener adds (or with nil removes) a listener for every line at
// level Info and up.
log_set_listener :: proc(
	s: ^Log_Sink,
	listener: proc(data: rawptr, level: log.Level, tag: string, text: string),
	data: rawptr,
) {
	sync.guard(&s.mutex)
	s.listener, s.listener_data = listener, data
}

// log_set_capture adds (or with nil removes) a receiver of every line at level
// Warning and up.
log_set_capture :: proc(
	s: ^Log_Sink,
	capture: proc(data: rawptr, level: log.Level, tag: string, text: string),
	data: rawptr,
) {
	sync.guard(&s.mutex)
	s.capture, s.capture_data = capture, data
}

// log_sink_of: the sink a logger of ours writes to (nil: not one of ours, e.g. the test runner's).
log_sink_of :: proc(logger: log.Logger) -> ^Log_Sink {
	if logger.procedure != tagged_logger_proc {return nil}
	return (^Log_Tag)(logger.data).sink
}

// log_retag returns a logger writing to parent's sink under a new tag
// (parent unchanged if it is not one of ours, e.g. the test runner's).
log_retag :: proc(storage: ^Log_Tag, parent: log.Logger, tag: string) -> log.Logger {
	if parent.procedure != tagged_logger_proc {return parent}
	storage^ = {(^Log_Tag)(parent.data).sink, tag}
	return tagged_logger(storage)
}

@(private = "file")
tagged_logger :: proc(t: ^Log_Tag) -> log.Logger {
	return {procedure = tagged_logger_proc, data = t, lowest_level = .Debug}
}

@(private = "file")
tagged_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	t := (^Log_Tag)(data)
	s := t.sink
	secs := time.duration_seconds(time.tick_since(s.start))
	file := location.file_path
	// Paths relative to the repository: from the first of our top-level dirs.
	for dir in ([]string{"/base/", "/client/", "/common/", "/server/", "/dedicated/", "/tools/"}) {
		if i := strings.last_index(file, dir); i >= 0 {
			file = file[i + 1:]
			break
		}
	}
	name := level_name(level)
	// Seconds right-aligned to 9 columns (fmt pads numbers with zeros).
	seconds_buf: [32]u8
	digits := fmt.bprintf(seconds_buf[16:], "%.3f", secs)
	pad := max(9 - len(digits), 0)
	for i in 0 ..< pad {seconds_buf[16 - pad + i] = ' '}
	seconds := string(seconds_buf[16 - pad:][:pad + len(digits)])

	buf: [1024]u8
	b := strings.builder_from_bytes(buf[:])
	locked := !sync.atomic_load(&s.crashing)
	if locked {sync.mutex_lock(&s.mutex)}
	defer if locked {sync.mutex_unlock(&s.mutex)}
	if level >= s.console_level {
		strings.builder_reset(&b)
		if s.color {
			fmt.sbprintf(
				&b,
				"%s%s%s %s%-5s%s %s%-10s%s ",
				DIM,
				seconds,
				RESET,
				level_color(level),
				name,
				RESET,
				CYAN,
				t.tag,
				RESET,
			)
			fmt.sbprintf(
				&b,
				"%s%s%s",
				RED if level >= .Error else "",
				text,
				RESET if level >= .Error else "",
			)
			if level >=
			   .Warning {fmt.sbprintf(&b, " %s(%s:%d)%s", DIM, file, location.line, RESET)}
		} else {
			fmt.sbprintf(&b, "%s %-5s %-10s %s", seconds, name, t.tag, text)
			if level >= .Warning {fmt.sbprintf(&b, " (%s:%d)", file, location.line)}
		}
		// Errors to stderr, the rest to stdout; one write per line.
		fmt.fprintln(os.stderr if level >= .Error else os.stdout, strings.to_string(b))
	}
	if s.file != nil {
		fmt.fprintfln(
			s.file,
			"%.6f | %s | %s | %s | %s:%d",
			secs,
			name,
			t.tag,
			text,
			file,
			location.line,
		)
	}
	if s.listener != nil && level >= .Info {s.listener(s.listener_data, level, t.tag, text)}
	if locked && s.capture != nil && level >= .Warning {
		s.capture(s.capture_data, level, t.tag, text)
	}
}

@(private = "file")
level_name :: proc(level: log.Level) -> string {
	switch level {
	case .Debug:
		return "DEBUG"
	case .Info:
		return "INFO"
	case .Warning:
		return "WARN"
	case .Error:
		return "ERROR"
	case .Fatal:
		return "FATAL"
	}
	return "?"
}

@(private = "file")
DIM :: ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
@(private = "file")
RESET :: ansi.CSI + ansi.RESET + ansi.SGR
@(private = "file")
CYAN :: ansi.CSI + ansi.FG_CYAN + ansi.SGR
@(private = "file")
RED :: ansi.CSI + ansi.FG_RED + ansi.SGR

@(private = "file")
level_color :: proc(level: log.Level) -> string {
	switch level {
	case .Debug:
		return DIM
	case .Info:
		return ansi.CSI + ansi.FG_GREEN + ansi.SGR
	case .Warning:
		return ansi.CSI + ansi.FG_YELLOW + ansi.SGR
	case .Error, .Fatal:
		return RED
	}
	return ""
}
