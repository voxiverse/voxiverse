# Script API notes (the shape M51 and M52 will expose)

Survival for the LAN party (M48f, M48g) is built in Odin, on procedures that the script
VM will wrap instead of reaching around them. Each is declared in `server/script_api.odin`
as a typed procedure (the future native), with its capability (M52's names) as a constant.
Nothing here is a script yet; this file is the contract. A script never changes health,
a mode or a rule except through these.

## Procedures

| Native | Odin procedure | Capability | Notes |
| --- | --- | --- | --- |
| `player.set_game_mode(player, mode, cause)` | `set_game_mode(s, player, mode, cause) -> Mode_Result` | `players.mode` | The only place a mode changes. `cause` is recorded in the journal. Result: ok, unknown mode, same. |
| `player.abilities(player) -> set` | `derive_abilities(reg, mode, inv)` via `has_ability(c, a)` | `players.read` | Read-only: the mode's profile plus equipment. |
| `player.mode(player) -> id` | `Client.mode` | `players.read` | |
| `player.damage(player, amount, source)` | `damage(s, target, amount, source) -> Damage_Result` | `players.damage` | Checks `invulnerable`, `pvp`, `health`; `source` has a kind and optional attacker and weapon. Death messages come from the source. |
| `player.heal(player, amount)` | `heal_player` | `players.damage` | |
| `player.respawn(player)` | `respawn(s, c)` | `players.respawn` | Valid only while dead. |
| `rules.get(name)` / `rules.set(name, value, cause)` | `rules_get`, `rules_set` (the table that `/rule` uses) | `rules.read` / `rules.set` | Journalled with the actor. `rules.set` needs the rule's name in the pack's grant list (M52). |
| `kit.give(player, kit)` | `kit_give(s, c, kit)` | `item.give` | A kit is data (`Mode_Def.kit` or `data/kits`). |

## Events (M26's stream; M52's `Script_Event`)

| Event | Fields | Raised by |
| --- | --- | --- |
| `mode_changed` | player, from, to, cause | `set_game_mode`, once per real change |
| `damaged` | player, amount, source kind, attacker, weapon, health after | `damage`, when it applied |
| `died` | player, source kind, attacker, weapon, message | `die` |
| `respawned` | player, position, kit given | `respawn` |

Rules for the VM's wrapper: it passes a pack's id as the actor (`script:<pack>`) into the
`cause` argument; it never calls `die` or sets `Client.health` (they are not natives); it
rate-limits `damage` as it limits other effects (M52's budget); a script that asks for
a capability it was not granted gets M52's refusal, not a silent no-op. Permissions
(`voxiverse.command.*`) are about who may *ask* through commands; a script's authority is
its capabilities; abilities are what the character can do. The three stay separate.
