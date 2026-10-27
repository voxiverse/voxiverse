package client

import "core:fmt"
import "core:strings"

import "../base"
import "../common/game"
import "platform"

// Controls (Options > Controls): every action is bound to a key or a mouse
// button by its place on the keyboard (platform.Key), so WASD stays a
// cluster on any layout. The bindings are settings ("key.jump = space" in
// the settings file, `set key.jump space` in the console); F1-F4, F11's
// neighbours, Escape and the console key stay fixed.

Bindings :: struct {
	forward:    platform.Key,
	back:       platform.Key,
	left:       platform.Key,
	right:      platform.Key,
	jump:       platform.Key, // twice quickly: fly (where flying is allowed)
	sneak:      platform.Key,
	sprint:     platform.Key,
	attack:     platform.Key, // break the aimed block, hit
	use:        platform.Key, // place, use the held item, dial a gate
	pick:       platform.Key, // pick the aimed block into the hand
	inventory:  platform.Key,
	stats:      platform.Key, // open the statistics
	drop:       platform.Key, // with Ctrl: the whole stack
	chat:       platform.Key,
	command:    platform.Key, // the chat, starting with /
	hotbar_1:   platform.Key,
	hotbar_2:   platform.Key,
	hotbar_3:   platform.Key,
	hotbar_4:   platform.Key,
	hotbar_5:   platform.Key,
	screenshot: platform.Key,
	fullscreen: platform.Key,
	tab_prev:   platform.Key, // menus: the tab before
	tab_next:   platform.Key, // menus: the tab after
}

DEFAULT_BINDINGS :: Bindings {
	forward    = .W,
	back       = .S,
	left       = .A,
	right      = .D,
	jump       = .Space,
	sneak      = .Left_Shift,
	sprint     = .Left_Control,
	attack     = .Mouse_Left,
	use        = .Mouse_Right,
	pick       = .Mouse_Middle,
	inventory  = .E,
	stats      = .K,
	drop       = .Q,
	chat       = .T,
	command    = .Slash,
	hotbar_1   = .Num_1,
	hotbar_2   = .Num_2,
	hotbar_3   = .Num_3,
	hotbar_4   = .Num_4,
	hotbar_5   = .Num_5,
	screenshot = .F2,
	fullscreen = .F11,
	tab_prev   = .Q,
	tab_next   = .E,
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
	{field = "inventory", help = "Open the inventory."},
	{field = "stats", label = "Statistics", help = "Open your statistics."},
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

// Binding_Context: where a binding is read. Two bindings clash only when
// their contexts overlap (Both overlaps either).
Binding_Context :: enum u8 {
	World,
	Menu,
	Both,
}

@(rodata)
BINDING_CONTEXT := [len(BINDING_VARS)]Binding_Context {
	20 = .Both, // screenshot
	21 = .Both, // fullscreen
	22 = .Menu, // tab_prev
	23 = .Menu, // tab_next
}

bindings_overlap :: proc(a, b: Binding_Context) -> bool {
	return a == b || a == .Both || b == .Both
}

// menu_tab_step: -1, +1 or 0 from the tab keys pressed this frame. Typing a
// Q into a text field, or choosing a key for a binding, is not a step.
// over_slot: a slot is under the mouse, where the drop key drops instead.
menu_tab_step :: proc(app: ^App, over_slot := false) -> int {
	if app.ui.edit.active || app.options.listening != 0 {return 0}
	keys := app.settings.keys
	step := 0
	if keys.tab_prev in app.input.pressed && !(over_slot && keys.tab_prev == keys.drop) {step -= 1}
	if keys.tab_next in app.input.pressed && !(over_slot && keys.tab_next == keys.drop) {step += 1}
	return step
}

bindings_table :: proc() -> base.Var_Table {
	return {"key.", Bindings, BINDING_VARS[:], &BINDINGS_DEFAULTS}
}

// hotbar_keys: the keys of the hotbar's slots, in order.
hotbar_keys :: proc(b: Bindings) -> [game.HOTBAR_SLOTS]platform.Key {
	return {b.hotbar_1, b.hotbar_2, b.hotbar_3, b.hotbar_4, b.hotbar_5}
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
