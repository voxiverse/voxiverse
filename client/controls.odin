package client

import "core:fmt"
import "core:strings"

import "../base"
import "platform"
import "ui"

// Controls (Options > Controls): every action is bound to a key or a mouse
// button by its place on the keyboard (platform.Key), so WASD stays a
// cluster on any layout. The bindings are settings ("key.jump = space" in
// the settings file, `set key.jump space` in the console); F1-F4, F11's
// neighbours, Escape and the console key stay fixed.

Bindings :: struct {
	forward:         platform.Key,
	back:            platform.Key,
	left:            platform.Key,
	right:           platform.Key,
	jump:            platform.Key, // twice quickly: fly (where flying is allowed)
	sneak:           platform.Key,
	sprint:          platform.Key,
	attack:          platform.Key, // break the aimed block, hit
	use:             platform.Key, // place, use the held item, dial a gate
	pick:            platform.Key, // pick the aimed block into the hand
	inventory:       platform.Key,
	stats:           platform.Key, // open the statistics
	player_menu:     platform.Key, // the last section; closes the menu
	world_map:       platform.Key, // (the Map section: hidden for now)
	journal:         platform.Key, // (hidden)
	character:       platform.Key, // (hidden)
	atlas:           platform.Key, // (hidden)
	toggle_hud:      platform.Key, // hide the HUD
	camera:          platform.Key, // first person, third person behind, third person facing you
	swap_offhand:    platform.Key, // the hand's item with the offhand slot's
	reload:          platform.Key, // refill the held weapon's magazine
	player_list:     platform.Key, // held: who is here
	drop:            platform.Key, // with Ctrl: the whole stack
	chat:            platform.Key,
	command:         platform.Key, // the chat, starting with /
	hotbar_1:        platform.Key,
	hotbar_2:        platform.Key,
	hotbar_3:        platform.Key,
	hotbar_4:        platform.Key,
	hotbar_5:        platform.Key,
	hotbar_next:     platform.Key, // (unbound: the wheel does it)
	hotbar_previous: platform.Key,
	screenshot:      platform.Key,
	fullscreen:      platform.Key,
	tab_prev:        platform.Key, // menus: the tab before
	tab_next:        platform.Key, // menus: the tab after
}

DEFAULT_BINDINGS :: Bindings {
	forward      = .W,
	back         = .S,
	left         = .A,
	right        = .D,
	jump         = .Space,
	sneak        = .Left_Shift,
	sprint       = .Left_Control,
	attack       = .Mouse_Left,
	use          = .Mouse_Right,
	pick         = .Mouse_Middle,
	inventory    = .E,
	stats        = .K,
	player_menu  = .Tab,
	world_map    = .M,
	journal      = .J,
	character    = .C,
	atlas        = .L,
	toggle_hud   = .F1,
	camera       = .F5,
	swap_offhand = .F,
	reload       = .R,
	player_list  = .P,
	drop         = .Q,
	chat         = .T,
	command      = .Slash,
	hotbar_1     = .Num_1,
	hotbar_2     = .Num_2,
	hotbar_3     = .Num_3,
	hotbar_4     = .Num_4,
	hotbar_5     = .Num_5,
	screenshot   = .F2,
	fullscreen   = .F11,
	tab_prev     = .Q,
	tab_next     = .E,
}

@(rodata)
BINDINGS_DEFAULTS := DEFAULT_BINDINGS

@(rodata)
BINDING_VARS := [?]base.Var {
	{field = "forward", label = "Walk forward", help = "Walk forward."},
	{field = "back", label = "Walk backward", help = "Walk backward."},
	{field = "left", label = "Strafe left", help = "Step to the left."},
	{field = "right", label = "Strafe right", help = "Step to the right."},
	{field = "jump", help = "Jump. Press twice quickly to fly, where flying is allowed."},
	{field = "sneak", help = "Sneak: slower, and you do not fall off edges."},
	{field = "sprint", help = "Run faster while moving forward."},
	{
		field = "attack",
		label = "Attack / Break",
		help = "Break the block you aim at, or hit what you aim at.",
	},
	{
		field = "use",
		label = "Use / Place",
		help = "Place a block, use the item in your hand, or dial a gate.",
	},
	{field = "pick", label = "Pick Block", help = "Take the block you aim at into your hand."},
	{
		field = "inventory",
		help = "Open the player menu at your inventory; the same key closes it.",
	},
	{field = "stats", label = "Statistics", help = "Open the player menu at your statistics."},
	{
		field = "player_menu",
		label = "Player menu",
		help = "Open the player menu at the section you had open last; the same key closes it.",
	},
	{field = "world_map", label = "Map", help = "Open the map (not there yet)."},
	{field = "journal", help = "Open the journal (not there yet)."},
	{field = "character", help = "Open your character (not there yet)."},
	{field = "atlas", help = "Open the atlas (not there yet)."},
	{
		field = "toggle_hud",
		label = "Hide HUD",
		help = "Hide the hotbar, crosshair and health until you press it again.",
	},
	{
		field = "camera",
		help = "Cycle the camera: first person, third person behind you, third person facing you.",
	},
	{
		field = "swap_offhand",
		label = "Swap with offhand",
		help = "Swap the item in your hand with the one in your offhand slot.",
	},
	{
		field = "reload",
		help = "Reload the weapon in your hand. An empty magazine reloads when you fire.",
	},
	{field = "player_list", label = "Player list", help = "Hold to see who is here."},
	{
		field = "drop",
		label = "Drop item",
		help = "Drop one of the item in your hand; with Ctrl, the whole stack.",
	},
	{field = "chat", label = "Open chat", help = "Open the chat to write a message."},
	{
		field = "command",
		label = "Open command",
		help = "Open the chat with a slash, ready for a command.",
	},
	{field = "hotbar_1", label = "Hotbar slot 1", help = "Hold the first item of your hotbar."},
	{field = "hotbar_2", label = "Hotbar slot 2", help = "Hold the second item of your hotbar."},
	{field = "hotbar_3", label = "Hotbar slot 3", help = "Hold the third item of your hotbar."},
	{field = "hotbar_4", label = "Hotbar slot 4", help = "Hold the fourth item of your hotbar."},
	{field = "hotbar_5", label = "Hotbar slot 5", help = "Hold the fifth item of your hotbar."},
	{
		field = "hotbar_next",
		label = "Next hotbar slot",
		help = "Hold the next item of your hotbar (the wheel does too).",
	},
	{
		field = "hotbar_previous",
		label = "Previous hotbar slot",
		help = "Hold the previous item of your hotbar (the wheel does too).",
	},
	{field = "screenshot", label = "Take screenshot", help = "Save a picture of the screen."},
	{
		field = "fullscreen",
		label = "Toggle fullscreen",
		help = "Switch between a window and the whole screen.",
	},
	{
		field = "tab_prev",
		label = "Previous tab",
		help = "In menus with tabs, go to the tab before.",
	},
	{field = "tab_next", label = "Next tab", help = "In menus with tabs, go to the tab after."},
}

// menu_tab_step: -1, +1 or 0 from the tab actions pressed this frame. Typing
// a Q into a text field, or choosing a key for a binding, is not a step.
// over_slot: a slot is under the mouse, where the drop key drops instead.
menu_tab_step :: proc(app: ^App, over_slot := false) -> int {
	if app.ui.edit.active || app.options.listening != .None || ui.osk_is_open(&app.ui) {return 0}
	a := &app.actions
	step := 0
	prev_is_drop := app.settings.keys.tab_prev == app.settings.keys.drop
	next_is_drop := app.settings.keys.tab_next == app.settings.keys.drop
	if action_pressed(a, .Tab_Prev) &&
	   !(over_slot && prev_is_drop && a.device == .Keyboard) {step -= 1}
	if action_pressed(a, .Tab_Next) &&
	   !(over_slot && next_is_drop && a.device == .Keyboard) {step += 1}
	return step
}

bindings_table :: proc() -> base.Var_Table {
	return {"key.", Bindings, BINDING_VARS[:], &BINDINGS_DEFAULTS}
}

// key_label: what to call k on screen, as the player's keyboard prints it.
key_label :: proc(w: ^platform.Window, k: platform.Key) -> string {
	#partial switch k {
	case .Unknown:
		return "(none)"
	case .Mouse_Left:
		return "Left Button"
	case .Mouse_Right:
		return "Right Button"
	case .Mouse_Middle:
		return "Middle Button"
	case .Mouse_4:
		return "Mouse Button 4"
	case .Mouse_5:
		return "Mouse Button 5"
	}
	#partial switch s := platform.key_symbol(w, k); s {
	case .Num_0 ..= .Num_9:
		return KEY_DIGITS[int(s) - int(platform.Key.Num_0)]
	case .Grave ..= .Slash:
		return KEY_MARKS[int(s) - int(platform.Key.Grave)]
	case:
		name, _ := strings.replace_all(fmt.tprint(s), "_", " ", context.temp_allocator)
		return name
	}
}

@(private = "file")
KEY_DIGITS := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
@(private = "file")
KEY_MARKS := [11]string{"`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"}

// Pad_Bindings: the gamepad's buttons for the actions that can be rebound,
// named by place as on an Xbox pad (platform.Pad_Button); None is unbound.
// "pad.jump = a" in the settings file, `set pad.jump a` in the console.
Pad_Bindings :: struct {
	jump:            platform.Pad_Button,
	sneak:           platform.Pad_Button,
	sprint:          platform.Pad_Button,
	attack:          platform.Pad_Button,
	use:             platform.Pad_Button,
	pick:            platform.Pad_Button,
	inventory:       platform.Pad_Button,
	player_menu:     platform.Pad_Button,
	drop:            platform.Pad_Button,
	reload:          platform.Pad_Button,
	chat:            platform.Pad_Button,
	command:         platform.Pad_Button,
	hotbar_next:     platform.Pad_Button,
	hotbar_previous: platform.Pad_Button,
	screenshot:      platform.Pad_Button,
	menu_confirm:    platform.Pad_Button,
	menu_back:       platform.Pad_Button,
	menu_secondary:  platform.Pad_Button,
	menu_tertiary:   platform.Pad_Button,
	tab_prev:        platform.Pad_Button,
	tab_next:        platform.Pad_Button,
}

DEFAULT_PAD_BINDINGS :: Pad_Bindings {
	jump            = .A,
	sneak           = .B,
	sprint          = .Left_Stick,
	attack          = .Right_Trigger,
	use             = .Left_Trigger,
	pick            = .Right_Stick,
	inventory       = .Y,
	player_menu     = .Back,
	drop            = .Dpad_Down,
	reload          = .X,
	chat            = .Dpad_Up,
	hotbar_next     = .Right_Bumper,
	hotbar_previous = .Left_Bumper,
	menu_confirm    = .A,
	menu_back       = .B,
	menu_secondary  = .X,
	menu_tertiary   = .Y,
	tab_prev        = .Left_Bumper,
	tab_next        = .Right_Bumper,
}

@(rodata)
PAD_BINDINGS_DEFAULTS := DEFAULT_PAD_BINDINGS

@(rodata)
PAD_BINDING_VARS := [?]base.Var {
	{field = "jump", help = "pad: jump; twice quickly: fly."},
	{field = "sneak", help = "pad: sneak."},
	{field = "sprint", help = "pad: run faster."},
	{field = "attack", help = "pad: break the block you aim at, or hit."},
	{field = "use", help = "pad: place a block, use the item in hand, dial a gate."},
	{field = "pick", help = "pad: take the aimed block into your hand."},
	{field = "inventory", help = "pad: open the inventory."},
	{field = "player_menu", help = "pad: open the player menu."},
	{field = "drop", help = "pad: drop an item."},
	{field = "reload", help = "pad: reload the weapon in your hand."},
	{field = "chat", help = "pad: open the chat."},
	{field = "command", help = "pad: open the chat with a slash."},
	{field = "hotbar_next", help = "pad: the next hotbar slot."},
	{field = "hotbar_previous", help = "pad: the previous hotbar slot."},
	{field = "screenshot", help = "pad: save a picture of the screen."},
	{field = "menu_confirm", help = "pad: choose in menus."},
	{field = "menu_back", help = "pad: go back in menus."},
	{field = "menu_secondary", help = "pad: the menus' second action."},
	{field = "menu_tertiary", help = "pad: the menus' third action."},
	{field = "tab_prev", help = "pad: the tab before."},
	{field = "tab_next", help = "pad: the tab after."},
}

pad_bindings_table :: proc() -> base.Var_Table {
	return {"pad.", Pad_Bindings, PAD_BINDING_VARS[:], &PAD_BINDINGS_DEFAULTS}
}

@(rodata)
PAD_NAMES_XBOX := [platform.Pad_Button]string {
	.None          = "(none)",
	.A             = "A",
	.B             = "B",
	.X             = "X",
	.Y             = "Y",
	.Left_Bumper   = "LB",
	.Right_Bumper  = "RB",
	.Left_Trigger  = "LT",
	.Right_Trigger = "RT",
	.Back          = "View",
	.Start         = "Menu",
	.Left_Stick    = "LS",
	.Right_Stick   = "RS",
	.Dpad_Up       = "",
	.Dpad_Down     = "",
	.Dpad_Left     = "",
	.Dpad_Right    = "",
}

@(rodata)
PAD_NAMES_PLAYSTATION := [platform.Pad_Button]string {
	.None          = "(none)",
	.A             = "Cross",
	.B             = "Circle",
	.X             = "Square",
	.Y             = "Triangle",
	.Left_Bumper   = "L1",
	.Right_Bumper  = "R1",
	.Left_Trigger  = "L2",
	.Right_Trigger = "R2",
	.Back          = "Create",
	.Start         = "Options",
	.Left_Stick    = "L3",
	.Right_Stick   = "R3",
	.Dpad_Up       = "",
	.Dpad_Down     = "",
	.Dpad_Left     = "",
	.Dpad_Right    = "",
}

@(rodata)
PAD_NAMES_SWITCH := [platform.Pad_Button]string {
	.None          = "(none)",
	.A             = "B",
	.B             = "A",
	.X             = "Y",
	.Y             = "X",
	.Left_Bumper   = "L",
	.Right_Bumper  = "R",
	.Left_Trigger  = "ZL",
	.Right_Trigger = "ZR",
	.Back          = "Minus",
	.Start         = "Plus",
	.Left_Stick    = "Left Stick",
	.Right_Stick   = "Right Stick",
	.Dpad_Up       = "",
	.Dpad_Down     = "",
	.Dpad_Left     = "",
	.Dpad_Right    = "",
}

@(rodata)
PAD_NAMES_DECK := [platform.Pad_Button]string {
	.None          = "(none)",
	.A             = "A",
	.B             = "B",
	.X             = "X",
	.Y             = "Y",
	.Left_Bumper   = "L1",
	.Right_Bumper  = "R1",
	.Left_Trigger  = "L2",
	.Right_Trigger = "R2",
	.Back          = "View",
	.Start         = "Menu",
	.Left_Stick    = "L3",
	.Right_Stick   = "R3",
	.Dpad_Up       = "",
	.Dpad_Down     = "",
	.Dpad_Left     = "",
	.Dpad_Right    = "",
}

// pad_button_name: what to call b on a pad of this family (product tells
// the DualShock 4's Share from the DualSense's Create).
pad_button_name :: proc(
	family: platform.Pad_Family,
	product: u16,
	b: platform.Pad_Button,
) -> string {
	#partial switch b {
	case .None:
		return "(none)"
	case .Dpad_Up:
		return "D-pad Up"
	case .Dpad_Down:
		return "D-pad Down"
	case .Dpad_Left:
		return "D-pad Left"
	case .Dpad_Right:
		return "D-pad Right"
	}
	switch family {
	case .Generic, .Xbox:
		return PAD_NAMES_XBOX[b]
	case .PlayStation:
		if b == .Back {return "Share" if product == 0x05c4 || product == 0x09cc else "Create"}
		return PAD_NAMES_PLAYSTATION[b]
	case .Switch:
		return PAD_NAMES_SWITCH[b]
	case .Steam_Deck:
		return PAD_NAMES_DECK[b]
	}
	return "?"
}
