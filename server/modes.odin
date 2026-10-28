package server

import "core:fmt"
import "core:strings"

import "../base"
import "../common/game"

// Game modes, per player. A mode is a profile of abilities from a pack
// (data/game_modes/); what a character can do is derive_abilities(mode,
// inventory), asked for by the systems (has_ability), never a mode's name.
// A player's mode changes in one place, set_game_mode: it is stored with
// the character, replicated (the Mode record), journalled with who changed it
// and raised as an event (the telemetry Mode_Changed). The universe has a
// default (universe.cfg `mode`), a world may override it (the rule
// default_game_mode). Permissions guard the commands that ask for a change
// (voxiverse.command.gamemode.self and .others); they are not abilities.
//
// The names a script will call are in script_api.odin.

// The mode a universe without a choice starts its players in. (The one place
// that names a mode: it is data's id, not a test.)
DEFAULT_MODE :: "base:creative"

NODE_GAMEMODE_SELF :: "voxiverse.command.gamemode.self"
NODE_GAMEMODE_OTHERS :: "voxiverse.command.gamemode.others"

Mode_Result :: enum u8 {
	Ok,
	Unknown_Mode,
	Same, // already in it: nothing changed
}

// Mode_Cause: why a mode changed, for the journal and the event.
Mode_Cause :: struct {
	how: string, // "join", "command", "script", "rule"
	by:  string, // who asked: a player's name, a pack's id ("" for the world)
}

// mode_text_valid: text is a mode id as universe.cfg and the creation screen write it.
mode_text_valid :: proc(text: string) -> bool {
	return len(text) > 0 && len(text) <= 64 && !strings.contains_any(text, " \t\r\n=")
}

mode_config_text :: proc(mode: string) -> string {
	return mode if mode != "" else DEFAULT_MODE
}

// mode_default: the mode a new character in w starts in: the world's rule,
// else the universe's, else the first the registry has.
mode_default :: proc(s: ^Server, w: ^World) -> int {
	if text := base.var_text(&w.rules.default_game_mode); text != "" {
		if m, ok := game.mode_find(s.registry, text); ok {return m}
	}
	if m, ok := game.mode_find(s.registry, mode_config_text(s.config.mode)); ok {return m}
	return 0
}

// has_ability: c's character can do a.
has_ability :: proc(s: ^Server, c: ^Client, a: game.Ability) -> bool {
	return a in game.derive_abilities(s.registry, c.mode, &c.inventory)
}

// character_mods: the numbers and abilities physics and rules read for c.
character_mods :: proc(s: ^Server, c: ^Client) -> game.Mods {
	return game.derive_character(s.registry, c.mode, &c.inventory)
}

// set_game_mode: the one place a player's game mode changes.
set_game_mode :: proc(s: ^Server, c: ^Client, mode: int, cause: Mode_Cause) -> Mode_Result {
	if mode < 0 || mode >= len(s.registry.game_modes) {return .Unknown_Mode}
	if c.mode_set && mode == c.mode {return .Same}
	before := game.derive_abilities(s.registry, c.mode, &c.inventory) if c.mode_set else {}
	from := game.mode_label(s.registry, c.mode) if c.mode_set else ""
	c.mode, c.mode_set = mode, true
	after := game.derive_abilities(s.registry, c.mode, &c.inventory)
	if .Fly not_in after {c.player.flying = false}
	if .Health in after && .Health not_in before {c.max_health = 0} 	// (health_tick: full)
	disturb(s, c) // (what the character can do changed what its inputs mean)
	label := game.mode_label(s.registry, mode)
	if cause.how != "join" {
		text := fmt.tprintf("gamemode %s %s (from %s, %s)", label, client_name(c), from, cause.how)
		by :=
			Actor{.Character, cause.by, false} if cause.by != "" && cause.how == "command" else Actor{}
		if cause.how == "script" {by = {.Script, cause.by, false}}
		journal_setting(c.world, by, text)
		record(s, c, .Mode_Changed, label, 1 if cause.how == "command" else 0)
	}
	mode_put(s, c)
	return .Ok
}

// mode_put: the Mode record (sent when it changes).
mode_put :: proc(s: ^Server, c: ^Client) {
	rec := game.Mode_Record{s.registry.game_modes[c.mode].id}
	state_put(s, c, .Mode, &rec)
}

// admin_gamemode: gamemode (the mode), gamemode <mode> (change your own),
// gamemode <mode> <player> (change theirs). What you may ask for is a permission;
// what a character can do is its abilities.
@(private)
admin_gamemode :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) == 0 {
		changed :=
			" (the universe's default was changed since it was made)" if s.config.mode_changed else ""
		notice(s, c, fmt.tprintf("game mode %s%s", game.mode_label(s.registry, c.mode), changed))
		return true
	}
	target := c
	if len(args) == 2 {
		target = client_by_name(s, args[1])
		if target == nil {
			notice(s, c, fmt.tprintf("&cNo player %s here", args[1]))
			return true
		}
	}
	mine := target == c
	if mine && !allowed(s, c, NODE_GAMEMODE_SELF) {
		notice(s, c, "You may not change your own game mode.")
		return true
	}
	if !mine && !allowed(s, c, NODE_GAMEMODE_OTHERS) {
		notice(s, c, "You may not change another player's game mode.")
		return true
	}
	m, ok := game.mode_find(s.registry, args[0])
	if !ok {
		notice(s, c, fmt.tprintf("&cNo game mode %s", args[0]))
		return true
	}
	switch set_game_mode(s, target, m, {"command", client_name(c)}) {
	case .Ok:
		label := game.mode_label(s.registry, m)
		notice(s, c, fmt.tprintf("%s: game mode %s", client_name(target), label))
		if !mine {notice(s, target, fmt.tprintf("Your game mode is now %s", label))}
	case .Same:
		notice(s, c, fmt.tprintf("%s is in %s already", client_name(target), args[0]))
	case .Unknown_Mode:
		notice(s, c, fmt.tprintf("&cNo game mode %s", args[0]))
	}
	return true
}

// mode_record_text: c's mode as the character's file keeps it.
mode_record_text :: proc(s: ^Server, c: ^Client) -> (text: base.Var_Text) {
	if c.mode_set {base.var_text_set(&text, s.registry.game_modes[c.mode].id)}
	return
}
