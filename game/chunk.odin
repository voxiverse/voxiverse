package game

import "core:mem"

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

// Block_Arrays recycles chunk arrays: memory grows to the most chunks with
// arrays ever loaded at once, then stays flat as chunks load and unload.
// Not thread-safe; one per owner (server world, client world).
Block_Arrays :: struct {
	free:      [dynamic]^Block_Array,
	allocated: int, // arrays ever allocated (in use + free)
	allocator: mem.Allocator,
}

block_arrays_init :: proc(a: ^Block_Arrays, allocator := context.allocator) {
	a^ = {
		free      = make([dynamic]^Block_Array, allocator),
		allocator = allocator,
	}
}

// block_arrays_destroy frees every array; those still in chunks must have
// been given back first (or the whole allocator is being freed).
block_arrays_destroy :: proc(a: ^Block_Arrays) {
	assert(len(a.free) == a.allocated, "chunk arrays still in use")
	for p in a.free {free(p, a.allocator)}
	delete(a.free)
	a^ = {}
}

block_arrays_in_use :: proc(a: ^Block_Arrays) -> int {
	return a.allocated - len(a.free)
}

// block_arrays_take returns an array with unspecified contents.
block_arrays_take :: proc(
	a: ^Block_Arrays,
	loc := #caller_location,
) -> (
	^Block_Array,
	mem.Allocator_Error,
) {
	if p, ok := pop_safe(&a.free); ok {return p, nil}
	p, err := new(Block_Array, a.allocator, loc)
	if err == nil {a.allocated += 1}
	return p, err
}

block_arrays_give :: proc(a: ^Block_Arrays, p: ^Block_Array) {
	append(&a.free, p)
}
