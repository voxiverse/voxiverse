package engine

import "common:netcode"
import "core:time"

Multiplayer_Mode :: enum u8 {
	List,
	Direct, // Direct Connection: an address and a password
	Name, // first time: the name to play under
}

Multiplayer_Screen :: struct {
	discovery:  netcode.Discovery,
	searching:  bool, // discovery is open
	mode:       Multiplayer_Mode,
	selected:   u64, // the selected server's instance (0: none)
	last_click: time.Tick, // (double-clicks)
	address:    [dynamic]u8,
	password:   [dynamic]u8,
	name:       [dynamic]u8,
}
