# Saves (M46)

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
telemetry/, exports/                          (never part of a save)
```

## One save is one transaction

`save` encodes every file on the server thread and hands them as a `Save_Batch` to the
save worker (`server/save_tx.odin`; a stepped server has no worker: the batch runs inside
`save`). The worker:

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
