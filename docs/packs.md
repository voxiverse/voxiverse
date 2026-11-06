# Packs and the trust boundary

A pack is a directory of JSON and asset files that adds content (blocks, items, textures,
sounds, recipes, models, game modes, channels, simulation rules, structures) without code. The
base game is itself a pack (`assets/packs/voxiverse`, namespace `voxiverse`). This page says how
packs are laid out, loaded and sent, what a pack's rule language can do, and what the engine
treats as untrusted. The script language is in [script.md](script.md); the journal that records
every change in [journal.md](journal.md).

## Layout

```
<namespace>/
  pack.json        format, namespace, version, title, description, requires
  assets/          client-only: textures (PNG), sounds (Ogg)
  data/            both sides: blocks, items, tags, recipes, shapes, models, game modes,
                   channels, simulation rules
  server/          server-only: structures (.vxs)
```

The server sends `pack.json`, `assets/` and `data/` and nothing else; `server/` never leaves it.
A client building a registry from a pack refuses a `server/` file. The content check covers
everything both sides build from `data/`. A custom item's definition lives in `data/` (the client
must show it); anything the client must not see lives in `server/`. The directory name is the
pack's namespace; ids read `namespace:name`.

Each registry kind has one directory and one JSON object of named definitions per file
(`KIND_DIRS` in `common/game/registry_load.odin`):

| Kind | Directory |
|---|---|
| Texture, Sound | `assets/textures`, `assets/sounds` (each with a `blocks.json` naming the files or generators) |
| Block, Item, Block tag, Item tag, Recipe | `data/blocks`, `data/items`, `data/block_tags`, `data/item_tags`, `data/recipes` |
| Shape, Model, Game mode | `data/shapes`, `data/models`, `data/game_modes` |
| Channel, Sim rule, Entity | `data/channels`, `data/sim`, `data/entities` |
| Structure | `server/structures` |

A file elsewhere in a pack is refused with the layout above in the message. Pack JSON is RFC 8259
plus `//` and `/* */` comments and trailing commas; objects keep source order and every value keeps
its line and column, so every error is a `Pack_Error` of the form
`<pack>/<file>:<line>:<column>: <what is wrong>; <the fix>`. A registry has one id space per kind,
assigned in load order; packs load in the order the universe lists them.

`./build.sh packs [<dir>...]` loads the base pack plus the given pack directories the way a
universe does, prints every error and a summary with the registry hash (`tools/packcheck`).

## Entity kinds

Entity kinds are `data/entities/*.json` entries (`common/game/registry_entities.odin`); the base
pack's are `animals.json` (`sheep`) and `engine.json` (`rocket`, `item`, `player`), with the
numbers the engine's tables hold today. A kind is a `Kind_Id` (its registry index + 1; 0 is none)
and its `Kind_Info` is `reg.kinds[id - 1]`. Fields, each checked when the registry is built
(a `Pack_Error` at the value, saying the fix):

- `box` `[width, height]`, each 0.1..4; `health` (default 1); `saved`, `summonable`, `hittable`.
- `physics` (`none`, `walker`, `item`, `projectile`) with its block of numbers (`walker`, `item`
  or `projectile`), required with it and refused without it.
- `brain` (`none`, `grazer`; `grazer` needs `walker`), `with` (`wool`, `genes`, `breeding`),
  `looks` (at most 16; each is computed from a component the kind must have in `with`).
- `fields`: at most 8 saved numbers, `{"name": {"type": "u8"|"u16", "min": n, "max": n}}`.
- `model`: `sheep`, `rocket`, `item`, `player` or `{"box": [r, g, b]}`.
- `spawn`: natural spawning (`on` a block matcher, `day` fractions, `every` ticks, `chance`, `cap`,
  `within`, `distance`, `group`), all required.

The server's entities do not read these yet; moving them onto kinds is the rest of M50e.

## Simulation rules

Simulation rules are `data/sim/*.json` entries. Their behaviour runs on the server only
(`server/core/sim_interp.odin`), and every write goes through `set_block` and `set_channel` like
any change, so the journal, the wakes and the clients' updates are the engine's.

- `"behaviour": "flow"` is a fluid (levels, falling block, delay, reach, whether sources form).
- `"list"` is an ordered block list; a flow rule is a list of its blocks, so no fact is written
  twice.
- A statement rule has `blocks`, a `trigger` (`scheduled` or `random`), `wake` conditions
  (`placed`, `neighbour`, `load`) and a `do` array. Each statement, condition and expression is a
  short string in a bounded language lexed by `common/game/sim_lexer.odin` (at most
  `MAX_RULE_TOKENS` = 64 tokens, no escapes, so a token's column is exact); the envelope (the
  statement tree with `if`/`then` and `repeat` objects) is JSON. `assets/packs/voxiverse/data/sim`
  has working examples (`growth.json`, `water.json`).
- Everything that bounds a rule is checked when the registry is built, each refusal one
  `Pack_Error` at the token at fault: reach `RULE_REACH` = 8 cells, cost `RULE_MAX_COST` = 4096,
  `RULE_MAX_STATEMENTS` = 64, nesting `RULE_MAX_DEPTH` = 4, `RULE_MAX_PICKS` = 4, `RULE_MAX_BOX` =
  9, `RULE_MAX_BLOCKS` = 16 per rule, `RULE_MAX_LIST` = 64, `RULE_MAX_ERRORS` = 20 reported.
  The compiled program is a flat, index-linked `Rule_Program` that points into nothing but the
  registry's arena. The interpreter has no recursion and no loop but `repeat`, and allocates
  nothing.
- Data rules are deterministic ([determinism.md](determinism.md)); they draw randomness only from
  the tick's stream.

Rules are pack JSON, not a file format of their own, so they reuse the registry, the pack hash,
hot reload, packs over the wire and the pack fuzz targets.

## Packs on the wire

A universe's packs are fixed while it runs: `universe.cfg`'s `packs` line lists their namespaces
(the base pack is always first and never listed), each in `<universe>/packs/<namespace>/`, and the
registry is built once at start. It never grows, and no pack is sent in the middle of a session.

- **Archive.** `pack_archive_make` writes one pack as one canonical file: `VXPK`, a version,
  a file count, then per file in byte order of path the path, the size and the bytes, so the
  same files always give the same bytes. The pack's hash is the SHA-256 of that archive.
- **Join.** After the `Proof` the server sends `Packs`: every pack in the universe (up to
  `MAX_PACKS` = 32) with its size and hash, in load order, and the registry hash they make. The
  client takes what it has in its cache (`<cache>/<sha256>.vxpack`, least recently used dropped
  past 256 MiB), asks for the rest with `Pack_Want`, and receives `Pack_Part`s (1100 bytes each,
  at most 32 KiB per tick per client). It checks each pack's size and hash as its last part
  arrives and builds the registry; the registry hash must equal the server's. A client spends at
  most 120 s in this phase. Every pack is sent whether or not the player visits the worlds that
  use it.
- **Limits.** An archive lists at most `MAX_PACK_FILES` = 1024 files of at most `MAX_PACK_PATH`
  = 128 bytes of path, a file is at most `JSON_MAX_FILE` = 1 MiB, a pack at most `MAX_PACK_BYTES`
  = 16 MiB. `pack_archive_read` refuses every way an archive can be wrong with a message: it came
  over the network.
- **Hot reload** (development builds, `Config.pack_watch`; the owner's `pack reload` reloads at
  once). The server watches the base pack's source directory and the universe's `packs/`; a reload
  that would change the number of any block, item, texture or sound set is refused (the registry
  never grows), the old registry stays on any error, and the swap waits until no chunk job and no
  save is reading it. `Packs_Changed` carries the new registry hash to a client on the same
  machine, which builds the same registry from the same files; no pack file is sent.

## Assets

A pack's PNGs and Oggs come over the network, so they are read by bounds-checked Odin only and
checked when the registry is built (`common/game/pack_assets.odin`):

- A block texture is exactly 16 x 16 pixels, at most `MAX_PNG_BYTES` = 64 KiB. The header is read
  before the decoder (a PNG of a huge size packs into a few bytes); `core:image/png` decodes
  it into RGBA8.
- A sound is an Ogg of at most `MAX_OGG_BYTES` = 1 MiB and `MAX_SOUND_SECONDS` = 5 s, scanned for
  its length and decoded once by `common/ogg`, so the client only plays a file that passed.
  File-based sound sets total at most `MAX_PACK_SOUND_FILES` = 128 files over all packs.
- `common/ogg` returns an `Error` for anything malformed, with every size a constant and one
  allocation. Both decoders are fuzzed ([fuzzing.md](fuzzing.md)).
- A pack directory read from disk (`server/packs`) refuses symlinks, so a pack reads only what is
  inside its directory, and skips files past the limits without reading them.

## What is untrusted

The engine is a replicated, deterministic simulation of a voxel field and its entities, in which
every change has a cause and a history. Four things are untrusted: scripts and packs (buggy or
hostile), player input, generated text and names, and the pack transport.

| Surface | What holds |
|---|---|
| Pack transport | The archive limits and hash check above; JSON limits (`JSON_MAX_DEPTH` 32, `JSON_MAX_STRING` 4096, `JSON_MAX_ENTRIES` 4096, `JSON_MAX_FILE` 1 MiB); rule bounds checked at load. |
| Decoders | Odin only: pack PNGs by `core:image/png` after a header check, pack Oggs by `common/ogg`. No C parses a hostile file; a pack's only code is a rule program the registry compiles. |
| Network messages | Validated at the edge (ground rule 6 in [design.md](design.md)): ranges, length caps, a schema hash at join, fuzz targets for every decoder. |
| Script VM | Memory-safe by construction, deterministic (no ambient clock, random, hash order or I/O), metered in instructions, memory and call depth, state serializable ([script.md](script.md)). Scripts are never transpiled or compiled to native code. |
| Script authority | A script has no ambient authority. `server/core/script_api.odin` holds the typed natives for the party systems, each behind a named capability (`players.read`, `players.mode`, `rules.read`, `rules.set`, `players.damage`, `players.respawn`); a native records its cause as `script:<pack>` in the journal. The VM runs in `build script`, the benchmarks and the fuzz targets; the server does not run scripts. |
| Items | Every item entering or leaving what the server holds is one `ledger` call with a reason (a faucet counts positive, a sink negative); an audit sums everything held against the entries and reports a mismatch without fixing it. |
| Damage from bad changes | Every block change carries an actor, a system and a mechanism in the journal; a bad actor's changes are undone from it ([journal.md](journal.md)). |
| Telemetry | Aggregate behaviour only: no names, chat text or addresses ([telemetry.md](telemetry.md)); the consent question is off by default (`telemetry.ask` = 0) and nothing is sent while it is unanswered. |

## Workshop packs

With Steam on (docs/platforms.md, "Steam"), the packs a player subscribed to on the Steam
Workshop are one more pack source beside the local ones; with Steam off the source does not
exist (`client/steam/workshop.odin`).

- **Layout.** An item's folder (Steam names it by the item's id) holds the pack as a sub-folder
  named by its namespace, in the layout above. An item with no pack folder is refused.
- **Trust.** Nothing from the Workshop is trusted more than a local pack: its folder is read by
  `server/packs` (symlinks and files past the limits refused) and the result goes through the
  same `registry_build`, so a malformed item fails with the errors a local pack gets.
- **Where a listed pack is found.** `universe.cfg` lists packs by name as always; there is no
  format change. A listed pack is looked for in the universe's `packs/<namespace>/`, then in the
  local packs folder (`<user data>/voxiverse/local_packs/<namespace>/`), then in the subscribed
  Workshop items. The client reads the last two once per session and gives them to the server
  (`Config.available_packs`) and to `registry_for_dir` alike, so both build the same registry. A
  subscribed item no universe lists is never loaded.
- **A bad item** is treated like a bad local pack: a universe that lists it does not open, and
  the `Pack_Error` (or the read problem, with "Workshop item <id>") names it. It is never skipped,
  because a world built on a pack must not open without it. An item with no pack folder names no
  pack, so nobody can list it: that is logged, not refused. Exporting a universe still takes only
  the packs in its own `packs/` folder.
- **Publishing.** The console command `workshop_publish <namespace>` publishes a pack of the local
  packs folder. `workshop_publish_info` takes the title and description from its `pack.json` and
  the preview from a `preview.png` of at most 1 MiB in its folder; `workshop_publish` hands them to
  Steam. The real Steam does not publish yet; the fake records the call. A menu entry waits for a
  pack screen.
