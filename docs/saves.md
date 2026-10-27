# Saves (M46, M46b)

A universe is a directory. Everything the server keeps is in it; nothing else is.

```
universe.cfg            format, seed, home world, kit, generation, age
save.tx                 only while a save is being applied (the commit record)
permissions.cfg, community.cfg
characters/<name>.json
worlds/<address>/world.cfg, entities.cfg, containers.cfg, protections.cfg
worlds/<address>/regions/r.<x>.<z>.vxr      region format 2
worlds/<address>/journal/<seq>.vxj
backups/g<generation>-<UTC time>/, pre-migration-<from>/, pre-restore-g<N>/
lock                                          held while the universe is open (never part of a save)
telemetry/, exports/                          (never part of a save)
```

## A save describes one tick, and does not stall it

A save must describe one tick (items move between inventories, chests and dropped stacks),
yet encoding a big universe takes longer than a tick. `save_begin` (`server/save_slice.odin`)
**captures** at tick T and the following ticks **encode** what was captured:

- At T, at once: the small state (`universe.cfg`, each world's `world.cfg`, entities,
  containers, protections, stats, `permissions.cfg`, `community.cfg`), each dirty character's
  record (without its counters), and for each changed region its unloaded chunks' bytes, its
  tops, and a mark (`Chunk.capture`) on its loaded edited chunks.
- A chunk that changes or unloads while marked is copied first (`chunk_cow`, called from
  `chunks_set_block`, bulk edits and `chunks_unload`: the pipeline is the only writer), so the
  save holds what T held.
- Each tick, `save_slice` encodes chunks and characters until `SAVE_SLICE_US` (2 ms) of the
  tick are used. A region's encoded chunks go to the worker as a `Region_Job`. A character's
  counters are read when it is encoded, a few seconds newer than the inventory beside them:
  the only part of a save not from T.
- A world with a save running does not unload. `stop` (a `save` with wait) finishes the
  running save at once and then saves again. Timing is the wall clock's: how many ticks a save
  takes varies, never what it writes or any hashed state.
- `test_save_200_characters` holds the numbers on the CI runner: capture at most 4 ms, a
  slice tick at most 3 ms, committed within 150 ticks, a blocking save at most 1.5 s.

The journal segment a save names is synced by the worker before the commit, not on the tick.

## One save is one transaction

The batch (`Save_Batch`, `server/save_tx.odin`) goes to the save worker (a stepped server has
no worker: the batch runs inside `save`). The worker:

0. **Compacts and encodes the regions** (below), and syncs the journal segment.
1. **Prepares:** every file is written as `<path>.new` and synced.
2. **Commits:** `save.tx` (the list of renames and deletions, with the CRC of each `.new`)
   is written with `disk_replace`. This is the commit point.
3. **Applies:** each `.new` is renamed over its file, deletions are done, directories
   synced, `save.tx` removed.
4. Makes a rolling backup if one is due.

`store_recover` runs first in `store_open`: a whole `save.tx` is applied again (a rename
whose `.new` is gone and whose file has the recorded CRC was done already); without one,
every `.new` and `.tmp` goes and the previous generation stands. A save is therefore the
old generation or the new one, never a mix, which also keeps a character's stack and the
chest it came from in step (M31's ledger cannot see a mix).

A failed batch is logged, its files wait in `Store.carry` and the next save writes them
again. Files written outside a save (`structure save`, `permissions_changed`) use
`disk_replace`.

All disk access goes through `base/disk.odin` (`disk_write`, `disk_replace`, `disk_rename`,
`disk_link`, ...): durable (`fsync`; `F_FULLFSYNC` on macOS; `FlushFileBuffers` and
write-through renames on Windows) and fault-injectable. `Disk_Faults` tears the Nth
operation and refuses everything after, which `server/crash_test.odin` uses to kill a save
at every operation.

## Compaction

A region file holds only what differs from the generator. On the worker, as each region is
prepared: a chunk a rollback, undo or redo touched since the region was written
(`World.revisit`) is generated again and dropped if it is identical (it is natural again; when
the batch commits the server clears its `modified` flag, if it is still as captured); edited
column tops equal to the natural top are dropped; a region left with nothing is deleted in the
transaction. A region file is the same bytes whenever it is written (tops are sorted).

## Export and import

`.vxu` is one universe in one file (`server/export.odin`): a header, then each file with its
path, size and CRC, then a seal over every path and CRC. The files are a backup's, plus the
journal up to the end its `world.cfg` records (`--no-journal` leaves it out: it names
characters). Not compressed (regions already are palette and runs).

- `voxiverse-server --export <file>` (the universe closed), `--import <file>` (into
  `--universe`, which must not exist); in the game's console `export <save> [file]` (default
  `<saves>/<save>.vxu`) and `import <file> [name]` (a new save, numbered if the name is taken);
  on a running server `/export` (node `server.export`) saves and the worker writes
  `exports/g<generation>.vxu` after the commit.
- Import never trusts the file. It refuses an existing destination, more than 100 000 files,
  a file over 1 GiB, over 16 GiB in all, a universe from a newer game, and any path that is
  absolute or has `..`, `.`, an empty part, `\`, `:`, more than 8 parts, a part over 64 bytes
  or a byte outside `[A-Za-z0-9._-]`, naming the path. It writes `<dest>.import/`, checks every
  CRC and the seal, and renames it to `<dest>`: the universe appears whole or not at all. An
  older universe migrates when it is opened.

## One process per universe

An open universe holds `<universe>/lock` (`flock` on Linux and macOS, a file opened with no
sharing on Windows; `base/lock_*.odin`). A second process (a second game, or the dedicated
server on a save the game has open) fails at open with `the universe is open in another
process (<path>)` before anything is read or written; an export or import-then-open of an
open universe too. The lock holds the owner's process id as text, for that message only. The
OS drops a lock with its process, so a crash leaves none.

## Formats

`SAVE_FORMAT` (5) is in `universe.cfg` and each `world.cfg`. Region format 2 has a header
with an index (position, offset, length and CRC per chunk) and a CRC of the header: a bad
chunk drops only itself; a bad header moves the file aside and loads the region from the
newest backup that has it whole (logged, with what is lost). Text files and character JSON
have no checksums: people edit them, and the transaction makes them whole.

## Migrations

`MIGRATIONS` in `server/migrate.odin` is a chain: entry `from` leaves format `from + 1`.
Opening an older save makes a `pre-migration-<from>` backup, runs every entry from there
on one `Migrator` (writes are staged, not made), then commits all of it as one
transaction. A failing entry commits nothing and the open fails with its reason.

Rules:

- A migration reads only files of its `from` format, with readers frozen beside it (never
  the current reader, which will change: `common/game/save_v1.odin` is region format 1).
- A migration is never edited once released.
- It is tested from a committed fixture of its `from` format (`assets/fixtures/save-v4`,
  written by the code of format 4; `test_v4_save_migrates`). Fixtures are `-text` in
  `.gitattributes`.
- Formats 1-3 predate universes and are upgraded in memory by the format-4 readers.

The next entry is M47's names palette.

## Backups

A backup is a directory of hard links (a copy where the file system has none) to the files
of a committed generation: saves never change a file in place, so the old inode stays with
the backup. Journal segments grow afterwards; the backup's `world.cfg` records where each
ended, and the journal's start cuts them there. Made after the first save of a run, then
every `BACKUP_EVERY` ticks (30 minutes of play); the newest `BACKUP_KEEP` (5;
`--backups N`, 0 for none) stay. `pre-*` backups are never removed by the server.

`voxiverse-server --restore <name|latest>` makes a `pre-restore` backup, then puts the
backup's files in place in one transaction (and deletes the files it does not have).
`voxiverse-server --check` reads every file the way the loaders do and exits 1 on a
problem.
