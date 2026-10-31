package engine

Section_Id :: enum u8 {
	Map,
	Journal,
	Inventory,
	Character,
	Atlas,
	Statistics,
}

Player_Menu :: struct {
	section:  Section_Id, // the one shown
	last:     Section_Id, // the one shown last (Tab opens it); not saved between runs
	has_last: bool,
}
