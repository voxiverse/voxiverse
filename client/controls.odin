package client

import "core:fmt"
import "core:strings"

import "../base"
import "../game"
import "../platform"

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
}

@(rodata)
BINDINGS_DEFAULTS := DEFAULT_BINDINGS

@(rodata)
BINDING_VARS := [?]base.Var {
	{field = "forward", label = "Walk forward", help = "key: walk forward"},
	{field = "back", label = "Walk backward", help = "key: walk backward"},
	{field = "left", label = "Strafe left", help = "key: step left"},
	{field = "right", label = "Strafe right", help = "key: step right"},
	{field = "jump", help = "key: jump (twice quickly: fly, where allowed)"},
	{field = "sneak", help = "key: sneak"},
	{field = "sprint", help = "key: sprint"},
	{field = "attack", label = "Attack / Break", help = "key: break the aimed block, hit"},
	{field = "use", label = "Use / Place", help = "key: place, use the held item"},
	{field = "pick", label = "Pick Block", help = "key: pick the aimed block into the hand"},
	{field = "inventory", help = "key: open the inventory"},
	{field = "stats", label = "Statistics", help = "key: open the statistics"},
	{field = "drop", label = "Drop item", help = "key: drop one of the held item (Ctrl: all)"},
	{field = "chat", label = "Open chat", help = "key: open the chat"},
	{field = "command", label = "Open command", help = "key: open the chat with /"},
	{field = "hotbar_1", label = "Hotbar slot 1", help = "key: hotbar slot 1"},
	{field = "hotbar_2", label = "Hotbar slot 2", help = "key: hotbar slot 2"},
	{field = "hotbar_3", label = "Hotbar slot 3", help = "key: hotbar slot 3"},
	{field = "hotbar_4", label = "Hotbar slot 4", help = "key: hotbar slot 4"},
	{field = "hotbar_5", label = "Hotbar slot 5", help = "key: hotbar slot 5"},
	{field = "screenshot", label = "Take screenshot", help = "key: save a screenshot"},
	{field = "fullscreen", label = "Toggle fullscreen", help = "key: fullscreen on or off"},
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
