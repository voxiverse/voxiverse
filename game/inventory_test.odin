package game

import "core:testing"

@(test)
test_items :: proc(t: ^testing.T) {
	stone := item_of_block(.Stone)
	testing.expect_value(t, item_name(stone), "stone")
	testing.expect_value(t, item_stack_size(stone), BLOCK_STACK)
	info, _ := item_info(stone)
	testing.expect_value(t, info.block, Block.Stone)
	testing.expect_value(t, item_of_block(.Bedrock), NO_ITEM)
	launcher, ok := item_by_name("rocket_launcher")
	testing.expect(t, ok && item_stack_size(launcher) == 1)
	testing.expect(
		t,
		!item_valid(Item(0x7fff)) && !item_valid(TOOL_ITEMS + 99) && !item_valid(NO_ITEM),
	)
	for i in every_item() {
		back, found := item_by_name(item_name(i))
		testing.expectf(t, found && back == i, "%v does not round-trip its name", i)
	}
}

@(test)
test_inventory_actions :: proc(t: ^testing.T) {
	stone, dirt := item_of_block(.Stone), item_of_block(.Dirt)
	launcher := item_of_tool(.Launcher)
	inv: Inventory
	testing.expect(t, inventory_add(&inv, {stone, 100}) == {}, "100 stone fit")
	testing.expect(t, inv.slots[0] == {stone, 64} && inv.slots[1] == {stone, 36})
	inventory_add(&inv, {launcher, 1})
	testing.expect(t, inv.slots[2] == {launcher, 1})

	do_ :: proc(
		inv: ^Inventory,
		kind: Inventory_Action_Kind,
		slot: int,
		arg := 0,
	) -> (
		Stack,
		bool,
	) {
		return inventory_apply(inv, {kind, slot, arg}, false)
	}
	// Pick up 36, put them onto the 64 (full: swap), onto an empty slot.
	_, ok := do_(&inv, .Click, 1)
	testing.expect(t, ok && inv.cursor == {stone, 36} && inv.slots[1] == {})
	do_(&inv, .Click, 0) // full: they swap
	testing.expect(t, inv.cursor == {stone, 64} && inv.slots[0] == {stone, 36})
	do_(&inv, .Click, 0) // 28 fit, 36 stay on the cursor
	testing.expect(t, inv.slots[0] == {stone, 64} && inv.cursor == {stone, 36})
	do_(&inv, .Click, 20)
	testing.expect(t, inv.slots[20] == {stone, 36} && stack_empty(inv.cursor))
	// Right: half up, one down at a time; nothing to do: refused.
	do_(&inv, .Click_Right, 20)
	testing.expect(t, inv.cursor == {stone, 18} && inv.slots[20] == {stone, 18})
	do_(&inv, .Click_Right, 21)
	testing.expect(t, inv.slots[21] == {stone, 1} && inv.cursor == {stone, 17})
	do_(&inv, .Click, 20)
	_, ok = do_(&inv, .Click, 25)
	testing.expect(t, !ok, "an empty click did something")
	// Shift-click: from the rest to the hotbar (onto stone? full; an empty slot).
	do_(&inv, .Quick_Move, 20)
	testing.expect(t, inv.slots[1] == {stone, 35} && inv.slots[20] == {})
	do_(&inv, .Quick_Move, 2) // the launcher, out of the hotbar
	testing.expect(t, inv.slots[5] == {launcher, 1} && inv.slots[2] == {})
	do_(&inv, .Swap_Hotbar, 5, 4)
	testing.expect(t, inv.slots[4] == {launcher, 1} && inv.slots[5] == {})
	// Drops.
	dropped, _ := do_(&inv, .Drop, 0)
	testing.expect(t, dropped == {stone, 1} && inv.slots[0] == {stone, 63})
	dropped, _ = do_(&inv, .Drop, 0, 1)
	testing.expect(t, dropped == {stone, 63} && inv.slots[0] == {})
	// The catalog only for those who may.
	_, ok = do_(&inv, .Take, CURSOR_SLOT, int(dirt))
	testing.expect(t, !ok)
	_, ok = inventory_apply(&inv, {.Take, CURSOR_SLOT, int(dirt)}, true)
	testing.expect(t, ok && inv.cursor == {dirt, 64})
	dropped, _ = do_(&inv, .Close, CURSOR_SLOT)
	testing.expect(
		t,
		stack_empty(dropped) && stack_empty(inv.cursor) && inventory_count(&inv, dirt) == 64,
	)
	// Full: closing drops what does not fit.
	full: Inventory
	for &s in full.slots {s = {stone, 64}}
	full.cursor = {dirt, 5}
	dropped, _ = do_(&full, .Close, CURSOR_SLOT)
	testing.expect(t, dropped == {dirt, 5})
	// Using what is held; bad actions.
	do_(&inv, .Select, 0, 1)
	before := inventory_held(&inv)
	inventory_use_held(&inv)
	testing.expect_value(t, inventory_held(&inv).count, before.count - 1)
	for bad in ([]Inventory_Action{{.Select, 0, 5}, {.Click, 30, 0}, {.Swap_Hotbar, 5, 12}, {.Drop, -2, 0}}) {
		_, ok = inventory_apply(&inv, bad, false)
		testing.expectf(t, !ok, "%v accepted", bad)
	}
	testing.expect(t, inventory_valid(&inv))
	testing.expect_value(t, inventory_remove(&inv, stone, 1000), inventory_count(&inv, stone) + 35)
}
