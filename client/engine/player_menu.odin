package engine

import "client:ui"

Section_Id :: enum u8 {
	Map,
	Journal,
	Inventory,
	Character,
	Atlas,
	Statistics,
}

Player_Menu :: struct {
	section:      Section_Id, // the one shown
	last:         Section_Id, // the one shown last (Tab opens it); not saved between runs
	has_last:     bool,
	journal_page: Journal_Page, // the journal's page shown (where the registry has quests)
	quest_list:   ui.Scroll_List, // the journal's quests: the row picked is the quest shown (the tracked one when the journal first shows them)
	skill_pick:   int, // the Character section's skill shown (an index into the registry's)
}

// Journal_Page: the journal's pages (client/menu/journal.odin).
Journal_Page :: enum u8 {
	Quests, // the quests under way and done
	Log, // the places found and the creatures met
	Worlds, // the worlds stood on, and what was found on each
}
