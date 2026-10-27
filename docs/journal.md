# The edit journal (M45)

Every block a world's state changes is recorded with its cause: who (an actor), through
what (a system), and how (the mechanism of this one change). A bad script's or griefer's
changes are undone from it, replay checks that no write bypassed it, and one enforcement
point (`admit`) sits on the way in.

## The pipeline rule

Blocks of a server's chunks change in one way: `set_block(w, p, b, act, by)` and
`bulk_edit(w, e, act)` (`server/changes.odin`, `server/edits.odin`). The `act` is
required: `Act{action, how}`. Inside, per block: `act_current` (a freed action becomes the
world's), `admit`, the write, `journal_entry` (or `journal_batch` for a bulk edit's chunk).
`build check` fails on `chunks_set_block(` or `game.chunk_set(` in any non-test file of
`server/` other than `chunks.odin`, `changes.odin` and `edits.odin`:

    server/x.odin:12: block write outside the edit pipeline: use set_block or bulk_edit with an Act (docs/journal.md)

Where each path gets its action:

| Path | Action | how |
|---|---|---|
| `apply_edit` break, place | `action_begin(w, actor_of(s, c), .Hand)` per edit | Hand |
| tilling, then the moist farmland | one `.Till` action | Till |
| `/fill /replace /sphere /setblock` | `.Command`, with the command text | Command |
| `structure paste` | `.Structure`, with the command text | Structure |
| a rocket | `.Explosion` made at `fire`, kept in `Entity.action` | Explosion |
| a plant losing its footing | the action of the change under it | Support |
| flowing water | `Update.action`: the action of the change that woke it; `action_world(w, .Liquid)` when woken by a chunk loading | Liquid |
| random ticks, gates, grazing | `action_world(w, <system>)`: the world's own, one per system per tick | Random_Tick, Gate, Graze |
| rollback, undo, redo | their own action | Rollback, Undo, Redo |

Consequences inherit their cause, so rolling back a griefer also restores the water they
released, and rolling back someone else's change next to water they woke leaves that water
(it is theirs: reported as `kept`).

Entities, container contents and inventories are not journaled (M48, M50, M31's ledger);
rules, the clock and generator parameters get marker records only (`Params`).

## Time

`age_of(s)` = `Server.age_base + s.tick`: the universe's tick count across runs
(`universe.cfg`'s `age`). Rollback times are in ages (`10m` is 18 000), never the wall
clock. `Tick` records carry the wall clock for people.

## On disk

`worlds/<address>/journal/00000001.vxj`, ... A segment ends at 4 MiB, when the world
closes, and a new one begins at each server start. Format (`common/game/journal.odin`,
varints as `game.Writer`):

    header:  "VXJN" u32 format(1) u32 seq u64 first_age u8 flags u32 crc32(header)
    records: u8 type, varint length, payload, u32 crc32(type, length, payload)
      1 Tick     varint64 age, svarint64 unix_ms
      2 Actor    varint index, u8 kind, string name (<= 64)
      3 Action   varint id, varint actor, u8 system, varint64 age, u8 bypass, string command (<= 256)
      4 Changes  svarint cx cy cz, varint count (1..4096),
                 count x { varint local index, varint old, varint new, svarint action delta, u8 how }
      5 Save     varint64 age
      6 Params   varint64 age

Actors and actions are declared in a segment before their first use there, so every
segment reads alone. Entries are grouped by tick (a `Tick` record per age) and by chunk,
in the order appended, so per position the order is the order of the changes. A reader
stops at the first bad or short record (a torn tail) and reports its offset.

`world_save` flushes, appends `Save`, then writes `world.cfg` with `journal.segment`,
`journal.offset` and `journal.next_action`. At world start, segments after the recorded one
are deleted and the recorded one is cut to the offset, so the journal never describes
edits the loaded regions do not have. A save from before M45 has no keys: it starts an
empty journal.

### Compaction and retention

`world_save` (`journal_maintain`, `server/journal_compact.odin`) compacts at most one
segment per save: a closed segment whose newest change is older than `JOURNAL_DETAIL`
(108 000 ticks, an hour; judged by the next segment's first age, so a quiet world compacts
late, never early) is rewritten once, with header flag `JOURNAL_COMPACTED`, through
`<seq>.vxj.tmp` and a rename. A run of changes of one block by one action becomes one entry
(the first `old`, the last `new`, the last age and `how`); entries that changed nothing are
dropped; `Save` records go, the `Params` records and the actors and actions still named stay.
Only a run is merged, never changes of other actions in between, so the chain of `old`/`new`
per block still agrees and replay holds. A rollback over compacted history gives the same net
result; what is lost is the time resolution inside the segment's span (a rollback that begins
inside it restores the whole segment's net change). The newest segment, the one `world.cfg`
records, is never touched.

Retention, in the same place: segments whose next one began more than `JOURNAL_KEEP` (7 days)
ago are deleted, then the oldest while the directory is over `JOURNAL_MAX_BYTES` (256 MiB);
never the newest. After retention a replay from the generator is no longer possible; replay
from a snapshot newer than the oldest segment still is. `Config.journal_detail`,
`journal_keep` and `journal_max_bytes` override the three for tests.

## Region protection

`World.protections` (`server/protect.odin`), at most 256 per world, each a name (1-32 of
`[a-z0-9_-]`), a box and member character names; saved in `worlds/<address>/protections.cfg`
(`protect <name> x1 y1 z1 x2 y2 z2 [member ...]`, one per line; written when changed and
retried at save) and hashed in the `Journal` section (by name). A change inside a protection
is admitted when its actor is the world, has `world.protect.bypass` (resolved once per action
by `actor_of`, kept in the action) or is a member (by character name, case folded).
`admit` is the one check; a bulk edit asks once with `admit_box` and skips the blocks inside
the boxes it may not edit (`bulk_edit` returns the count: `fill: 120 blocks changed, 36
protected`). A refused hand edit is an unaccepted `Edit_Result` and the notice `This place is
protected (<name>)`, at most once a second per player. Consequences carry their cause's
action, so water poured outside stops at the edge. Commands (node `world.protect`):
`/protect add <name> [x1 y1 z1 x2 y2 z2]` (the selection with no coordinates), `remove`,
`list`, `member add|remove <name> <character>`.

## Rollback

`/rollback player <name> <time> [radius <n> | sel | world]`, `system <system> <time>
[...]`, `area <time> [radius <n> | sel]`, `status`, `cancel` (node `world.rollback`).
A filter selects entries (actor, `how`, one action, since an age, a box). For each position
the entries in the window are walked newest first: if the newest matches, the position is
restored to the `old` of the oldest entry in the unbroken run of matching entries from the
newest; a non-matching newest entry leaves the position alone (counted as `kept`).

It is a job over ticks: the journal is flushed and the matching queued water updates are
cancelled; the scan reads segments newest first (a world without a save directory scans the
ring); then up to 4096 blocks a tick are applied, in chunk then block order, each only if the
block is still what the run left (`expect`); entries appended meanwhile are folded in first,
so water that moved is not left behind. Chunks not loaded are loaded from the save, 16 a tick
at most and while 64 slots are free. Progress every 5 s and at the end:
`Rollback done (action 812): 12345 restored, 12 kept (changed by others since), 0 missing`.

Not restored: dropped items and spilled chest contents (a restored chest is empty),
entities, inventories.

`/undo [n]`, `/redo [n]` (node `world.edit.undo`, not in `default` or `mod`): undo rolls back
the caller's last n actions by action id over the ring, as an `Undo` action; redo rolls back
the `Undo` action. A new action of the caller clears its redo. An action whose first entry has
left the ring is "too old to undo; use /rollback". `/history x y z` lists the last 8 changes
at a block from the ring.

## Replay

`journal_replay(w, snapshot_dir, since)` applies the entries after an age onto a snapshot
(a saved copy of the world's directory, or `""`: the generator), checking each `old`
against what the replay holds, and compares the chunks with the live world's. The first
mismatch is a write that bypassed the pipeline and is named with its position. A `Params`
record in the interval refuses the replay.

## Cost

`Config.journal_timed` (tests) counts the journal's cycles. `test_journal_cost` (CI:
"Journal cost, optimized") holds it to 5% of the ticks' time and 0.5 ms a tick on average
over a flood, 20 blasts and ten big fills.
