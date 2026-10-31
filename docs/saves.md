# Saves

This document describes how the server stores a universe on disk (M46, M46b).

A universe is a directory. Everything the server keeps is in that directory, and nothing
else is.

## Directory layout

```
universe.cfg            format, seed, home world, kit, generation, age
save.tx                 only while a save is being applied (the commit record)
permissions.cfg, community.cfg
characters/<account>/<name>.json   (players/<name>.json in universes from before accounts)
worlds/<address>/world.cfg, entities.cfg, protections.cfg
worlds/<address>/regions/r.<x>.<z>.vxr      region format 4
worlds/<address>/journal/<seq>.vxj
backups/g<generation>-<UTC time>/, pre-migration-<from>/, pre-restore-g<N>/
lock                                          held while the universe is open (never part of a save)
telemetry/, analytics/, exports/              (never part of a save: analytics/ holds the session recordings)
```

## Capturing a tick without stalling it

A save must describe a single tick, because items move between inventories, chests and
dropped stacks. Encoding a large universe, however, takes longer than a tick. `save_begin`
(`server/save_slice.odin`) therefore **captures** the state at tick T, and the following
ticks **encode** what was captured.

### Capture

At tick T, the server immediately captures:

- the small state: `universe.cfg`, each world's `world.cfg`, entities, containers,
  protections, stats, `permissions.cfg` and `community.cfg`;
- each dirty character's record, without its counters;
- for each changed region: its unloaded chunks' bytes, its tops, and a mark
  (`Chunk.capture`) on its loaded, edited chunks.

A marked chunk that changes or unloads is copied first (`chunk_cow`, called from
`chunks_set_block`, from bulk edits, and from `chunks_unload`; the pipeline is the only
writer). The save therefore holds what tick T held.

### Encoding

Each tick, `save_slice` encodes chunks and characters until `SAVE_SLICE_US` (2 ms) of the
tick has been used. A region's encoded chunks are passed to the worker as a `Region_Job`.

A character's counters are read when the character is encoded, so they are a few seconds
newer than the inventory beside them. They are the only part of a save not taken from tick T.

### Constraints

- A world with a save in progress does not unload.
- `stop` (a `save` with wait) finishes the running save immediately and then saves again.
- Timing follows the wall clock. The number of ticks a save takes varies; what it writes, and
  any hashed state, does not.
- `build bench budgets -check` enforces the following limits on the CI runner: capture at most
  4 ms, a slice tick at most 3 ms, and a blocking save at most 1.5 s.
  `test_save_200_characters` checks that the same scene commits. The number of ticks the
  worker takes is wall-clock time, not a budget.

The journal segment a save names is synced by the worker before the commit, not on the tick.

## The save transaction

Each save is a single transaction. The batch (`Save_Batch`, `server/save_tx.odin`) is passed
to the save worker. A stepped server has no worker; there, the batch runs inside `save`.

The worker performs the following steps:

0. **Compact and encode** the regions (see [Compaction](#compaction)), and sync the journal
   segment.
1. **Prepare.** Every file is written as `<path>.new` and synced.
2. **Commit.** `save.tx` (the list of renames and deletions, with the CRC of each `.new`) is
   written with `disk_replace`. This is the commit point.
3. **Apply.** Each `.new` is renamed over its file, deletions are performed, directories are
   synced, and `save.tx` is removed.
4. **Back up**, if a rolling backup is due.

### Recovery

`store_recover` runs first in `store_open`. If a complete `save.tx` exists, it is applied
again; a rename whose `.new` is missing and whose target has the recorded CRC was already
performed. If there is no `save.tx`, every `.new` and `.tmp` file is removed and the previous
generation stands.

A save is therefore either the old generation or the new one, never a mixture. This also keeps
a character's stack and the chest it came from consistent (M31's ledger cannot observe a
mixture).

A failed batch is logged; its files are held in `Store.carry`, and the next save writes them
again. Files written outside a save (`structure save`, `permissions_changed`) use
`disk_replace`.

### Disk access

All disk access goes through `common/base/disk.odin` (`disk_write`, `disk_replace`, `disk_rename`,
`disk_link`, ...). These operations are durable (`fsync`; `F_FULLFSYNC` on macOS;
`FlushFileBuffers` and write-through renames on Windows) and support fault injection.
`Disk_Faults` tears the Nth operation and refuses every operation after it;
`server/crash_test.odin` uses this to kill a save at every operation.

## Compaction

A region file holds only what differs from the generator. On the worker, as each region is
prepared:

- A chunk that a rollback, undo or redo touched since the region was last written
  (`World.revisit`) is generated again and dropped if it is identical, because it is natural
  again. When the batch commits, the server clears the chunk's `modified` flag if the chunk
  is still as captured.
- Edited column tops equal to the natural top are dropped.
- A region left with nothing is deleted in the transaction.

A region file has the same bytes whenever it is written (tops are sorted).

## Export and import

A `.vxu` file contains one universe (`server/export.odin`): a header, then each file with
its path, size and CRC, then a seal over every path and CRC. The files are those of a
backup, plus the journal up to the end that its `world.cfg` records. `--no-journal` omits
the journal, which names characters. The file is not compressed, because regions are already
encoded as palettes and runs.

### Commands

| Context | Export | Import |
|---|---|---|
| Dedicated server (universe closed) | `voxiverse-server --export <file>` | `voxiverse-server --import <file>`, into `--universe`, which must not exist |
| Game console | `export <save> [file]` (default `<saves>/<save>.vxu`) | `import <file> [name]`: a new save, numbered if the name is taken |
| Running server | `/export` (node `server.export`) saves, and the worker writes `exports/g<generation>.vxu` after the commit | |

### Validation

Import never trusts the file. It refuses, naming the offending path:

- an existing destination;
- more than 100 000 files, a file over 1 GiB, or more than 16 GiB in total;
- a universe from a newer version of the game;
- any path that is absolute or contains `..`, `.`, an empty component, `\`, `:`, more than
  8 components, a component over 64 bytes, or a byte outside `[A-Za-z0-9._-]`.

Import writes `<dest>.import/`, checks every CRC and the seal, and then renames the directory
to `<dest>`. The universe therefore appears whole or not at all. An older universe is
migrated when it is opened.

## One process per universe

An open universe holds `<universe>/lock`: `flock` on Linux and macOS, and a file opened with
no sharing on Windows (`base/lock_*.odin`). A second process, such as a second game or the
dedicated server on a save the game has open, fails at open, before anything is read or
written, with:

```
the universe is open in another process (<path>)
```

Exporting an open universe, or importing and then opening one, fails in the same way. The lock
file holds the owner's process ID as text, for that message only. The operating system
releases the lock with its process, so a crash leaves no stale lock.

## Formats

`SAVE_FORMAT` (6) is recorded in `universe.cfg` and in each `world.cfg`.

### Region format 4

A region file in format 4 stores block entities after each chunk's blocks, and a table of
item IDs after the block names. It has:

- a header with the names of the blocks: every block of the registry, by its number (the
  IDs), followed by the item ID table;
- an index: position, offset, length and CRC per chunk;
- a CRC of the header.

A bad chunk drops only itself. A bad header moves the file aside and loads the region from
the newest backup that holds it intact; this is logged, together with what is lost.

The chunks hold block numbers, and the header records which block each number denoted. A
registry whose numbers have moved (a different pack set, or one pack ordered ahead of another) still
loads them. A name the registry lacks causes the world to be refused at start, naming the
blocks, unless `universe.cfg` says `unknown_blocks = air`, in which case they load as air.

### The edit journal

The edit journal stores block numbers, which are fixed for a universe. A universe's packs are
listed in `universe.cfg` (`packs = a, b`, the directories `packs/<namespace>/`). The base
pack is always first and is never listed.

### Text files

Text files and character JSON have no checksums: people edit them, and the transaction keeps
them whole.

## Migrations

`MIGRATIONS` in `server/migrate.odin` is a chain: the entry `from` produces format
`from + 1`. Opening an older save:

1. makes a `pre-migration-<from>` backup;
2. runs every entry from there on, on one `Migrator` (writes are staged, not performed);
3. commits all of it as one transaction.

A failing entry commits nothing, and the open fails with its reason.

`MIGRATIONS` is currently empty. Before 1.0 nothing is compatible, so M47a (format 6) did not
migrate format 5, nor the formats from before universes, which it previously upgraded in
memory. A universe of an older format is refused with the following message, and nothing in
it is touched:

```
this world was made by an older build; create a new one
```

The chain is retained for the first release that must keep saves. The rules for migrations
are then:

- A migration reads only files of its `from` format, with readers frozen beside it (never the
  current reader, which will change).
- A migration is never edited once released.
- A migration is tested from a committed fixture of its `from` format, written by the code
  of that format. Fixtures are marked `-text` in `.gitattributes`.

## Backups

A backup is a directory of hard links (or copies, where the file system does not support hard
links) to the files of a committed generation. Saves never change a file in place, so the old
inode remains with the backup. Journal segments grow afterwards; the backup's `world.cfg`
records where each ended, and the journal's start truncates them there.

A backup is made after the first save of a run, and then every `BACKUP_EVERY` ticks (30
minutes of play). The newest `BACKUP_KEEP` (5) backups are kept; `--backups N` changes this,
and 0 disables backups. The server never removes `pre-*` backups.

### Restoring and checking

`voxiverse-server --restore <name|latest>` makes a `pre-restore` backup, then puts the
backup's files in place in one transaction, deleting the files the backup does not contain.

`voxiverse-server --check` reads every file the way the loaders do, and exits with status 1
if it finds a problem.
