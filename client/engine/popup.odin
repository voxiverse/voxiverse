package engine

import "common:game"

Item_Popup :: struct {
	seen:   bool, // a slot has been seen (not yet: the first frame in a world shows)
	slot:   int, // the slot last seen selected
	age:    f32, // seconds since it began
	item:   game.Item,
	active: bool,
}

// popup_reset: out of a world (the next one starts afresh).
popup_reset :: proc(p: ^Item_Popup) {
	p^ = {}
}
