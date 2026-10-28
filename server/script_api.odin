package server

import "../base"
import "../common/game"

// The shape of the script API for the party systems (docs/script_api_notes.md).
// No VM exists yet: these are the typed procedures M51 and M52 will wrap as
// natives, each with the capability a script needs to call it. A script never
// changes a mode, health or a rule except through them. Damage, healing and
// respawn join in M48g.

Capability :: distinct string

CAP_PLAYERS_READ :: Capability("players.read")
CAP_PLAYERS_MODE :: Capability("players.mode")
CAP_RULES_READ :: Capability("rules.read")
CAP_RULES_SET :: Capability("rules.set")

// native_set_game_mode (players.mode): the cause is recorded as script:<pack>.
native_set_game_mode :: proc(s: ^Server, c: ^Client, mode: int, pack: string) -> Mode_Result {
	return set_game_mode(s, c, mode, {"script", pack})
}

// native_abilities (players.read): what c's character can do.
native_abilities :: proc(s: ^Server, c: ^Client) -> game.Abilities {
	return game.derive_abilities(s.registry, c.mode, &c.inventory)
}

// native_rule_get (rules.read): a rule's value as text.
native_rule_get :: proc(w: ^World, name: string) -> (value: string, ok: bool) {
	table := game.rules_table()
	v := base.var_find(table, rule_name(name)) or_return
	return base.var_format(table, &w.rules, v), true
}
