package worldgen

// Column_Cache keeps what a chunk column's chunks share (its climate, and
// the trees standing in it), which depends only on (x, z): one chunk
// column is some 24 chunks high, and without it every chunk of it worked
// the same noise out again (most of generating one). Each worker has its
// own (no locking); direct-mapped by column. An entry knows the generator
// it was made by (kind, seed, parameters), so a changed generator (live
// tuning) never reads stale columns.

COLUMN_CACHE_SIZE :: 64 // entries (each about 7 KiB)

Column_Cache :: struct {
	entries: [COLUMN_CACHE_SIZE]Column_Entry,
}

@(private)
Column_Entry :: struct {
	gen:        Generator,
	column:     [2]i32,
	used:       bool,
	has_cols:   bool,
	has_trees:  bool,
	cols:       Columns,
	trees:      [MOST_TREE_TRIES]Tree,
	tree_count: int,
}

// column_entry: column's entry, emptied when it held another column or
// another generator's.
@(private)
column_entry :: proc(cache: ^Column_Cache, gen: ^Generator, column: [2]i32) -> ^Column_Entry {
	h := u32(column.x) * 0x9e37_79b1 ~ u32(column.y) * 0x85eb_ca77
	e := &cache.entries[(h ~ h >> 15) % COLUMN_CACHE_SIZE]
	if !e.used || e.column != column || e.gen != gen^ {
		e.used, e.column, e.gen = true, column, gen^
		e.has_cols, e.has_trees = false, false
	}
	return e
}

// cached_trees appends the trees standing in column.
@(private)
cached_trees :: proc(cache: ^Column_Cache, gen: ^Generator, column: [2]i32, out: ^[dynamic]Tree) {
	if cache == nil {
		place_trees(gen, column, out)
		return
	}
	e := column_entry(cache, gen, column)
	if !e.has_trees {
		found := make([dynamic]Tree, context.temp_allocator)
		place_trees(gen, column, &found)
		assert(len(found) <= MOST_TREE_TRIES)
		copy(e.trees[:], found[:])
		e.tree_count, e.has_trees = len(found), true
	}
	append(out, ..e.trees[:e.tree_count])
}

// cached_columns: column's climate (valid until the cache is next used).
@(private)
cached_columns :: proc(cache: ^Column_Cache, gen: ^Generator, column: [2]i32) -> ^Columns {
	if cache == nil {
		cols := new(Columns, context.temp_allocator)
		columns_fill(&gen.params, gen.seed, column, cols)
		return cols
	}
	e := column_entry(cache, gen, column)
	if !e.has_cols {
		columns_fill(&gen.params, gen.seed, column, &e.cols)
		e.has_cols = true
	}
	return &e.cols
}
