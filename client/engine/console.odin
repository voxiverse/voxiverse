package engine

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"

CONSOLE_MAX_LINES :: 1000

Console :: struct {
	lines:     [CONSOLE_MAX_LINES]Console_Line, // ring buffer
	first:     int,
	count:     int,
	mutex:     sync.Mutex,
	line:      Line_Editor, // (console_line.odin)
	scroll:    f32, // lines scrolled up from the bottom
	commands:  [dynamic]Command,
	allocator: runtime.Allocator,
}

Console_Line :: struct {
	text:  string,
	level: log.Level,
}

Command :: struct {
	using spec: Command_Spec,
	complete:   Completer,
	args:       [2]int, // how many arguments: at least, at most (-1: any); {}: not checked
	needs:      Command_Needs,
	node:       string, // the permission it needs ("": none)
}

// Command_Spec: what console_register is given (the rest apart).
Command_Spec :: struct {
	name: string,
	help: string, // "name <args>: what it does" (up to ": ", its usage)
	run:  proc(app: ^App, args: []string),
}

Command_Need :: enum u8 {
	World, // in a world (playing)
	Host, // the world runs here
}

Command_Needs :: bit_set[Command_Need]

// Completer: what argument `arg` (0: the first) can be, for Tab.
Completer :: proc(app: ^App, arg: int, args: []string) -> []string

console_print :: proc(c: ^Console, text: string, level := log.Level.Info) {
	sync.guard(&c.mutex)
	line := strings.clone(text, c.allocator)
	if c.count == CONSOLE_MAX_LINES {
		delete(c.lines[c.first].text, c.allocator)
		c.lines[c.first] = {line, level}
		c.first = (c.first + 1) % CONSOLE_MAX_LINES
	} else {
		c.lines[(c.first + c.count) % CONSOLE_MAX_LINES] = {line, level}
		c.count += 1
	}
}
