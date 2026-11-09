package worldgen

// Column_Cache shares what a chunk column's chunks share, with the worldgen
// threads: the climate and the trees standing in it (place_trees and
// column_at are most of generating one). One chunk column is some 24 chunks
// high, and without the cache every chunk of it worked the same noise out
// again. The table is shared, an entry is filled once under its own lock,
// and a reference keeps an entry alive while a caller is using it; when the
// slot a column hashes to is busy, the caller computes without caching
// (rare: a hash collision between two hot columns).
import "core:sync"


COLUMN_CACHE_SIZE :: 64 // entries (each about 7 KiB)

Column_Cache :: struct {
	entries: [COLUMN_CACHE_SIZE]Column_Entry,
}

@(private)
Column_Entry :: struct {
	mu:         sync.Mutex,
	readers:    u32, // live users of the entry (0: evictable)
	filled:     bool,
	trees_only: bool, // trees computed, climate not (columns are lazier)
	gen:        Generator,
	column:     [2]i32,
	scratch:    bool, // a temporary entry, not in the table (never cached)
	cols:       Columns,
	trees:      [MOST_TREE_TRIES]Tree,
	tree_count: int,
}

@(private)
entry_hash :: proc(column: [2]i32) -> u64 {
	u := u32(column.x) * 0x9e37_79b1 ~ u32(column.y) * 0x85eb_ca77
	u = u ~ u >> 15
	u *= 0x85ebca6b
	return u64(u ~ u >> 13)
}

// entry_fill fills the parts of e a caller needs. Highest is computed by the
// caller from everything it has, as the unculled code does. The mutex (and
// its readers count) are preserved: the caller holds the entry's own lock.
@(private)
entry_fill :: proc(gen: ^Generator, column: [2]i32, e: ^Column_Entry, trees_only: bool) {
	e.gen, e.column, e.filled, e.trees_only = gen^, column, true, trees_only
	if !trees_only {
		columns_fill(&gen.params, gen.seed, column, &e.cols)
	}
	found := make([dynamic]Tree, context.temp_allocator)
	place_trees(gen, column, &found)
	assert(len(found) <= MOST_TREE_TRIES)
	copy(e.trees[:], found[:])
	e.tree_count = len(found)
}

// column_entry: the column's entry, filling it first if it was empty or held
// another generator's or another column's. The caller MUST call entry_done
// with the returned entry, which holds a reference for it.
@(private)
column_entry :: proc(
	cache: ^Column_Cache,
	gen: ^Generator,
	column: [2]i32,
	trees_only := false,
) -> ^Column_Entry {
	if cache == nil {
		e := new(Column_Entry, context.temp_allocator)
		e^ = {}
		e.scratch = true
		entry_fill(gen, column, e, trees_only)
		sync.atomic_add(&e.readers, 1)
		return e
	}
	e := &cache.entries[entry_hash(column) % COLUMN_CACHE_SIZE]
	sync.mutex_lock(&e.mu)
	// The entry fits this column, this generator and this mode: hand it out.
	if e.filled && e.gen == gen^ && e.column == column && e.trees_only == trees_only {
		sync.atomic_add(&e.readers, 1)
		sync.mutex_unlock(&e.mu)
		return e
	}
	// The slot is free (or holds a different generator's or column's, evicted
	// here): fill it in place.
	if sync.atomic_load(&e.readers) == 0 {
		entry_fill(gen, column, e, trees_only)
		sync.atomic_add(&e.readers, 1)
		sync.mutex_unlock(&e.mu)
		return e
	}
	// The slot is busy with another column or generator: compute without caching.
	sync.mutex_unlock(&e.mu)
	e = new(Column_Entry, context.temp_allocator)
	e^ = {}
	e.scratch = true
	entry_fill(gen, column, e, trees_only)
	sync.atomic_add(&e.readers, 1)
	return e
}

// entry_done: the caller is finished with the entry.
@(private)
entry_done :: proc(e: ^Column_Entry) {
	sync.atomic_sub(&e.readers, 1)
}
