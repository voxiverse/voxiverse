package game

import "core:strings"

// What hurts a player, and how a death is told. A source kind is the one
// thing the damage pipeline (server/damage.odin) and the death message are
// keyed by: a new source is an enum value and a line below, no branches.

Source_Kind :: enum u8 {
	Fall,
	Explosion,
	Weapon,
	Command,
	Void,
}

damage_source_name :: proc(kind: Source_Kind) -> string {
	switch kind {
	case .Fall:
		return "fall"
	case .Explosion:
		return "explosion"
	case .Weapon:
		return "weapon"
	case .Command:
		return "command"
	case .Void:
		return "void"
	}
	return "command"
}

// damage_source_parse: a kind by its name (a Player_Died's cause).
damage_source_parse :: proc(name: string) -> (kind: Source_Kind, ok: bool) {
	for k in Source_Kind {
		if damage_source_name(k) == name {return k, true}
	}
	return .Command, false
}

// Death_Line: how a death reads to others and to the one who died. {0} the
// victim, {1} the attacker, {2} the weapon. The keys are `death.<kind>` and
// `death.you.<kind>`: the strings of the death screen and the chat.
Death_Line :: struct {
	others: string,
	you:    string,
	by:     string, // with an attacker (others): "{0} was shot by {1} ({2})"
	by_you: string, // with an attacker, to the victim
}

@(rodata)
DEATH_LINES := [Source_Kind]Death_Line {
	.Fall = {
		others = "{0} fell",
		you = "You fell",
		by = "{0} was knocked off by {1}",
		by_you = "You were knocked off by {1}",
	},
	.Explosion = {
		others = "{0} blew up",
		you = "You blew up",
		by = "{0} was blown up by {1}",
		by_you = "You were blown up by {1}",
	},
	.Weapon = {
		others = "{0} was shot",
		you = "You were shot",
		by = "{0} was shot by {1} ({2})",
		by_you = "You were shot by {1} ({2})",
	},
	.Command = {
		others = "{0} died",
		you = "You died",
		by = "{0} was killed by {1}",
		by_you = "You were killed by {1}",
	},
	.Void = {
		others = "{0} fell out of the world",
		you = "You fell out of the world",
		by = "{0} was pushed out of the world by {1}",
		by_you = "You were pushed out of the world by {1}",
	},
}

// death_text: the line for a death of kind: to everyone (viewer_is_victim
// false, victim named) or to the player who died ("You ...").
death_text :: proc(
	kind: Source_Kind,
	victim, attacker, weapon: string,
	viewer_is_victim: bool,
	allocator := context.temp_allocator,
) -> string {
	line := DEATH_LINES[kind]
	template: string
	switch {
	case attacker != "" && viewer_is_victim:
		template = line.by_you
	case attacker != "":
		template = line.by
	case viewer_is_victim:
		template = line.you
	case:
		template = line.others
	}
	text, _ := strings.replace_all(template, "{0}", victim, allocator)
	text, _ = strings.replace_all(text, "{1}", attacker, allocator)
	text, _ = strings.replace_all(text, "{2}", weapon, allocator)
	return text
}
