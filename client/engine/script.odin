package engine

import "core:time"

Script :: struct {
	commands:   []string, // into the --exec text (lives for the program)
	next:       int,
	wait:       int, // frames left to wait
	wait_world: bool,
	until:      time.Tick, // sleeping until then (zero: not)
}
