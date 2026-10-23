package printer_test

import "core:fmt"

// Known values for checking the debugger pretty-printers (tools/debugger):
// `build debugger-test` stops at the marked line under gdb/lldb and prints
// each of these. Not part of the game.

Shape :: union {
	Circle,
	Rect,
}

Circle :: struct {
	radius: f32,
}

Rect :: struct {
	w, h: f32,
}

Handle :: distinct u32

main :: proc() {
	name := "voxiverse"
	empty := ""
	numbers := []int{1, 2, 3}
	list := make([dynamic]string, 0, 8)
	append(&list, "a", "bb", "ccc")
	shape: Shape = Rect{2, 3}
	none: Shape
	lookup := make(map[string]int)
	lookup["one"] = 1
	lookup["two"] = 2
	handle := Handle(7)
	// Layout edge cases: values bigger than a 64-byte cell, odd-sized keys,
	// and a deleted entry (tombstone).
	big := make(map[int][100]u8)
	big[5] = {
		0 = 42,
	}
	odd := make(map[[3]u8]int)
	odd[{1, 2, 3}] = 123
	odd[{4, 5, 6}] = 456
	odd[{7, 8, 9}] = 789
	delete_key(&odd, [3]u8{4, 5, 6})
	// A full small map: deleting inside probe chains leaves tombstones,
	// which the printers must skip.
	dense := make(map[int]int)
	for k in 0 ..< 12 {dense[k * 1000] = k}
	for k in 0 ..< 12 do if k % 2 == 1 {delete_key(&dense, k * 1000)}
	fmt.println(
		name,
		empty,
		numbers,
		list,
		shape,
		none,
		lookup,
		handle,
		len(big),
		len(odd),
		len(dense),
	) // BREAK HERE
	delete(list)
	delete(lookup)
	delete(big)
	delete(odd)
	delete(dense)
}
