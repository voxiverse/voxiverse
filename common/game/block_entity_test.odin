package game

import "core:strings"
import "core:testing"

// A machine is a block entity a pack declares: its slots, its record, what it shows and
// when it thinks next are kept whole through the save's encoding.

@(private = "file")
MACHINE_PACK :: `{"oven": {"textures": {"all": "voxiverse:stone"}, "entity": {"kind": "machine", "slots": 3}}}`

@(test)
test_a_machine_keeps_its_record_through_a_save :: proc(t: ^testing.T) {
	reg, errs := build_with(pack_of("works", {{"data/blocks/works.json", MACHINE_PACK}}))
	testing.expect(t, reg != nil, errors_text(errs))
	if reg == nil {return}
	oven, ok := registry_block(reg, "works:oven")
	testing.expect(t, ok)
	ty := &reg.blocks.types[reg.blocks.type_of[oven]]
	testing.expect_value(t, block_entity_kind(&reg.blocks, oven), Block_Entity_Kind.Machine)
	testing.expect_value(t, ty.slots, 3)

	stone := item_of_block(reg, .Stone)
	e := Block_Entity {
		local = 77,
		kind  = .Machine,
		due   = 1 << 40 + 5,
	}
	e.slots[2] = {stone, 9, 0, 0}
	e.data[0], e.data[10], e.shown[3] = 7, 200, 42
	bytes := block_entity_pack(reg, &e, context.temp_allocator)
	back: Block_Entity
	testing.expect(t, block_entity_unpack(reg, bytes, &back))
	back.local = e.local
	testing.expect(t, back == e, "the machine changed through the encoding")

	// A machine whose record is longer than MAX_MACHINE_DATA does not read.
	w: Writer
	writer_init(&w, context.temp_allocator)
	write_varint(&w, 0)
	write_u8(&w, u8(Block_Entity_Kind.Machine))
	write_varint(&w, 0)
	write_varint(&w, MAX_MACHINE_DATA + 1)
	for _ in 0 ..= MAX_MACHINE_DATA {write_u8(&w, 1)}
	testing.expect(t, !block_entity_unpack(reg, w.buf[:], &back), "an overlong record read")
}

@(test)
test_a_machine_holds_at_most_a_chests_slots :: proc(t: ^testing.T) {
	text := `{"oven": {"textures": {"all": "voxiverse:stone"}, "entity": {"kind": "machine", "slots": 26}}}`
	reg, errs := build_with(pack_of("works", {{"data/blocks/works.json", text}}))
	testing.expect(t, reg == nil)
	testing.expect(t, strings.contains(errors_text(errs), "a machine holds 0 to 25 slots"))
}

// A process recipe is pack data both sides read: what a kind of machine makes of its inputs
// in a time; the crafting grid never matches one.
@(test)
test_a_process_is_a_recipe_for_a_machine :: proc(t: ^testing.T) {
	text := `{"bar": {"type": "process", "machine": "works:oven", "time": 3.2,
		"inputs": [{"item": "voxiverse:cobblestone", "count": 12}, {"item": "voxiverse:planks", "count": 1}],
		"output": {"item": "voxiverse:stone", "count": 2}}}`
	reg, errs := build_with(pack_of("works", {{"data/recipes/works.json", text}}))
	testing.expect(t, reg != nil, errors_text(errs))
	if reg == nil {return}
	id, ok := recipe_by_id(reg, "works:bar")
	if !testing.expect(t, ok) {return}
	r := &reg.recipes[id]
	testing.expect_value(t, r.machine, "works:oven")
	testing.expect_value(t, r.time, 3.2)
	testing.expect_value(t, r.output.count, 2)
	needs, _, n := recipe_needs(r)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, needs[0], Stack{item_of_block(reg, .Cobblestone), 12, 0, 0})
	testing.expect_value(t, needs[1].count, 1)
	grid: [9]Stack
	grid[0] = {item_of_block(reg, .Planks), 1, 0, 0}
	for i in 1 ..< 9 {grid[i] = {item_of_block(reg, .Cobblestone), 1, 0, 0}}
	if found, matched := recipe_match(reg, grid, 3, 3); matched {
		testing.expect(t, reg.recipes[found].machine == "", "the grid matched a process")
	}
	bad := `{"bar": {"type": "process", "time": 1, "inputs": [{"item": "voxiverse:planks"}], "output": {"item": "voxiverse:stone"}}}`
	_, errs = build_with(pack_of("works", {{"data/recipes/works.json", bad}}))
	testing.expect(t, strings.contains(errors_text(errs), "a process names its \"machine\""))
}
