package store

// Format 9 to 10: a block entity may be a game's machine (common/game/block_entity.odin:
// its kind, record, what it shows, its slots and when it thinks next, saved with its
// chunk). A chunk of format 9 holds no machine and reads as it did, so every file of
// format 9 is one of format 10; the number moves so that a build of format 9 refuses a
// universe that may hold machines rather than misread its chunks.
@(private)
migrate_v9_machines :: proc(m: ^Migrator) -> bool {return true}
