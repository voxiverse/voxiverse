# Server commands, permissions, accounts and chat

Every change to the world is made by the server; permissions decide who may run what.
This document lists the server commands, the permission model, accounts and characters,
chat and community commands, and the statistics. Worlds, items and generation are in
[world.md](world.md).

## Server commands

Server commands are entered as `/command` in the chat or in the developer console (a plain
word in the console belongs to the client; see [debugging.md](debugging.md#the-developer-console)).

Wherever a command takes a player, `@s` denotes you, `@p` the nearest other player, `@r` any
player, and `@a` every player, where that is meaningful (`/give @a`, `/tp @a @s`).
Coordinates may be relative (`~`, `~5`, `~-2`); the first of a run is x, then y, then z.
`/help` lists the commands you may use, and `/help <command>` shows a command's usage and
permission. Minecraft's command names are accepted where the equivalent exists: `/tell`, `/w`,
`/say`, `/gamerule`, `/teleport`.

### World and time

| Command | Effect |
|---|---|
| `/time set <t>`, `/time add <hours>`, `/time query` (and `/time <t>`) | The time of day: `sunrise day noon sunset night midnight` or `0..1` (`world.time`). |
| `/rule [name] [value]` (`/gamerule`) | Lists the world's rules, shows one, or sets one (setting needs `voxiverse.command.rule`): `random_tick_speed`, `drops`, `reach`, `daylight_cycle` (false stops the clock), `day_length` (seconds per day), ... A change is journalled and announced to the world. |
| `/gamemode [mode] [player]` | Shows the mode, changes your own, or another player's. What a player may ask for is a permission (`voxiverse.command.gamemode.self`, `.others`); what the character can do is the mode's abilities. |
| `/setblock <x y z> <block>` | Sets one block, through the bulk edit pipeline (`world.edit.bulk`). |
| `/cell <x y z> [<channel> [<value>]]` | Shows every channel's value at a cell, one channel's, or sets one (clamped to its maximum; a computed channel is read-only). |
| `/pos1 [x y z]`, `/pos2 [x y z]`, `/sel` | Sets the selection's corners (the block you are looking at, within 128 blocks, or the given coordinates), kept by the server and drawn as a box / clears the selection. |
| `/fill [box] <block>`, `/replace [box] <from> <to>`, `/sphere [x y z] <radius> <block>` | Bulk edits (`world.edit.bulk`; at most 64x64x64 blocks) of the selection, or of a given box `x1 y1 z1 x2 y2 z2`. The server applies them in one pass and sends each touched chunk whole, after a `Bulk_Begin` stating how many follow. |
| `/structure save <name> [box] [clear]`, `/structure paste <name> [x y z] [turns]`, `/structure list` | Keeps the selection (or a box) as `<world>/structures/<name>.vxs` (air is kept as void, so pasting leaves what is there; with `clear`, as air) / places one at pos1 (or x y z) through the bulk edit pipeline, turned 0-3 quarters (`world.structure`). |
| `/regen [radius]` | Regenerates the unedited chunks within a radius (1-8 chunks) from the generator in its current configuration (`world.gen`). |
| `/summon [kind] [count]`, `/kill <kind\|all> [radius]` | Summons sheep in front of you (`world.summon`) / removes the entities of a kind within a radius (`world.kill`). `/tag <kind\|all> add\|remove <name> [radius]` tags the entity world's entities of a kind within a radius (`world.tag`; for tests and admins). Every playing client also has a `voxiverse:player` entity in its world's entity world (`player_entity_sync`), moved with the player, so the spatial service finds players; it goes when the client travels or leaves. Sheep also appear by themselves in daylight on grass 16-40 blocks from a player, at most 6 near one player, and despawn when nobody is within 80 blocks. |
| `/damage <player> <amount>` | Hurts a player like any damage source: abilities and rules decide the effect. |
| `/seed`, `/packs`, `/pack reload` | The world's seed / the packs the universe runs, in load order / development builds: re-reads the packs' files and swaps the registry (`server.packs`). |
| `/save`, `/export` | Saves the universe (`server.save`) / saves, then writes the universe as one file in `exports/` (`server.export`). |
| `/open_lan`, `/close_lan` | Opens or closes the world to the local network (`server.open_lan`). |

### Teleporting and places

| Command | Effect |
|---|---|
| `/tp <x y z> [yaw pitch]`, `/tp <player>`, `/tp <who> <player>`, `/tphere <player>` | Moves (angles in degrees; `/tp ~ ~10 ~` goes up ten blocks); moving others needs `teleport.tp.others`. |
| `/spawn`, `/setworldspawn [x y z]` | Returns to the world spawn; sets where new players arrive. A new world's spawn is found by the generator's search (dry open land, no tree or structure nearby), chosen once and kept in `world.cfg`. |
| `/locate [biome\|structure] <name>` | Takes you to the nearest biome or structure (`teleport.locate`): `tower`, `ruin`, `well`, `dungeon`, `gate`. |
| `/home [name]`, `/sethome [name]`, `/delhome <name>`, `/homes` | Your homes (`teleport.home`; at most your role's `max_homes` metadata, 3 for `default`). |
| `/warp [name]`, `/warps` / `/setwarp <name>`, `/delwarp <name>` | The world's warps (`teleport.warp` / `teleport.warp.set`). |
| `/tpa <player>`, `/tpahere <player>`, `/tpaccept`, `/tpdeny` | Requests to go to someone, or for them to come to you (`teleport.tpa`; two minutes to answer). |
| `/where`, `/goto <lat lon \| place>` | On a planet world (`worldgen.planet`): the latitude, longitude and elevation under you / to the surface at a latitude and longitude, or a named place (everest, k2, sahara, amazon, nile_delta, alps, greenland, antarctica, atacama, siberia, great_barrier_reef, grand_canyon; `PLANET_PLACES`). |
| `/back`, `/top` | Where you were before your last teleport / up onto the highest block. |

`/travel`, `/address` and `/worlds` are in [world.md](world.md#worlds). Homes, warps, `back` and `tp` remember their world and travel to it.

### Edit history

| Command | Effect |
|---|---|
| `/interventions [radius]` | Lists the last 20 of the world's interventions (a radius in blocks: those within it of you; `world.interventions`). |
| `/history <x y z>` | Lists the last changes at a block (`world.rollback`). |
| `/undo [n]`, `/redo [n]` | Undoes or redoes your own last n actions (`world.edit.undo`). |
| `/rollback player <name> <time> [radius <n> \| sel \| world]`, `system <system> <time> [...]`, `area <time> [radius <n> \| sel]`, `status`, `cancel` | Reverts changes by a player, a system or in an area, up to a time back (`90s`, `10m`, `2h`, `1d`; `world.rollback`). |
| `/protect add <name> [box]`, `remove <name>`, `list`, `member add\|remove <name> <character>` | Protected regions (no box: the selection; `world.protect`; `world.protect.bypass` edits inside them). |

### Items and players

| Command | Effect |
|---|---|
| `/give <player\|@a> <item> [count]` | `items.give`; what does not fit is dropped at the player's feet. |
| `/clear [player] [item]` | Empties an inventory, or removes one item from it (`items.clear`; another player's: `items.clear.others`). |
| `/wear`, `/item` | Puts on all the armour carried (`items.wear`) / shows the held item, its ID and its stack size. |
| `/audit` | Checks the items held against the ledger (`admin.audit`). |

## Permissions

What a player may do is a set of nodes: dotted lower-case words. The families in use:

- `world.*`: `world.edit` (build), `world.edit.bulk`, `world.edit.undo`, `world.fire`,
  `world.summon`, `world.kill`, `world.tag`, `world.structure`, `world.time`, `world.gen`, `world.spawn`,
  `world.travel`, `world.rollback`, `world.protect`, `world.interventions`;
- `debug.coordinates`: F3 shows position, chunk and the block underneath when
  `rules.show_coordinates` is off;
- `teleport.*`, `chat.*`, `moderation.*`, `info.*`, `items.*`: the nodes the commands use;
- `server.save`, `server.export`, `server.open_lan`, `server.packs`;
- `permissions.edit`;
- `voxiverse.command.*`: `rule`, `damage` and the game-mode commands.

What a character *can do* (flying, invulnerability, `infinite_items`, `catalog`) is not a
permission but an ability its game mode grants (`common/game/abilities.odin`).

### Grants

A grant is a node, `x.*` (x and everything under it), `*` (everything), or `-x` (not x).
A node matches a grant as follows:

1. The most specific grant wins: an exact node beats a wildcard at the same depth, and a
   deeper wildcard beats a shallower one.
2. At the same specificity, the nearer source wins: the character's own grants (and their
   account's), then their roles' grants, then the grants of inherited roles.
3. At the same source, a denial beats an allowance.
4. With no matching grant, the node is not allowed.

### Roles

Roles grant nodes, inherit other roles, and carry metadata (`prefix`, a chat tag such as
`&c&lAdmin`; `max_homes`). Every player has the role `default`; the world's `rules.guest_role`
adds a role for everyone who is not the owner. A new world has three roles:

| Role | Grants |
|---|---|
| `default` | Build (`world.edit`, `world.fire`), basic chat, `teleport.spawn`, `home`, `warp`, `tpa`, `back`, `info.*` except `info.stats.others`, `items.wear`. |
| `mod` | Inherits `default`; all of chat and moderation, and `teleport.tp`. |
| `admin` | Inherits `mod`; `*`. |

The local player of a world played locally, and every player of a server started with
`--cheats`, has every node.

| Command | Effect |
|---|---|
| `/role list`, `/role info <role>` | Lists the roles / shows one role's inherited roles, grants and metadata. |
| `/role grant\|revoke <role> <node>` | Grants or revokes a node (`-x` denies). The first grant creates the role. |
| `/role inherit\|uninherit <role> <role>`, `/role meta <role> <key> [value]`, `/role delete <role>` | Manages inheritance and metadata, or deletes a role. |
| `/user info <player>`, `/user role add\|remove <player> <role>` | Shows a player's roles and grants / adds or removes a role. |
| `/user grant\|revoke <player> <node>`, `/user meta <player> <key> [value]` | Manages the player's own grants (the nearest source) and metadata. |

These commands require `permissions.edit`. Each change is sent to the players it affects and saved in
`<world>/permissions.cfg`:

```
role mod
inherit default
grant chat.*
meta prefix &e&lMod
player Alice
role mod
```

A dedicated server has no owner. To make the first admin, stop the server and edit that file:
add `player alice`, and `role admin` on the next line. A line `account <hex>` grants to every
character of an account.

A client requests only what its grants allow (the console reports "not allowed on this
server"). The server checks again and answers a refusal with a notice, not a disconnect.

## Accounts and characters

The game creates an account on first launch: an Ed25519 key, stored as `account.key` beside
the settings (the private key's 32 bytes in hex). Whoever holds that file holds the account: back it up.

When joining, the handshake proceeds as follows:

1. The client sends the account and a character name (`Hello`).
2. The server sends a random nonce (`Challenge`).
3. The client sends its signature over the nonce (`Proof`). A wrong signature is refused, and a
   proof is valid for one nonce only.

With Steam, `Hello` also carries the player's SteamID and an auth ticket (see
[Joining with a Steam identity](#joining-with-a-steam-identity)); the steps above are the same.

A character name belongs to the first account that plays it in that universe (otherwise the
join is refused: `that name is another account's`). An account has at most 8 characters in a
universe (`MAX_CHARACTERS`). The Multiplayer screen requests the account's characters (`Characters`) to choose or create one;
singleplayer, `join` and scripts play the settings' `name`.

Each character is stored in `characters/<account>/<name>.json`. A `players/<name>.json` from a
universe that predates accounts is assigned to the first account that plays that name.

- `ban` also bans the character's account (`ban_account` in `community.cfg`).
- `account <hex>` in `permissions.cfg` grants to every character of an account.
- `whois` shows a character's account (`moderation.address`).

### Admins

`<universe>/admins.cfg` names the server's admins. One entry per line: an account public key in
hex (64 digits) or `steam:<SteamID64>`; `#` starts a comment. A line that is neither is logged
and skipped. Whoever it names has the role `admin` (in `permissions.cfg`, so its grants are the
world's own) in addition to their other roles. The file is read when the server starts.

A `steam:` line applies only to a join whose Steam ticket the server accepted (`--steam`, see
[Joining with a Steam identity](#joining-with-a-steam-identity)); that is how the owner is admin
on any server by signing in with Steam. A SteamID a client only claims (no ticket, a bad one, a
ticket for another ID) or any ID on a server without Steam is never trusted, and the same account
key without Steam is not the SteamID. The collector reads the same format
([docs/telemetry.md](telemetry.md#admins)).

## Joining with a Steam identity

Steam is one way in, never the only one: a player without it joins with the account key alone.
When the client has Steam on, `Hello` carries an optional SteamID and Steam auth ticket
(`steam_id`, `ticket`; at most 1024 bytes). The client asks Steam for a fresh ticket for every
join.

- **A server without Steam** (the default) ignores them. `voxiverse-server --steam` turns Steam
  on: it needs the Steamworks library beside the executable, otherwise it logs `steam server off:
  ...` and runs as without Steam.
- **A server with Steam** checks the ticket (a game server auth session, closed at once: only the
  result is used) before it sends the `Challenge`. Steam's refusal is the join's refusal and the
  client shows its reason: `Steam refused your ticket`, `Steam says your ticket is for another
  game`, `your Steam ticket has expired; restart the game and join again`, `this Steam account is
  already joining`, `Steam could not check your ticket` (no Steam answer: also a refusal, never
  a wait). A `Hello` without a ticket is not refused.
- **The link.** When the account is proved (after the `Proof`), the SteamID is linked to the
  account key: the first join with a SteamID makes the link. Later, the same SteamID with another
  key is refused with `this Steam account is linked to another account key on this server`. The
  link is checked on a ticket's SteamID, so a player without Steam can still play an account
  that is linked.
- **What is stored.** One line in the universe's `community.cfg` for each link:
  `steam <SteamID64> <account hex>`.
- **To unlink an account**, stop the server, delete its `steam` line in `community.cfg` and
  start it again (a running server writes the file back at its next save). The next join with
  that SteamID links it to whichever key it comes with.

## Chat

`t` opens the chat, and `/` opens it with a command started (the server runs it). The
server processes each line as follows:

- it numbers the line;
- it adds the speaker's tag (their role's `prefix` metadata, and `suffix`) and nickname;
- it keeps formatting codes only where the speaker has `chat.format.color`,
  `chat.format.rgb` or `chat.format.style` (otherwise they are shown as written);
- it drops control characters;
- it allows 5 lines at once (`CHAT_BURST`), then one per second;
- it logs every line (`server chat`).

### Formatting codes

`&0`-`&f` colours, `&#rrggbb` an RGB colour, `&l` bold, `&o` italic, `&n` underline,
`&m` strikethrough, `&r` plain, `&&` a literal `&`.

A colour code clears the styles before it. Each part (tag, name, words) is formatted separately, so no `&r` is needed.

### Chat and community commands

Each requires the permission given in brackets. The commands are modelled on EssentialsX's.

| Command | Effect |
|---|---|
| `/msg <player> <words>`, `/r <words>`, `/me <action>`, `/broadcast <words>` | Whisper, reply to the last whisper, an action, a message to everyone (`chat.msg`, `chat.me`, `chat.broadcast`). |
| `/ignore <player>` | Stops (or resumes) hearing a player (`chat.ignore`). |
| `/mute <player> [30m\|2h\|7d]`, `/unmute <player>` | Mutes for a period or permanently (`moderation.mute`). |
| `/delmsg <player> [count]` | Removes a player's newest lines from everyone's chat (`chat.delete`). |
| `/nick <nickname\|off> [player]`, `/realname <nickname>` | A nickname: a name's letters, formatted as you may format chat, and never another player's name (`chat.nick`; others': `chat.nick.others`). |
| `/motd [set <words>]` | The message of the day, shown on joining (`info.motd`). |
| `/kick <player> [reason]` | `moderation.kick`. |
| `/ban <player> [reason]`, `/tempban <player> <30m\|2h\|7d> [reason]`, `/unban <player>` | `moderation.ban`. |
| `/ban-ip <player\|address> [reason]`, `/unban-ip <address>` | Bans everyone from that address (`moderation.ban_ip`). |
| `/list`, `/whois <player>`, `/seen <player>`, `/afk`, `/status` | Who is present; who someone is (their address, with `moderation.address`); when they were last present; away (moving or speaking ends it); ticks, chunks, memory. |

Nobody may kick, ban or mute a player with `moderation.exempt` (admins, the host). The host
cannot be kicked at all. Nicknames, mutes, ignores, homes, warps, bans, last-seen times and
last addresses, and the message of the day are stored in `<world>/community.cfg`.

## Statistics and events

Everything the server counts or measures is an *event* (`common/telemetry/`: one kind per row of
`KIND_INFO`). `record` (`server/core/stats.odin`) emits the event and adds to the counters the
kind names, the player's and the world's.

Counters have dotted names (`blocks.mined.stone`, `distance.walked` in cm, `time.played` in
seconds, `commands.time`, ...). A parent counter is the sum of the counters below it
(`stats_total`, computed when asked). Counters are stored in the character's file (`"stats"`)
and in `<world>/stats.json`. In the game they are shown by the `/stats [player] [filter]`
command (30 lines in chat; another player's counters need `info.stats.others`) and by the
statistics screen (key `K`, or `screen stats`).

The event log is `<universe dir>/telemetry/YYYY-MM-DD.jsonl`, one JSON object per line: the
time in ms, the tick, the session, the actor (the player's ID), the kind, the world, the
position, and the kind's fields. A dedicated thread writes it; a full buffer drops events and records this in an
`events_dropped` line. A day's log stops at 64 MiB. A scratch world writes nothing.

Client reports (`Client_Info`, `Client_Overlay`, `Client_Perf`) arrive in a
`Telemetry_Report` message, at most six per minute, and are validated. Refusals are counted
in the world's `telemetry.refused`.

[telemetry.md](telemetry.md) describes collection, consent and how to query the log.
