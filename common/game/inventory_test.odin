package game

import "core:testing"

@(test)
test_items :: proc(t: ^testing.T) {
	stone := item_of_block(test_reg(), .Stone)
	testing.expect_value(t, item_name(test_reg(), stone), "stone")
	testing.expect_value(t, item_stack_size(test_reg(), stone), BLOCK_STACK)
	info, _ := item_info(test_reg(), stone)
	testing.expect_value(t, info.block, Block.Stone)
	testing.expect_value(t, item_of_block(test_reg(), .Bedrock), NO_ITEM)
	launcher, ok := item_by_name(test_reg(), "rocket_launcher")
	testing.expect(t, ok && item_stack_size(test_reg(), launcher) == 1)
	testing.expect(
		t,
		!item_valid(test_reg(), Item(0x7fff)) &&
		!item_valid(test_reg(), TOOL_ITEMS + 99) &&
		!item_valid(test_reg(), NO_ITEM),
	)
	for i in every_item(test_reg()) {
		back, found := item_by_name(test_reg(), item_name(test_reg(), i))
		testing.expectf(t, found && back == i, "%v does not round-trip its name", i)
	}
}

@(test)
test_inventory_actions :: proc(t: ^testing.T) {
	stone, dirt := item_of_block(test_reg(), .Stone), item_of_block(test_reg(), .Dirt)
	launcher := item_of_tool(.Launcher)
	inv: Inventory
	testing.expect(t, inventory_add(test_reg(), &inv, {stone, 100, 0}) == {}, "100 stone fit")
	testing.expect(t, inv.slots[0] == {stone, 64, 0} && inv.slots[1] == {stone, 36, 0})
	inventory_add(test_reg(), &inv, {launcher, 1, 0})
	testing.expect(t, inv.slots[2] == {launcher, 1, 0})

	do_ :: proc(
		inv: ^Inventory,
		kind: Inventory_Action_Kind,
		slot: int,
		arg := 0,
	) -> (
		Stack,
		bool,
	) {
		return inventory_apply(test_reg(), inv, {kind, slot, arg}, false)
	}
	// Pick up 36, put them onto the 64 (full: swap), onto an empty slot.
	_, ok := do_(&inv, .Click, 1)
	testing.expect(t, ok && inv.cursor == {stone, 36, 0} && inv.slots[1] == {})
	do_(&inv, .Click, 0) // full: they swap
	testing.expect(t, inv.cursor == {stone, 64, 0} && inv.slots[0] == {stone, 36, 0})
	do_(&inv, .Click, 0) // 28 fit, 36 stay on the cursor
	testing.expect(t, inv.slots[0] == {stone, 64, 0} && inv.cursor == {stone, 36, 0})
	do_(&inv, .Click, 20)
	testing.expect(t, inv.slots[20] == {stone, 36, 0} && stack_empty(inv.cursor))
	// Right: half up, one down at a time; nothing to do: refused.
	do_(&inv, .Click_Right, 20)
	testing.expect(t, inv.cursor == {stone, 18, 0} && inv.slots[20] == {stone, 18, 0})
	do_(&inv, .Click_Right, 21)
	testing.expect(t, inv.slots[21] == {stone, 1, 0} && inv.cursor == {stone, 17, 0})
	do_(&inv, .Click, 20)
	_, ok = do_(&inv, .Click, 25)
	testing.expect(t, !ok, "an empty click did something")
	// Shift-click: from the rest to the hotbar (onto stone? full; an empty slot).
	do_(&inv, .Quick_Move, 20)
	testing.expect(t, inv.slots[1] == {stone, 35, 0} && inv.slots[20] == {})
	do_(&inv, .Quick_Move, 2) // the launcher, out of the hotbar
	testing.expect(t, inv.slots[5] == {launcher, 1, 0} && inv.slots[2] == {})
	do_(&inv, .Swap_Hotbar, 5, 4)
	testing.expect(t, inv.slots[4] == {launcher, 1, 0} && inv.slots[5] == {})
	// Drops.
	dropped, _ := do_(&inv, .Drop, 0)
	testing.expect(t, dropped == {stone, 1, 0} && inv.slots[0] == {stone, 63, 0})
	dropped, _ = do_(&inv, .Drop, 0, 1)
	testing.expect(t, dropped == {stone, 63, 0} && inv.slots[0] == {})
	// The catalog only for those who may.
	_, ok = do_(&inv, .Take, CURSOR_SLOT, int(dirt))
	testing.expect(t, !ok)
	_, ok = inventory_apply(test_reg(), &inv, {.Take, CURSOR_SLOT, int(dirt)}, true)
	testing.expect(t, ok && inv.cursor == {dirt, 64, 0})
	dropped, _ = do_(&inv, .Close, CURSOR_SLOT)
	testing.expect(
		t,
		stack_empty(dropped) && stack_empty(inv.cursor) && inventory_count(&inv, dirt) == 64,
	)
	// Full: closing drops what does not fit.
	full: Inventory
	for &s in full.slots {s = {stone, 64, 0}}
	full.cursor = {dirt, 5, 0}
	dropped, _ = do_(&full, .Close, CURSOR_SLOT)
	testing.expect(t, dropped == {dirt, 5, 0})
	// Using what is held; bad actions.
	do_(&inv, .Select, 0, 1)
	before := inventory_held(&inv)
	inventory_use_held(&inv)
	testing.expect_value(t, inventory_held(&inv).count, before.count - 1)
	for bad in ([]Inventory_Action{{.Select, 0, 5}, {.Click, 30, 0}, {.Swap_Hotbar, 5, 12}, {.Drop, -2, 0}}) {
		_, ok = inventory_apply(test_reg(), &inv, bad, false)
		testing.expectf(t, !ok, "%v accepted", bad)
	}
	testing.expect(t, inventory_valid(test_reg(), &inv))
	testing.expect_value(t, inventory_remove(&inv, stone, 1000), inventory_count(&inv, stone) + 35)
}

// The mouse tweaks' actions: Put (a drag spreading a stack), Gather (a
// double-click), Move_One (the wheel).
@(test)
test_inventory_tweak_actions :: proc(t: ^testing.T) {
	stone, dirt := item_of_block(test_reg(), .Stone), item_of_block(test_reg(), .Dirt)
	inv: Inventory
	do_ :: proc(inv: ^Inventory, kind: Inventory_Action_Kind, slot: int, arg := 0) -> bool {
		_, ok := inventory_apply(test_reg(), inv, {kind, slot, arg}, false)
		return ok
	}
	// Put: up to arg; onto the same item or an empty slot only, and no more than fits.
	inv.cursor = {stone, 10, 0}
	inv.slots[6] = {dirt, 1, 0}
	inv.slots[7] = {stone, 62, 0}
	testing.expect(t, !do_(&inv, .Put, 6, 3), "another item's slot refuses")
	testing.expect(
		t,
		do_(&inv, .Put, 7, 5) && inv.slots[7] == {stone, 64, 0} && inv.cursor.count == 8,
	)
	testing.expect(t, !do_(&inv, .Put, 7, 1), "a full slot refuses")
	testing.expect(
		t,
		do_(&inv, .Put, 8, 3) && inv.slots[8] == {stone, 3, 0} && inv.cursor.count == 5,
	)
	testing.expect(
		t,
		do_(&inv, .Put, 9, 50) && inv.slots[9] == {stone, 5, 0} && stack_empty(inv.cursor),
	)
	testing.expect(t, !do_(&inv, .Put, 10, 1), "an empty cursor puts nothing")

	// Gather: every stack of the cursor's item, not-full ones first, up to a full stack.
	inv = {}
	inv.cursor = {stone, 10, 0}
	inv.slots[0] = {stone, 64, 0}
	inv.slots[5] = {stone, 20, 0}
	inv.slots[6] = {dirt, 5, 0}
	inv.slots[7] = {stone, 50, 0}
	testing.expect(t, do_(&inv, .Gather, CURSOR_SLOT))
	testing.expect(t, inv.cursor == {stone, 64, 0} && stack_empty(inv.slots[5]))
	testing.expect(t, inv.slots[7] == {stone, 16, 0}, "the not-full stacks went first")
	testing.expect(
		t,
		inv.slots[0] == {stone, 64, 0} && inv.slots[6] == {dirt, 5, 0},
		"the full one was not needed",
	)
	testing.expect(t, !do_(&inv, .Gather, CURSOR_SLOT), "a full cursor gathers nothing")

	// Move_One: out of a slot to the other section; into one from it.
	inv = {}
	inv.slots[2] = {stone, 3, 0}
	testing.expect(t, do_(&inv, .Move_One, 2, 0))
	testing.expect(t, inv.slots[2].count == 2 && inv.slots[5] == {stone, 1, 0})
	testing.expect(t, do_(&inv, .Move_One, 5, 0) && inv.slots[2].count == 3, "back onto its stack")
	testing.expect(t, do_(&inv, .Move_One, 2, 1) == false, "nothing of it in the rest now")
	inv.slots[9] = {stone, 4, 0}
	testing.expect(
		t,
		do_(&inv, .Move_One, 2, 1) && inv.slots[2].count == 4 && inv.slots[9].count == 3,
	)
	inv.slots[3] = {dirt, 1, 0}
	testing.expect(
		t,
		!do_(&inv, .Move_One, 3, 1) && !do_(&inv, .Move_One, 4, 0),
		"no item: nothing",
	)
}

// Equipment: a slot takes only what fits it (the offhand anything); a click
// swaps; shift-click puts armor on when its slot is free and takes it off
// into the inventory; the other actions leave the equipment slots alone.
@(test)
test_equipment_actions :: proc(t: ^testing.T) {
	cap_, boots, stone :=
		item_of_armor(.Cap), item_of_armor(.Boots), item_of_block(test_reg(), .Stone)
	head, feet, off :=
		EQUIP_BASE +
		int(Equip_Slot.Head),
		EQUIP_BASE +
		int(Equip_Slot.Feet),
		EQUIP_BASE +
		int(Equip_Slot.Offhand)
	inv: Inventory
	do_ :: proc(inv: ^Inventory, kind: Inventory_Action_Kind, slot: int, arg := 0) -> bool {
		_, ok := inventory_apply(test_reg(), inv, {kind, slot, arg}, true)
		return ok
	}
	testing.expect(
		t,
		item_fits(test_reg(), {cap_, 1, 0}, .Head) && !item_fits(test_reg(), {cap_, 1, 0}, .Feet),
	)
	testing.expect(
		t,
		item_fits(test_reg(), {stone, 5, 0}, .Offhand) &&
		!item_fits(test_reg(), {stone, 5, 0}, .Head),
	)
	testing.expect(t, item_fits(test_reg(), {}, .Head), "empty fits anywhere")

	do_(&inv, .Take, CURSOR_SLOT, int(cap_))
	testing.expect(t, !do_(&inv, .Click, feet), "a cap does not go on the feet")
	testing.expect(t, !do_(&inv, .Click_Right, feet))
	testing.expect(
		t,
		do_(&inv, .Click, head) && inv.equipment[.Head] == {cap_, 1, 0} && stack_empty(inv.cursor),
	)
	// Swapping with another cap: the first comes back.
	do_(&inv, .Take, CURSOR_SLOT, int(cap_))
	testing.expect(
		t,
		do_(&inv, .Click, head) &&
		inv.equipment[.Head] == {cap_, 1, 0} &&
		inv.cursor == {cap_, 1, 0},
	)
	// A stack onto the offhand; the others cannot reach equipment.
	inv.cursor = {stone, 20, 0}
	testing.expect(t, do_(&inv, .Click, off) && inv.equipment[.Offhand] == {stone, 20, 0})
	testing.expect(t, do_(&inv, .Put, off, 5) == false, "an empty cursor puts nothing")
	inv.slots[7] = {stone, 3, 0}
	testing.expect(
		t,
		!do_(&inv, .Move_One, off, 1) && !do_(&inv, .Swap_Hotbar, off, 1),
		"not for equipment",
	)
	// Shift-click: off into the inventory, and on again.
	inv = {}
	inv.equipment[.Feet] = {boots, 1, 0}
	testing.expect(
		t,
		do_(&inv, .Quick_Move, feet) &&
		stack_empty(inv.equipment[.Feet]) &&
		inv.slots[0] == {boots, 1, 0},
	)
	testing.expect(
		t,
		do_(&inv, .Quick_Move, 0) &&
		inv.equipment[.Feet] == {boots, 1, 0} &&
		stack_empty(inv.slots[0]),
	)
	// A second pair while the feet are taken: stays in the inventory (moves hotbar <-> rest).
	inv.slots[0] = {boots, 1, 0}
	testing.expect(
		t,
		do_(&inv, .Quick_Move, 0) &&
		inv.slots[5] == {boots, 1, 0} &&
		inv.equipment[.Feet] == {boots, 1, 0},
	)
	// Valid inventories are those whose equipment fits.
	testing.expect(t, inventory_valid(test_reg(), &inv))
	inv.equipment[.Head] = {boots, 1, 0}
	testing.expect(t, !inventory_valid(test_reg(), &inv))
	// What the avatar shows.
	inv.equipment[.Head] = {cap_, 1, 0}
	inv.equipment[.Offhand] = {stone, 1, 0}
	testing.expect_value(t, worn_of(&inv), [WORN_SLOTS]Item{cap_, 0, 0, boots})
}

// An open chest's slots are named by requests like the inventory's own;
// shut, they refuse; shift-click moves between the two; closing clears it.
@(test)
test_chest_actions :: proc(t: ^testing.T) {
	stone, dirt := item_of_block(test_reg(), .Stone), item_of_block(test_reg(), .Dirt)
	inv: Inventory
	inv.slots[6] = {stone, 40, 0}
	inv.slots[0] = {dirt, 5, 0}
	_, ok := inventory_apply(test_reg(), &inv, {.Click, CHEST_BASE, 0}, false)
	testing.expect(t, !ok, "a shut chest took a request")
	inv.chest_open = true
	// Shift-click: into the chest, and back out.
	_, ok = inventory_apply(test_reg(), &inv, {.Quick_Move, 6, 0}, false)
	testing.expect(
		t,
		ok && inv.chest[0] == {stone, 40, 0} && stack_empty(inv.slots[6]),
		"not into the chest",
	)
	_, ok = inventory_apply(test_reg(), &inv, {.Quick_Move, CHEST_BASE, 0}, false)
	testing.expect(
		t,
		ok && stack_empty(inv.chest[0]) && inv.slots[1] == {stone, 40, 0},
		"not back out",
	)
	// A click picks up from a chest slot, puts down in another, right-click halves.
	inv.chest[3] = {stone, 10, 0}
	inventory_apply(test_reg(), &inv, {.Click, CHEST_BASE + 3, 0}, false)
	testing.expect_value(t, inv.cursor, Stack{stone, 10, 0})
	inventory_apply(test_reg(), &inv, {.Click, CHEST_BASE + 24, 0}, false)
	testing.expect(t, inv.chest[24] == {stone, 10, 0} && stack_empty(inv.cursor))
	inventory_apply(test_reg(), &inv, {.Click_Right, CHEST_BASE + 24, 0}, false)
	testing.expect(t, inv.cursor == {stone, 5, 0} && inv.chest[24] == {stone, 5, 0})
	// Dropping from a chest slot gives the stack.
	dropped, _ := inventory_apply(test_reg(), &inv, {.Drop, CHEST_BASE + 24, 1}, false)
	testing.expect_value(t, dropped, Stack{stone, 5, 0})
	// Closing puts the cursor away and empties the view.
	_, ok = inventory_apply(test_reg(), &inv, {.Close, CURSOR_SLOT, 0}, false)
	testing.expect(t, ok && !inv.chest_open && inv.chest == {} && stack_empty(inv.cursor))
}

// Sort: the grid's stacks merge up to the stack size and go in item order,
// the empty slots last; the hotbar and the cursor are not touched; nothing
// to change is no change.
@(test)
test_inventory_sort :: proc(t: ^testing.T) {
	reg := test_reg()
	stone, dirt := item_of_block(reg, .Stone), item_of_block(reg, .Dirt)
	inv: Inventory
	inv.slots[0] = {dirt, 9, 0} // the hotbar: left alone
	inv.slots[HOTBAR_SLOTS + 7] = {dirt, 60, 0}
	inv.slots[HOTBAR_SLOTS + 2] = {stone, 3, 0}
	inv.slots[HOTBAR_SLOTS + 11] = {dirt, 20, 0}
	inv.cursor = {stone, 2, 0}
	_, ok := inventory_apply(reg, &inv, {.Sort, 0, 0}, false)
	testing.expect(t, ok)
	grid := inv.slots[HOTBAR_SLOTS:INVENTORY_SLOTS]
	first, second := min(stone, dirt), max(stone, dirt)
	// Stone 3 and dirt 80 (a stack of 64 and one of 16), in item order.
	want := [?]Stack{{stone, 3, 0}, {dirt, 64, 0}, {dirt, 16, 0}}
	if first != stone {want = {{dirt, 64, 0}, {dirt, 16, 0}, {stone, 3, 0}}}
	for w, i in want {testing.expect_value(t, grid[i], w)}
	for s in grid[len(want):] {testing.expect(t, stack_empty(s))}
	testing.expect_value(t, inv.slots[0], Stack{dirt, 9, 0})
	testing.expect_value(t, inv.cursor, Stack{stone, 2, 0})
	_ = second
	// Sorted already: no change, and the server refuses it as a no-op.
	_, ok = inventory_apply(reg, &inv, {.Sort, 0, 0}, false)
	testing.expect(t, !ok)
}

// Swap_Offhand: the hand's stack and the offhand slot's change places; with
// both empty there is nothing to do (the server refuses it, the client does
// not predict it); a swapped-in stack comes from the selected slot only.
@(test)
test_swap_offhand :: proc(t: ^testing.T) {
	stone, dirt := item_of_block(test_reg(), .Stone), item_of_block(test_reg(), .Dirt)
	inv: Inventory
	swap :: proc(inv: ^Inventory) -> bool {
		_, ok := inventory_apply(test_reg(), inv, {.Swap_Offhand, 0, 0}, false)
		return ok
	}
	testing.expect(t, !swap(&inv), "nothing to swap")
	inv.selected = 2
	inv.slots[2], inv.slots[3] = {stone, 5, 0}, {dirt, 1, 0}
	testing.expect(t, swap(&inv), "into an empty offhand")
	testing.expect(t, stack_empty(inv.slots[2]) && inv.equipment[.Offhand] == {stone, 5, 0})
	testing.expect_value(t, inv.slots[3], Stack{dirt, 1, 0})
	testing.expect(t, swap(&inv), "back")
	testing.expect(t, inv.slots[2] == {stone, 5, 0} && stack_empty(inv.equipment[.Offhand]))
	inv.equipment[.Offhand] = {dirt, 9, 0}
	testing.expect(t, swap(&inv), "both full")
	testing.expect(t, inv.slots[2] == {dirt, 9, 0} && inv.equipment[.Offhand] == {stone, 5, 0})
	testing.expect(t, inventory_valid(test_reg(), &inv))
}

// A weapon's magazine is instance data: it goes where its stack goes (a click
// puts it down, a swap trades it, a quick move carries it), and a weapon taken
// from the catalog starts full.
@(test)
test_ammo_travels_with_the_stack :: proc(t: ^testing.T) {
	reg := test_reg()
	pistol, _ := registry_item(reg, "pistol")
	inv: Inventory
	inv.slots[0] = {pistol, 1, 7}
	apply :: proc(inv: ^Inventory, a: Inventory_Action, catalog := false) {
		inventory_apply(test_reg(), inv, a, catalog)
	}
	apply(&inv, {.Click, 0, 0}) // pick it up
	testing.expect_value(t, inv.cursor.ammo, u8(7))
	apply(&inv, {.Click, 12, 0}) // put it down elsewhere
	testing.expect_value(t, inv.slots[12].ammo, u8(7))
	apply(&inv, {.Quick_Move, 12, 0}) // up to the hotbar
	found := false
	for st in inv.slots[:HOTBAR_SLOTS] {
		if st.item == pistol {found = st.ammo == 7}
	}
	testing.expect(t, found, "a quick move keeps the magazine")
	apply(&inv, {.Swap_Hotbar, 0, 3})
	testing.expect_value(t, inv.slots[3].ammo, u8(7))
	dropped, _ := inventory_apply(reg, &inv, {.Drop, 3, 1}, false)
	testing.expect_value(t, dropped.ammo, u8(7)) // (a dropped weapon keeps it too)

	// From the catalog: a full magazine.
	taken: Inventory
	apply(&taken, {.Take, 0, int(pistol)}, catalog = true)
	testing.expect_value(t, taken.cursor.ammo, u8(new_ammo(reg, pistol)))
	testing.expect_value(t, taken.cursor.ammo, u8(12))
}
