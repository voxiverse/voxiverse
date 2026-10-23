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
	return nil
}

block_arrays_destroy :: proc(a: ^Block_Arrays) {
	virtual.release(raw_data(a.region), len(a.region))
	delete(a.free, a.allocator)
	a^ = {}
}

block_arrays_capacity :: proc(a: ^Block_Arrays) -> int {
	return len(a.free)
}

block_arrays_in_use :: proc(a: ^Block_Arrays) -> int {
	return a.allocated - a.free_len
}

// block_arrays_take returns an array with unspecified contents, or
// .Out_Of_Memory when capacity arrays are in use.
block_arrays_take :: proc(a: ^Block_Arrays) -> (array: ^Block_Array, err: mem.Allocator_Error) {
	if a.free_len > 0 {
		a.free_len -= 1
		return a.free[a.free_len], nil
	}
	if a.allocated == len(a.free) {return nil, .Out_Of_Memory}
	end := (a.allocated + 1) * size_of(Block_Array)
	if end > a.committed {
		step := min(COMMIT_STEP, len(a.region) - a.committed)
		virtual.commit(&a.region[a.committed], uint(step)) or_return
		a.committed += step
	}
	p := (^Block_Array)(&a.region[a.allocated * size_of(Block_Array)])
	a.allocated += 1
	return p, nil
}

block_arrays_give :: proc(a: ^Block_Arrays, p: ^Block_Array) {
	assert(a.free_len < len(a.free), "array given back twice")
	a.free[a.free_len] = p
	a.free_len += 1
}
