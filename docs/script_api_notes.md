# Script API notes

This document defines the shape of the script API that M51 and M52 will expose for the
survival systems.

Survival for the LAN playtest (M48f, M48g) is built in Odin, on procedures that the script VM
will wrap rather than bypass. Each procedure is declared in `server/script_api.odin` as a
typed procedure (the future native), with its capability (using M52's names) as a constant.

No part of this API is scriptable yet; this document is the contract. A script never changes
health, a game mode or a rule except through these procedures.

## Procedures

| Native | Odin procedure | Capability | Notes |
| --- | --- | --- | --- |
| `player.set_game_mode(player, mode, cause)` | `set_game_mode(s, player, mode, cause) -> Mode_Result` | `players.mode` | The only place a mode changes. `cause` is recorded in the journal. Result: ok, unknown mode, or same. |
| `player.abilities(player) -> set` | `derive_abilities(reg, mode, inv)` via `has_ability(c, a)` | `players.read` | Read-only: the mode's profile plus equipment. |
| `player.mode(player) -> id` | `Client.mode` | `players.read` | |
| `player.damage(player, amount, source)` | `damage(s, target, amount, source) -> Damage_Result` | `players.damage` | Checks `invulnerable`, `pvp` and `health`. `source` has a kind and an optional attacker and weapon. Death messages are derived from the source. |
| `player.heal(player, amount)` | `heal_player` | `players.damage` | |
| `player.respawn(player)` | `respawn(s, c)` | `players.respawn` | Valid only while the player is dead. |
| `rules.get(name)` / `rules.set(name, value, cause)` | `native_rule_get`, `rule_set` (the only place `/rule` and the console change a rule) | `rules.read` / `rules.set` | Journalled with the actor. `rules.set` requires the rule's name in the pack's grant list (M52). |
| `kit.give(player, kit)` | `kit_give(s, c, kit)` | `item.give` | A kit is data (`Mode_Def.kit` or `data/kits`). |

## Events

Events are carried on M26's event stream, and become M52's `Script_Event`.

| Event | Fields | Raised by |
| --- | --- | --- |
| `mode_changed` | player, from, to, cause | `set_game_mode`, once per actual change |
| `damaged` | player, amount, source kind, attacker, weapon, health after | `damage`, when the damage was applied |
| `died` | player, source kind, attacker, weapon, message | `die` |
| `respawned` | player, position, kit given | `respawn` |

## Requirements for the VM wrapper

The VM's wrapper must observe the following rules:

- It passes the pack's ID as the actor (`script:<pack>`) in the `cause` argument.
- It never calls `die` and never sets `Client.health`; neither is a native.
- It rate-limits `damage` in the same way as other effects (M52's budget).
- A script that requests a capability it was not granted receives M52's refusal, not a silent
  no-op.

## Permissions, capabilities and abilities

Three separate concepts govern what may happen, and they remain separate:

| Concept | Governs |
|---|---|
| Permissions (`voxiverse.command.*`) | Who may *request* an action through commands. |
| Capabilities | A script's authority. |
| Abilities | What the character can do. |
