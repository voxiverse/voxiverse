package client

import "core:mem/virtual"
import "core:testing"

import "../common/game"
import "font"
import "ui"

// A session in the inventory overlay, for driving it with the mouse.
Overlay_Fixture :: struct {
	app:  ^App,
	s:    ^Session,
	pipe: game.Pipe,
}

SCREEN :: ui.Vec2{1280, 720}

overlay_fixture :: proc(t: ^testing.T, f: ^Overlay_Fixture, catalog: bool) {
	f.app = new(App)
	f.app.settings = SETTINGS_DEFAULTS
	ok: bool
	f.app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&f.app.ui, &f.app.font))
	testing.expect(t, item_icons_init(test_reg(), &f.app.item_icons, &f.app.ui))
	f.s = new(Session)
	game.pipe_init(&f.pipe)
	f.s.endpoint = {&f.pipe, .Client}
	game.writer_init(&f.s.writer)
	f.s.state = .Playing
	f.s.reg = test_reg()
	test_mode(f.s, "creative" if catalog else "survival")
	f.app.session = f.s
	f.app.screen = .Game
	f.app.input.pressed = {.Tab}
	actions_sync(f.app)
	player_menu_keys(f.app)
	f.app.input.pressed = {}
	actions_sync(f.app)
	testing.expect(t, section_open(f.app, .Inventory))
}

overlay_fixture_destroy :: proc(f: ^Overlay_Fixture) {
	f.app.session = nil
	delete(f.s.inv_pending)
	delete(f.s.grants)
	game.writer_destroy(&f.s.writer)
	game.pipe_destroy(&f.pipe)
	free(f.s)
	delete(f.app.item_icons)
	delete(f.app.inventory_search)
	ui.destroy(&f.app.ui)
	free(f.app)
	free_all(context.temp_allocator)
}

overlay_frame :: proc(f: ^Overlay_Fixture, in_: ui.Input) {
	ui.begin_frame(&f.app.ui, in_, SCREEN, 1)
	draw_overlays(f.app, &f.app.ui)
	ui.end_frame(&f.app.ui)
}

// ui_begin, ui_end: one UI frame at the test screen size.
ui_begin :: proc(app: ^App) {
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
}

ui_end :: proc(app: ^App) {
	ui.end_frame(&app.ui)
}

overlay_slot_at :: proc(f: ^Overlay_Fixture, slot: int) -> ui.Vec2 {
	ui.begin_frame(&f.app.ui, {}, SCREEN, 1)
	l := inventory_layout(&f.app.ui, f.app.inventory_view.tab)
	ui.end_frame(&f.app.ui)
	r := l.slots[slot]
	return {r.x + r.w / 2, r.y + r.h / 2}
}

// Shift-drag quick-moves every slot passed; a right-drag puts one into each
// slot passed; a left-drag shares the stack on the cursor over the slots
// passed; a double-click gathers every stack of the item; the wheel moves
// one at a time between the hotbar and the rest.
@(test)
test_inventory_mouse_tweaks :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	inv := &f.s.inventory
	stone, dirt := game.item_of_block(test_reg(), .Stone), game.item_of_block(test_reg(), .Dirt)
	at := proc(f: ^Overlay_Fixture, slot: int) -> ui.Vec2 {return overlay_slot_at(f, slot)}

	// Shift-drag over slots 5, 6 and 7 (and the empty 8): all go to the hotbar.
	inv.slots[5], inv.slots[6], inv.slots[7] = {stone, 3, 0}, {dirt, 4, 0}, {stone, 5, 0}
	overlay_frame(
		&f,
		{mouse = at(&f, 5), mouse_pressed = {.Left}, mouse_down = {.Left}, modifiers = {.Shift}},
	)
	for slot in 6 ..= 8 {
		overlay_frame(&f, {mouse = at(&f, slot), mouse_down = {.Left}, modifiers = {.Shift}})
	}
	overlay_frame(&f, {mouse = at(&f, 8), mouse_released = {.Left}})
	testing.expect(
		t,
		inv.slots[0] == {stone, 8, 0} && inv.slots[1] == {dirt, 4, 0},
		"shift-drag moved them",
	)
	for slot in 5 ..= 8 {testing.expect(t, game.stack_empty(inv.slots[slot]))}

	// Right-drag with 10 stone: one each into 20, 21 (empty) and 22 (dirt: skipped).
	inv.slots[22] = {dirt, 1, 0}
	inv.cursor = {stone, 10, 0}
	overlay_frame(&f, {mouse = at(&f, 20), mouse_pressed = {.Right}, mouse_down = {.Right}})
	for slot in 21 ..= 23 {overlay_frame(&f, {mouse = at(&f, slot), mouse_down = {.Right}})}
	overlay_frame(&f, {mouse = at(&f, 23), mouse_released = {.Right}})
	testing.expect(
		t,
		inv.slots[20] == {stone, 1, 0} &&
		inv.slots[21] == {stone, 1, 0} &&
		inv.slots[23] == {stone, 1, 0},
	)
	testing.expect(
		t,
		inv.slots[22] == {dirt, 1, 0} && inv.cursor == {stone, 7, 0},
		"one each, dirt left alone",
	)

	// Left-drag with 7 stone over four empty slots (and one of dirt): 7 / 4 = 1 each, 3 left.
	// A slot already holding stone takes its share too.
	inv.slots[20], inv.slots[21], inv.slots[23] = {}, {}, {}
	inv.slots[24] = {stone, 2, 0}
	overlay_frame(&f, {mouse = at(&f, 20), mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect_value(t, inv.cursor.count, 7) // nothing yet: a click or a share
	for slot in ([]int{21, 22, 23, 24}) {overlay_frame(&f, {mouse = at(&f, slot), mouse_down = {.Left}})}
	overlay_frame(&f, {mouse = at(&f, 24), mouse_released = {.Left}})
	// Four slots take it (20, 21, 23, 24; 22 holds dirt): 7 / 4 = 1 each.
	testing.expect(
		t,
		inv.slots[20] == {stone, 1, 0} &&
		inv.slots[21] == {stone, 1, 0} &&
		inv.slots[23] == {stone, 1, 0},
	)
	testing.expect(
		t,
		inv.slots[24] == {stone, 3, 0} && inv.cursor == {stone, 3, 0},
		"shared evenly",
	)
	// A press and release on one slot is a plain click.
	overlay_frame(&f, {mouse = at(&f, 25), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 25), mouse_released = {.Left}})
	testing.expect(t, inv.slots[25] == {stone, 3, 0} && game.stack_empty(inv.cursor))

	// Double-click: the first press picks up, the second gathers every stack of it.
	inv^ = {}
	inv.slots[5], inv.slots[9], inv.slots[12], inv.slots[13] =
		{stone, 10, 0}, {stone, 20, 0}, {dirt, 7, 0}, {stone, 5, 0}
	overlay_frame(&f, {mouse = at(&f, 5), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_released = {.Left}})
	testing.expect(t, inv.cursor == {stone, 10, 0})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_released = {.Left}})
	testing.expect(
		t,
		inv.cursor == {stone, 35, 0} && game.inventory_count(inv, stone) == 35,
		"gathered",
	)
	testing.expect(t, inv.slots[12] == {dirt, 7, 0})
	player_menu_close(f.app)
	f.app.input.pressed = {.Tab}
	actions_sync(f.app)
	player_menu_keys(f.app) // open again
	f.app.input.pressed = {}
	actions_sync(f.app)

	// The wheel over a slot: up moves one out of it to the other section, down one into it.
	inv^ = {}
	inv.slots[7] = {stone, 3, 0}
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, 1}})
	testing.expect(t, inv.slots[7].count == 2 && inv.slots[0] == {stone, 1, 0})
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, 1}})
	testing.expect(t, inv.slots[7].count == 1 && inv.slots[0] == {stone, 2, 0})
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, -1}})
	testing.expect(t, inv.slots[7].count == 2 && inv.slots[0] == {stone, 1, 0})
	overlay_frame(&f, {mouse = at(&f, 0), wheel = {0, -1}}) // nothing in the rest to pull... 7 holds one
	testing.expect(t, inv.slots[0] == {stone, 2, 0} && inv.slots[7].count == 1)
}

// Middle click: in the inventory it takes a full stack of the slot's item
// (with items.catalog); over the game it picks the block aimed at.
@(test)
test_pick_block :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	inv := &f.s.inventory
	stone, dirt := game.item_of_block(test_reg(), .Stone), game.item_of_block(test_reg(), .Dirt)

	inv.slots[7] = {dirt, 1, 0}
	overlay_frame(&f, {mouse = overlay_slot_at(&f, 7), mouse_pressed = {.Middle}})
	testing.expect(t, inv.cursor == {dirt, 64, 0}, "a full stack, from the catalog")
	player_menu_close(f.app)
	testing.expect_value(t, game.inventory_count(inv, dirt), 65)

	// Aimed at stone.
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(
		t,
		world_init(&f.s.world, test_reg(), 64, 16, 1, virtual.arena_allocator(&arena)) == nil,
	)
	defer world_destroy(&f.s.world)
	column := game.Column {
		pos = {0, 0},
	}
	world_set_column(&f.s.world, column)
	scratch := new(game.Block_Array)
	defer free(scratch)
	testing.expect(
		t,
		world_set_chunk(
			&f.s.world,
			{pos = {0, 0, 0}, uniform = .Stone, is_uniform = true},
			scratch,
		),
	)
	f.s.aim = game.Ray_Hit {
		block = {1, 1, 1},
	}
	inv^ = {}
	inv.slots[1] = {dirt, 5, 0}
	inv.slots[3] = {stone, 9, 0}
	inv.selected = 1
	testing.expect(t, session_pick(f.s))
	testing.expect_value(t, inv.selected, 3) // the slot holding it
	// None holds it: a stack goes into the first empty slot (the hand's is full), and is held.
	inv.slots[3] = {}
	inv.selected = 1
	testing.expect(t, session_pick(f.s))
	testing.expect(
		t,
		inv.selected == 0 && inv.slots[0] == {stone, 64, 0} && inv.slots[1] == {dirt, 5, 0},
	)
	// The hand's slot is empty: used. A full hotbar: the hand's stack is replaced (and kept).
	inv^ = {}
	inv.selected = 2
	testing.expect(t, session_pick(f.s) && inv.slots[2] == {stone, 64, 0})
	for i in 0 ..< game.HOTBAR_SLOTS {inv.slots[i] = {dirt, 2, 0}}
	inv.selected = 4
	testing.expect(t, session_pick(f.s) && inv.slots[4] == {stone, 64, 0})
	testing.expect_value(t, game.inventory_count(inv, dirt), 10)
	// Without items.catalog: only what the hotbar holds.
	test_mode(f.s, "survival")
	inv^ = {}
	testing.expect(t, !session_pick(f.s))
	// A block with no item (bedrock) picks nothing.
	test_mode(f.s, "creative")
	testing.expect(t, world_set_block(&f.s.world, {1, 1, 1}, .Bedrock))
	testing.expect(t, !session_pick(f.s))
	free_all(context.temp_allocator)
}

// Every item has an icon with something in it (none blank); the first
// inventory screenshot of CI shows them.
@(test)
test_item_icons :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	atlas := &f.app.ui.glyphs
	for item in game.every_item(test_reg()) {
		icon, ok := f.app.item_icons[item]
		testing.expectf(t, ok, "%v has no icon", game.item_name(test_reg(), item))
		img := atlas.icons[icon]
		opaque := 0
		for p in img.pixels {if p.a > 0 {opaque += 1}}
		testing.expectf(
			t,
			opaque >= 24,
			"%v's icon is nearly blank",
			game.item_name(test_reg(), item),
		)
		// And it is in the atlas as made.
		at := (img.at.y * atlas.size + img.at.x) * 4
		testing.expect(t, atlas.pixels[at + 3] == img.pixels[0][3])
	}
}

// The Creative tab: only with items.catalog; the catalog and a search to
// narrow it, a click takes a full stack, and the hotbar stays under it.
@(test)
test_creative_tab :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	inv := &f.s.inventory
	v := &f.app.inventory_view
	dirt := game.item_of_block(test_reg(), .Dirt)

	// The tab button switches; the rest of the inventory is not shown on it.
	overlay_frame(&f, {})
	l := inventory_layout(&f.app.ui, .Inventory)
	creative := ui.Vec2{l.title.x + l.title.w - SECTION_TAB_WIDTH / 2, l.title.y + l.title.h / 2}
	overlay_frame(&f, {mouse = creative})
	overlay_frame(&f, {mouse = creative, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = creative, mouse_released = {.Left}})
	testing.expect_value(t, v.tab, Inventory_Tab.Creative)
	c := inventory_layout(&f.app.ui, .Creative)
	testing.expect(t, c.slots[10].w == 0 && c.slots[0].w > 0 && c.catalog.w > 0)
	testing.expect(t, c.slots[0] == l.slots[0], "the hotbar does not move between tabs")

	// A search narrows the catalog.
	testing.expect_value(t, len(matching_items(test_reg(), "")), len(game.every_item(test_reg())))
	found := matching_items(test_reg(), "DIR")
	testing.expect(t, len(found) == 1 && found[0] == dirt)
	testing.expect_value(t, len(matching_items(test_reg(), "no such item")), 0)

	// Clicking the first catalog item takes a stack; a click on a hotbar slot puts it there.
	first := game.every_item(test_reg())[0]
	cell := ui.Vec2{c.catalog.x + INVENTORY_SLOT.x / 2, c.catalog.y + INVENTORY_SLOT.y / 2}
	overlay_frame(&f, {mouse = cell, mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect_value(t, inv.cursor, game.Stack{first, 64, 0})
	slot := ui.Vec2{c.slots[4].x + 5, c.slots[4].y + 5}
	overlay_frame(&f, {mouse = slot, mouse_released = {.Left}})
	overlay_frame(&f, {mouse = slot, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = slot, mouse_released = {.Left}})
	testing.expect_value(t, inv.slots[4], game.Stack{first, 64, 0})

	// Without the catalog ability there is no Creative tab to be on.
	test_mode(f.s, "survival")
	overlay_frame(&f, {})
	testing.expect_value(t, v.tab, Inventory_Tab.Inventory)
}

// The equipment slots beside the preview: a click puts armor on (only into
// the slot it fits), shift-click moves it between the slots and the
// inventory; the preview asks to be drawn and turns toward the mouse.
@(test)
test_equipment_slots :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	inv := &f.s.inventory
	cap_, boots := game.item_of_armor(.Cap), game.item_of_armor(.Boots)
	head := game.EQUIP_BASE + int(game.Equip_Slot.Head)
	feet := game.EQUIP_BASE + int(game.Equip_Slot.Feet)
	click :: proc(f: ^Overlay_Fixture, slot: int, modifiers: bit_set[ui.Modifier] = {}) {
		at := overlay_slot_at(f, slot)
		overlay_frame(
			f,
			{mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}, modifiers = modifiers},
		)
		overlay_frame(f, {mouse = at, mouse_released = {.Left}})
	}

	overlay_frame(&f, {}) // (sets the screen's size)
	l := inventory_layout(&f.app.ui, .Inventory)
	testing.expect(t, l.slots[head].w > 0 && l.slots[feet].w > 0 && l.preview.w > 0)
	for e in 0 ..< game.EQUIP_SLOTS {
		r := l.slots[game.EQUIP_BASE + e]
		testing.expect(t, r.x + r.w <= l.preview.x, "the slots are left of the player")
	}

	// A cap on the cursor: the feet refuse it, the head takes it.
	inv.cursor = {cap_, 1, 0}
	click(&f, feet)
	testing.expect(t, inv.cursor == {cap_, 1, 0} && game.stack_empty(inv.equipment[.Feet]))
	click(&f, head)
	testing.expect(t, inv.equipment[.Head] == {cap_, 1, 0} && game.stack_empty(inv.cursor))
	// Boots in the inventory: shift-click puts them on.
	inv.slots[8] = {boots, 1, 0}
	click(&f, 8, {.Shift})
	testing.expect(t, inv.equipment[.Feet] == {boots, 1, 0} && game.stack_empty(inv.slots[8]))
	// Shift-click on a worn cap takes it off.
	click(&f, head, {.Shift})
	testing.expect(
		t,
		game.stack_empty(inv.equipment[.Head]) && game.inventory_count(inv, cap_) == 1,
	)

	// The preview: asked for each frame, turning toward the mouse.
	f.app.preview.active = false
	left := ui.Vec2{l.preview.x - 20, l.preview.y + l.preview.h / 2}
	overlay_frame(&f, {mouse = left})
	testing.expect(t, f.app.preview.active)
	testing.expect(t, f.app.preview.target_yaw < 0, "the mouse is left of the player")
	right := ui.Vec2{l.preview.x + l.preview.w + 200, l.preview.y + l.preview.h / 2}
	overlay_frame(&f, {mouse = right})
	testing.expect(t, f.app.preview.target_yaw > 0)
	above := ui.Vec2{l.preview.x + l.preview.w / 2, l.preview.y - 100}
	overlay_frame(&f, {mouse = above})
	testing.expect(t, f.app.preview.target_pitch > 0, "looks up at a mouse above")
	// Not drawn on the other tab.
	f.app.preview.active = false
	f.app.inventory_view.tab = .Creative
	overlay_frame(&f, {})
	testing.expect(t, !f.app.preview.active)
}
