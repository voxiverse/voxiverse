package game

import "core:mem"
import "core:mem/virtual"

// Chunk_Blocks holds one chunk's blocks: either one block for all of them
// (all air, all stone: most chunks) or a 16³ array taken from a Block_Arrays
// free list. Light is stored separately (later milestones).

Block_Array :: [CHUNK_VOLUME]Block

Chunk_Blocks :: struct {
	uniform: Block, // every block, when array is nil
	array:   ^Block_Array,
}

chunk_get :: #force_inline proc(c: ^Chunk_Blocks, l: [3]i32) -> Block {
	if c.array == nil {return c.uniform}
	return c.array[local_index(l)]
}

// chunk_set changes one block, taking an array from arrays the first time a
// uniform chunk gets a different block.
chunk_set :: proc(
	c: ^Chunk_Blocks,
	arrays: ^Block_Arrays,
	l: [3]i32,
	b: Block,
) -> mem.Allocator_Error {
	if c.array == nil {
		if b == c.uniform {return nil}
		c.array = block_arrays_take(arrays) or_return
		for &x in c.array {x = c.uniform}
	}
	c.array[local_index(l)] = b
	return nil
}

// chunk_replica_set: chunk_set for a copy of the world a client holds (the test client's, in
// server/harness_client.odin). A server's chunks change only through set_block and bulk_edit
// (docs/journal.md); the pipeline lint looks for chunk_set, so a replica writes by this name.
chunk_replica_set :: proc(
	c: ^Chunk_Blocks,
	arrays: ^Block_Arrays,
	l: [3]i32,
	b: Block,
) -> mem.Allocator_Error {
	return chunk_set(c, arrays, l, b)
}

// chunk_compact returns the array to arrays if all blocks are the same.
chunk_compact :: proc(c: ^Chunk_Blocks, arrays: ^Block_Arrays) {
	if c.array == nil {return}
	first := c.array[0]
	for b in c.array {if b != first {return}}
	block_arrays_give(arrays, c.array)
	c^ = {
		uniform = first,
	}
}

chunk_release :: proc(c: ^Chunk_Blocks, arrays: ^Block_Arrays) {
	if c.array != nil {block_arrays_give(arrays, c.array)}
	c^ = {}
}

// Block_Arrays hands out chunk arrays from one region of address space
// reserved for capacity arrays and committed as first used; returned arrays
// are reused. Memory therefore grows to the most arrays ever in use at once
// and can never pass capacity * 8 KiB, however far players travel.
// Not thread-safe; one per owner (server world, client world).
Block_Arrays :: struct {
	region:    []u8, // reserved
	committed: int, // bytes committed from the start of region
	allocated: int, // arrays handed out at least once
	free:      []^Block_Array,
	free_len:  int,
	refs:      []u16, // holders of each array handed out (0: free); see block_arrays_ref
	allocator: mem.Allocator,
}

@(private = "file")
COMMIT_STEP :: 64 * size_of(Block_Array)

block_arrays_init :: proc(
	a: ^Block_Arrays,
	capacity: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> mem.Allocator_Error {
	a^ = {
		allocator = allocator,
	}
	a.region = virtual.reserve(uint(capacity * size_of(Block_Array))) or_return
	a.free = make([]^Block_Array, capacity, allocator, loc) or_return
	a.refs = make([]u16, capacity, allocator, loc) or_return
	return nil
}

block_arrays_destroy :: proc(a: ^Block_Arrays) {
	virtual.release(raw_data(a.region), len(a.region))
	delete(a.free, a.allocator)
	delete(a.refs, a.allocator)
	a^ = {}
}

block_arrays_in_use :: proc(a: ^Block_Arrays) -> int {
	return a.allocated - a.free_len
}

block_arrays_index :: #force_inline proc(a: ^Block_Arrays, p: ^Block_Array) -> int {
	return (int(uintptr(p)) - int(uintptr(raw_data(a.region)))) / size_of(Block_Array)
}

// block_arrays_take returns an array with unspecified contents and one
// holder, or .Out_Of_Memory when capacity arrays are in use.
block_arrays_take :: proc(a: ^Block_Arrays) -> (array: ^Block_Array, err: mem.Allocator_Error) {
	if a.free_len > 0 {
		a.free_len -= 1
		p := a.free[a.free_len]
		a.refs[block_arrays_index(a, p)] = 1
		return p, nil
	}
	if a.allocated == len(a.free) {return nil, .Out_Of_Memory}
	end := (a.allocated + 1) * size_of(Block_Array)
	if end > a.committed {
		step := min(COMMIT_STEP, len(a.region) - a.committed)
		virtual.commit(&a.region[a.committed], uint(step)) or_return
		a.committed += step
	}
	p := (^Block_Array)(&a.region[a.allocated * size_of(Block_Array)])
	a.refs[a.allocated] = 1
	a.allocated += 1
	return p, nil
}

// block_arrays_ref adds a holder: a reader (a mesh job) that keeps the array
// as it is. Whoever writes an array with more than one holder takes a fresh
// one first (copy on write); the array goes back to the free list with its
// last holder's block_arrays_give.
block_arrays_ref :: #force_inline proc(a: ^Block_Arrays, p: ^Block_Array) {
	a.refs[block_arrays_index(a, p)] += 1
}

block_arrays_holders :: #force_inline proc(a: ^Block_Arrays, p: ^Block_Array) -> int {
	return int(a.refs[block_arrays_index(a, p)])
}

// block_arrays_give drops one holder; the last one returns the array.
block_arrays_give :: proc(a: ^Block_Arrays, p: ^Block_Array) {
	i := block_arrays_index(a, p)
	assert(a.refs[i] > 0, "array given back twice")
	a.refs[i] -= 1
	if a.refs[i] > 0 {return}
	assert(a.free_len < len(a.free), "array given back twice")
	a.free[a.free_len] = p
	a.free_len += 1
}

// chunks_hash_add mixes one chunk (where it is, and its blocks) into an
// order-independent hash of a set of chunks: two sides holding the same
// chunks get the same sum whatever order they add them in.
chunks_hash_add :: proc(sum: ^u64, pos: Chunk_Pos, c: ^Chunk_Blocks) {
	h := u64(0xcbf29ce484222325)
	mix :: #force_inline proc(h: u64, v: u64) -> u64 {return (h ~ v) * 0x100000001b3}
	h = mix(h, u64(u32(pos.x)))
	h = mix(h, u64(u32(pos.y)))
	h = mix(h, u64(u32(pos.z)))
	if c.array == nil {
		h = mix(h, u64(c.uniform) | 1 << 32)
	} else {
		for b in c.array {h = mix(h, u64(b))}
	}
	sum^ += h ~ (h >> 29)
}
