package engine

import "client:ui"
import "common:base"
import "common:starmap"
import "core:time"

THUMB_STARS :: 400 // stars a card's thumbnail draws

Save_Entry :: struct {
	name:         string, // the directory's name (what players see)
	path:         string,
	played:       time.Time, // its config file's last change: when it was last saved
	age:          i64, // ticks the universe has run, across runs (universe.cfg's age): the time played
	seed:         u64, // the universe's seed (its home world's address, its galaxy)
	game_id:      string, // the game it plays, as universe.cfg says it ("": from before games were recorded)
	mode:         string, // the universe's default game mode, as universe.cfg says it
	mode_changed: bool, // /gamemode changed it since it was made
	stars:        [THUMB_STARS]starmap.Star, // its galaxy
}

Saves_Mode :: enum u8 {
	List,
	Edit, // rename (and open the folder)
	Delete, // confirming
	Import, // asking for the file
}

// Last_Save: the title's Continue: the save played last (Settings.last_save) as last
// looked at on the disk, so the title reads its universe.cfg once, not every frame.
Last_Save :: struct {
	checked: bool, // looked at, for name (universes_refresh clears it: a save renamed or gone)
	name:    base.Var_Text,
	found:   bool, // a universe of the game to continue (not: gone, unreadable, another game's, or its game not in this build)
}

// Universes_Screen: Singleplayer, the game's universes; to play alone, or to host
// (Multiplayer's Host: the same page, and the world it starts opens to the LAN). It reads
// every save on the disk and lists the game's.
Universes_Screen :: struct {
	host:       bool, // chosen to host: the world started from the page opens to the LAN
	entries:    [dynamic]Save_Entry, // every save, of every game, the one played last first
	mode:       Saves_Mode,
	list:       ui.Scroll_List, // the page's saves: the one selected (its place among them) and the first in view
	last_row:   int, // the save clicked last (its place on the page) ...
	last_click: time.Tick, // ... and when (a second click on it within DOUBLE_CLICK plays it)
	name:       [dynamic]u8, // Edit's name
	path:       [dynamic]u8, // Import's file
	message:    string, // why the last action failed (shown on the list)
	last:       Last_Save, // the title's Continue
}
