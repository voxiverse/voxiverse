package engine

import "core:time"

Script :: struct {
	commands:    []string, // into the --exec text (lives for the program)
	next:        int,
	wait:        int, // frames left to wait
	wait_world:  bool,
	wait_joined: bool, // until the session plays (its world may still be loading)
	until:       time.Tick, // sleeping until then (zero: not)
	hurried:     bool, // until our own server has run the ticks it was asked to hurry (`ticks`)
}
