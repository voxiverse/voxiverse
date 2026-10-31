package engine

import "client:ui"

Prompt_Shape :: enum {
	Disc, // a filled disc, the letter over it
	Ring, // the PlayStation circle (drawn in a disc)
	Cross,
	Square,
	Triangle,
	Bumper_Left,
	Bumper_Right,
	Trigger_Left,
	Trigger_Right,
	Stick, // a ring, L or R over it
	Dpad,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
	Menu, // three bars
	View, // two squares
	Keycap, // a rounded key, its name over it
	Mouse_Left,
	Mouse_Right,
	Mouse_Middle,
}

Prompt_Glyph :: struct {
	shape: Prompt_Shape,
	text:  string,
}

Prompt_Icons :: [Prompt_Shape]ui.Icon

PROMPTS_SHOWN_MAX :: 32
