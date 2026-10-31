package engine

import "common:game"
import "core:time"

THUMB_STARS :: 400 // stars a card's thumbnail draws

Save_Entry :: struct {
	name:         string, // the directory's name (what players see)
	path:         string,
	played:       time.Time, // its config file's last change: when it was last saved
	seed:         u64, // the universe's seed (its home world's address, its galaxy)
	mode:         string, // the universe's default game mode, as universe.cfg says it
	mode_changed: bool, // /gamemode changed it since it was made
	stars:        [THUMB_STARS]game.Star, // its galaxy
}

Saves_Mode :: enum u8 {
	List,
	Menu, // a card's menu: Rename, Export, Delete
	Edit, // rename (and open the folder)
	Delete, // confirming
	Import, // asking for the file
}

Universes_Screen :: struct {
	entries:  [dynamic]Save_Entry,
	mode:     Saves_Mode,
	selected: int, // -1: none (the card the menu, rename or delete is about)
	scroll:   f32, // cards scrolled
	name:     [dynamic]u8, // Edit's name
	path:     [dynamic]u8, // Import's file
	message:  string, // why the last action failed (shown on the list)
}
