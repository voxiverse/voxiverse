package game

import "core:slice"

// A player's inventory and what may be done with it. The server applies
// actions (inventory_apply) and is the authority; the client applies the
// same actions at once to predict, and replays the ones the server has not
// answered yet over each Inventory it sends (client/session_items.odin).

HOTBAR_SLOTS :: 5
INVENTORY_SLOTS :: 30 // 0..4 the hotbar, 5..29 the rest (a 5x5 grid)
CURSOR_SLOT :: -1 // the stack on the mouse in the inventory overlay
EQUIP_BASE :: INVENTORY_SLOTS // slots INVENTORY_SLOTS ..< TOTAL_SLOTS are the equipment slots, in Equip_Slot order
TOTAL_SLOTS :: INVENTORY_SLOTS + EQUIP_SLOTS
CHEST_SLOTS :: 25 // an open chest's (a 5x5 grid), slot indexes CHEST_BASE ..< ALL_SLOTS
CHEST_BASE :: TOTAL_SLOTS
ALL_SLOTS :: TOTAL_SLOTS + CHEST_SLOTS

Inventory :: struct {
	slots:      [INVENTORY_SLOTS]Stack,
	equipment:  [Equip_Slot]Stack, // worn and held (slot index EQUIP_BASE + the slot)
	cursor:     Stack,
	selected:   int, // the hotbar slot in hand
	// The chest being looked into (not the inventory's own: never saved, and the
	// server fills it from the chest's record): requests may name its slots.
	chest:      [CHEST_SLOTS]Stack,
	chest_open: bool,
}

// with_count: st with another count (what a split or a merge leaves: a weapon's
// magazine goes with it).
with_count :: proc(st: Stack, count: int) -> Stack {
	r := st
	r.count = count
	return r
}

// new_ammo: the magazine a new stack of item has: a weapon's full one.
new_ammo :: proc(reg: ^Registry, item: Item) -> u8 {
	info, _ := registry_item_info(reg, item)
	if w, ok := info.weapon.?; ok {return u8(w.magazine)}
	return 0
}

// slot_at: slot i's stack (a regular slot, or an equipment slot).
slot_at :: proc(inv: ^Inventory, i: int) -> ^Stack {
	if i >= CHEST_BASE {return &inv.chest[i - CHEST_BASE]}
	if i >= EQUIP_BASE {return &inv.equipment[Equip_Slot(i - EQUIP_BASE)]}
	return &inv.slots[i]
}

// slot_accepts: whether stack may be put into slot i (equipment slots take
// only what fits them).
slot_accepts :: proc(reg: ^Registry, i: int, stack: Stack) -> bool {
	return i < EQUIP_BASE || i >= CHEST_BASE || item_fits(reg, stack, Equip_Slot(i - EQUIP_BASE))
}

// worn_of: the items the avatar shows (head to feet).
worn_of :: proc(inv: ^Inventory) -> (worn: [WORN_SLOTS]Item) {
	for i in 0 ..< WORN_SLOTS {
		st := inv.equipment[Equip_Slot(i)]
		if !stack_empty(st) {worn[i] = st.item}
	}
	return
}

Inventory_Action_Kind :: enum u8 {
	Select, // hold hotbar slot `arg`
	Click, // pick up, put down, merge with or swap with the cursor
	Click_Right, // pick up half, or put down one
	Quick_Move, // between the hotbar and the rest (shift-click)
	Swap_Hotbar, // the slot with hotbar slot `arg` (a number key over it)
	Drop, // one from the slot (CURSOR_SLOT: the cursor), all if `arg` is 1
	Take, // a full stack of item `arg` on the cursor (from the catalog)
	Close, // the overlay closed: the cursor's stack back in (what does not fit dropped)
	Put, // up to `arg` of the cursor's stack into the slot, if empty or of the same item (a drag spreading a stack)
	Gather, // every stack of the cursor's item onto the cursor, as far as it fits (a double-click)
	Move_One, // one between the hotbar and the rest: from the slot (arg 0), or into it (arg 1) (the wheel)
	Sort, // the pockets' grid (not the hotbar): stacks merged, then in item order, empty slots last (the slot is ignored)
	Swap_Offhand, // the hand's stack with the offhand slot's (nothing to swap when both are empty; the slot and arg are ignored)
}

Inventory_Action :: struct {
	kind: Inventory_Action_Kind,
	slot: int, // CURSOR_SLOT ..< ALL_SLOTS
	arg:  int, // 0 ..< 65536
}

// inventory_apply does a; what it drops into the world, and false if it
// could not be done (nothing changes then). catalog: the player may take
// any item.
inventory_apply :: proc(
	reg: ^Registry,
	inv: ^Inventory,
	a: Inventory_Action,
	catalog: bool,
) -> (
	dropped: Stack,
	ok: bool,
) {
	in_slots := a.slot >= 0 && a.slot < (ALL_SLOTS if inv.chest_open else TOTAL_SLOTS)
	regular := a.slot >= 0 && a.slot < INVENTORY_SLOTS
	switch a.kind {
	case .Select:
		if a.arg < 0 || a.arg >= HOTBAR_SLOTS {return}
		inv.selected = a.arg
	case .Click:
		if !in_slots {return}
		slot := slot_at(inv, a.slot)
		cur := &inv.cursor
		if !slot_accepts(reg, a.slot, cur^) {return} 	// (and what comes back is what was there)
		switch {
		case stack_empty(cur^) && stack_empty(slot^):
			return
		case !stack_empty(cur^) && !stack_empty(slot^) && cur.item == slot.item:
			moved := min(cur.count, item_stack_size(reg, slot.item) - slot.count)
			if moved <= 0 {cur^, slot^ = slot^, cur^} else {
				slot.count += moved
				cur.count -= moved
			}
		case:
			cur^, slot^ = slot^, cur^
		}
	case .Click_Right:
		if !in_slots {return}
		slot := slot_at(inv, a.slot)
		cur := &inv.cursor
		if !stack_empty(cur^) && !slot_accepts(reg, a.slot, cur^) {return}
		switch {
		case stack_empty(cur^):
			if stack_empty(slot^) {return}
			half := (slot.count + 1) / 2
			cur^ = with_count(slot^, half)
			slot.count -= half
		case stack_empty(slot^):
			slot^ = with_count(cur^, 1)
			cur.count -= 1
		case slot.item == cur.item:
			if slot.count >= item_stack_size(reg, slot.item) {return}
			slot.count += 1
			cur.count -= 1
		case:
			cur^, slot^ = slot^, cur^
		}
	case .Quick_Move:
		if !in_slots || stack_empty(slot_at(inv, a.slot)^) {return}
		slot := slot_at(inv, a.slot)
		if a.slot >= CHEST_BASE {
			// Out of the chest: into the inventory.
			left := slots_add(reg, inv.slots[:], slot^)
			if left.count == slot.count {return}
			slot^ = left
			break
		}
		if regular && inv.chest_open {
			// Into the chest.
			left := slots_add(reg, inv.chest[:], slot^)
			if left.count == slot.count {return}
			slot^ = left
			break
		}
		if !regular {
			// Out of an equipment slot: into the inventory.
			left := slots_add(reg, inv.slots[:], slot^)
			if left.count == slot.count {return}
			slot^ = left
			break
		}
		// Armor goes on, if its slot is free.
		if info, _ := item_info(reg, slot.item); info.equip != nil {
			e := info.equip.?
			if stack_empty(inv.equipment[e]) {
				inv.equipment[e], slot^ = slot^, {}
				break
			}
		}
		lo, hi := HOTBAR_SLOTS, INVENTORY_SLOTS
		if a.slot >= HOTBAR_SLOTS {lo, hi = 0, HOTBAR_SLOTS}
		left := slots_add(reg, inv.slots[lo:hi], slot^)
		if left.count == slot.count {return}
		slot^ = left
	case .Swap_Hotbar:
		if !regular || a.arg < 0 || a.arg >= HOTBAR_SLOTS || a.arg == a.slot {return}
		inv.slots[a.slot], inv.slots[a.arg] = inv.slots[a.arg], inv.slots[a.slot]
	case .Drop:
		from :=
			&inv.cursor if a.slot == CURSOR_SLOT else (slot_at(inv, a.slot) if in_slots else nil)
		if from == nil || stack_empty(from^) {return}
		n := from.count if a.arg == 1 else 1
		dropped = with_count(from^, n)
		from.count -= n
	case .Take:
		item := Item(a.arg)
		if !catalog || !item_valid(reg, item) {return}
		inv.cursor = {item, item_stack_size(reg, item), new_ammo(reg, item)}
	case .Put:
		if !in_slots || stack_empty(inv.cursor) || !slot_accepts(reg, a.slot, inv.cursor) {return}
		slot := slot_at(inv, a.slot)
		if !stack_empty(slot^) && slot.item != inv.cursor.item {return}
		moved := min(a.arg, inv.cursor.count, item_stack_size(reg, inv.cursor.item) - slot.count)
		if moved <= 0 {return}
		slot^ = with_count(inv.cursor, slot.count + moved)
		inv.cursor.count -= moved
	case .Gather:
		cur := &inv.cursor
		if stack_empty(cur^) {return}
		size := item_stack_size(reg, cur.item)
		before := cur.count
		// Stacks that are not full first, then the full ones.
		for full in ([2]bool{false, true}) {
			for &slot in inv.slots {
				if cur.count >= size {break}
				if slot.item != cur.item || stack_empty(slot) {continue}
				if (slot.count >= size) != full {continue}
				moved := min(slot.count, size - cur.count)
				slot.count -= moved
				cur.count += moved
			}
		}
		if cur.count == before {return}
	case .Move_One:
		if !regular {return}
		slot := &inv.slots[a.slot]
		lo, hi := HOTBAR_SLOTS, INVENTORY_SLOTS // the other section
		if a.slot >= HOTBAR_SLOTS {lo, hi = 0, HOTBAR_SLOTS}
		if a.arg == 0 {
			if stack_empty(slot^) {return}
			if left := slots_add(reg, inv.slots[lo:hi], with_count(slot^, 1));
			   left.count != 0 {return}
			slot.count -= 1
		} else {
			if stack_empty(slot^) || slot.count >= item_stack_size(reg, slot.item) {return}
			// From the last slot of the other section holding it.
			from := -1
			for i in lo ..< hi {if inv.slots[i].item == slot.item && !stack_empty(inv.slots[i]) {from = i}}
			if from < 0 {return}
			inv.slots[from].count -= 1
			slot.count += 1
		}
	case .Sort:
		grid := inv.slots[HOTBAR_SLOTS:INVENTORY_SLOTS]
		before := [INVENTORY_SLOTS - HOTBAR_SLOTS]Stack{}
		copy(before[:], grid)
		slots_sort(reg, grid)
		same := true
		for s, i in grid {if s != before[i] {same = false}}
		if same {return}
	case .Swap_Offhand:
		hand, off := &inv.slots[inv.selected], &inv.equipment[.Offhand]
		if stack_empty(hand^) && stack_empty(off^) {return}
		hand^, off^ = off^, hand^
	case .Close:
		if stack_empty(inv.cursor) && !inv.chest_open {return}
		inv.chest, inv.chest_open = {}, false
		dropped = inventory_add(reg, inv, inv.cursor)
		inv.cursor = {}
	}
	inventory_tidy(inv)
	return dropped, true
}

// inventory_add puts stack in: onto stacks of its item first (the hotbar
// first), then into empty slots. What does not fit is returned.
inventory_add :: proc(reg: ^Registry, inv: ^Inventory, stack: Stack) -> (left: Stack) {
	left = slots_add(reg, inv.slots[:], stack)
	inventory_tidy(inv)
	return
}

// slots_sort merges the stacks of one item (up to its stack size) and puts
// them in item order, the empty slots last.
@(private = "file")
slots_sort :: proc(reg: ^Registry, slots: []Stack) {
	items := make([dynamic]Stack, context.temp_allocator)
	for s in slots {if !stack_empty(s) {append(&items, s)}}
	slice.stable_sort_by(items[:], proc(a, b: Stack) -> bool {return a.item < b.item})
	n := 0
	for &s in slots {s = {}}
	for it in items {
		size := item_stack_size(reg, it.item)
		left := it.count
		if n > 0 && slots[n - 1].item == it.item && slots[n - 1].count < size {
			moved := min(left, size - slots[n - 1].count)
			slots[n - 1].count += moved
			left -= moved
		}
		for left > 0 && n < len(slots) {
			put := min(left, size)
			slots[n] = with_count(it, put)
			left -= put
			n += 1
		}
	}
}

@(private = "file")
slots_add :: proc(reg: ^Registry, slots: []Stack, stack: Stack) -> Stack {
	left := stack
	size := item_stack_size(reg, stack.item)
	if stack_empty(left) || size == 0 {return left}
	for &s in slots {
		if left.count == 0 {break}
		if s.item != left.item || stack_empty(s) {continue}
		moved := min(left.count, size - s.count)
		if moved > 0 {
			s.count += moved
			left.count -= moved
		}
	}
	for &s in slots {
		if left.count == 0 {break}
		if !stack_empty(s) {continue}
		moved := min(left.count, size)
		s = with_count(left, moved)
		left.count -= moved
	}
	if left.count == 0 {left = {}}
	return left
}

// inventory_held: the stack in hand.
inventory_held :: proc(inv: ^Inventory) -> Stack {
	return inv.slots[clamp(inv.selected, 0, HOTBAR_SLOTS - 1)]
}

// inventory_use_held takes one from the stack in hand (placing a block).
inventory_use_held :: proc(inv: ^Inventory) {
	s := &inv.slots[clamp(inv.selected, 0, HOTBAR_SLOTS - 1)]
	if s.count > 0 {s.count -= 1}
	inventory_tidy(inv)
}

// inventory_placing_slot: the slot placing block takes one from: the stack
// in hand if it is that block's item, else the first hotbar stack of it
// (the hand may have moved on since the edit was made); -1 if none.
inventory_placing_slot :: proc(reg: ^Registry, inv: ^Inventory, block: Block) -> int {
	item := placing_item(reg, block)
	if item == NO_ITEM {return -1}
	if inv.slots[inv.selected].item == item {return inv.selected}
	for st, i in inv.slots[:HOTBAR_SLOTS] {if st.item == item {return i}}
	return -1
}

// inventory_count: how many of item it holds (the cursor too).
inventory_count :: proc(inv: ^Inventory, item: Item) -> int {
	n := 0
	for s in inv.slots {if s.item == item {n += s.count}}
	for s in inv.equipment {if s.item == item {n += s.count}}
	if inv.cursor.item == item {n += inv.cursor.count}
	return n
}

// inventory_remove takes up to count of item (NO_ITEM: of everything);
// how many it took.
inventory_remove :: proc(inv: ^Inventory, item: Item, count: int) -> int {
	taken := 0
	for &s in inv.slots {
		if taken == count {break}
		if stack_empty(s) || (item != NO_ITEM && s.item != item) {continue}
		n := min(s.count, count - taken)
		s.count -= n
		taken += n
	}
	inventory_tidy(inv)
	return taken
}

// inventory_tidy: empty stacks are {} (so equal inventories compare equal).
inventory_tidy :: proc(inv: ^Inventory) {
	for &s in inv.slots {if stack_empty(s) {s = {}}}
	for &s in inv.equipment {if stack_empty(s) {s = {}}}
	for &s in inv.chest {if stack_empty(s) {s = {}}}
	if stack_empty(inv.cursor) {inv.cursor = {}}
}

// inventory_valid: every stack is a known item within its size (a decoded
// inventory, a loaded one).
inventory_valid :: proc(reg: ^Registry, inv: ^Inventory) -> bool {
	if inv.selected < 0 || inv.selected >= HOTBAR_SLOTS {return false}
	check :: proc(reg: ^Registry, s: Stack) -> bool {
		return(
			stack_empty(s) ||
			(item_valid(reg, s.item) && s.count <= item_stack_size(reg, s.item)) \
		)
	}
	for s in inv.slots {if !check(reg, s) {return false}}
	for s in inv.chest {if !check(reg, s) {return false}}
	for s, e in inv.equipment {if !check(reg, s) || !item_fits(reg, s, e) {return false}}
	return check(reg, inv.cursor)
}
