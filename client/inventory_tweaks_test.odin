package client

import "core:mem/virtual"
import "core:testing"

import "../font"
import "../game"
import "../ui"

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
	testing.expect(t, item_icons_init(&f.app.item_icons, &f.app.ui))
	f.s = new(Session)
	game.pipe_init(&f.pipe)
	f.s.endpoint = {&f.pipe, .Client}
	game.writer_init(&f.s.writer)
	f.s.state = .Playing
	if catalog {append(&f.s.grants, game.Grant{pattern = "items.catalog", allow = true})}
	f.app.session = f.s
	f.app.screen = .Game
	f.app.input.pressed = {.E}
	inventory_keys(f.app)
	f.app.input.pressed = {}
	testing.expect(t, overlay_is_open(&f.app.overlays, .Inventory))
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
	stone, dirt := game.item_of_block(.Stone), game.item_of_block(.Dirt)
	at := proc(f: ^Overlay_Fixture, slot: int) -> ui.Vec2 {return overlay_slot_at(f, slot)}

	// Shift-drag over slots 5, 6 and 7 (and the empty 8): all go to the hotbar.
	inv.slots[5], inv.slots[6], inv.slots[7] = {stone, 3}, {dirt, 4}, {stone, 5}
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
		inv.slots[0] == {stone, 8} && inv.slots[1] == {dirt, 4},
		"shift-drag moved them",
	)
	for slot in 5 ..= 8 {testing.expect(t, game.stack_empty(inv.slots[slot]))}

	// Right-drag with 10 stone: one each into 20, 21 (empty) and 22 (dirt: skipped).
	inv.slots[22] = {dirt, 1}
	inv.cursor = {stone, 10}
	overlay_frame(&f, {mouse = at(&f, 20), mouse_pressed = {.Right}, mouse_down = {.Right}})
	for slot in 21 ..= 23 {overlay_frame(&f, {mouse = at(&f, slot), mouse_down = {.Right}})}
	overlay_frame(&f, {mouse = at(&f, 23), mouse_released = {.Right}})
	testing.expect(
		t,
		inv.slots[20] == {stone, 1} && inv.slots[21] == {stone, 1} && inv.slots[23] == {stone, 1},
	)
	testing.expect(
		t,
		inv.slots[22] == {dirt, 1} && inv.cursor == {stone, 7},
		"one each, dirt left alone",
	)

	// Left-drag with 7 stone over four empty slots (and one of dirt): 7 / 4 = 1 each, 3 left.
	// A slot already holding stone takes its share too.
	inv.slots[20], inv.slots[21], inv.slots[23] = {}, {}, {}
	inv.slots[24] = {stone, 2}
	overlay_frame(&f, {mouse = at(&f, 20), mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect_value(t, inv.cursor.count, 7) // nothing yet: a click or a share
	for slot in ([]int{21, 22, 23, 24}) {overlay_frame(&f, {mouse = at(&f, slot), mouse_down = {.Left}})}
	overlay_frame(&f, {mouse = at(&f, 24), mouse_released = {.Left}})
	// Four slots take it (20, 21, 23, 24; 22 holds dirt): 7 / 4 = 1 each.
	testing.expect(
		t,
		inv.slots[20] == {stone, 1} && inv.slots[21] == {stone, 1} && inv.slots[23] == {stone, 1},
	)
	testing.expect(t, inv.slots[24] == {stone, 3} && inv.cursor == {stone, 3}, "shared evenly")
	// A press and release on one slot is a plain click.
	overlay_frame(&f, {mouse = at(&f, 25), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 25), mouse_released = {.Left}})
	testing.expect(t, inv.slots[25] == {stone, 3} && game.stack_empty(inv.cursor))

	// Double-click: the first press picks up, the second gathers every stack of it.
	inv^ = {}
	inv.slots[5], inv.slots[9], inv.slots[12], inv.slots[13] =
		{stone, 10}, {stone, 20}, {dirt, 7}, {stone, 5}
	overlay_frame(&f, {mouse = at(&f, 5), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_released = {.Left}})
	testing.expect(t, inv.cursor == {stone, 10})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at(&f, 5), mouse_released = {.Left}})
	testing.expect(
		t,
		inv.cursor == {stone, 35} && game.inventory_count(inv, stone) == 35,
		"gathered",
	)
	testing.expect(t, inv.slots[12] == {dirt, 7})
	inventory_close(f.app)
	f.app.input.pressed = {.E}
	inventory_keys(f.app) // open again
	f.app.input.pressed = {}

	// The wheel over a slot: up moves one out of it to the other section, down one into it.
	inv^ = {}
	inv.slots[7] = {stone, 3}
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, 1}})
	testing.expect(t, inv.slots[7].count == 2 && inv.slots[0] == {stone, 1})
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, 1}})
	testing.expect(t, inv.slots[7].count == 1 && inv.slots[0] == {stone, 2})
	overlay_frame(&f, {mouse = at(&f, 7), wheel = {0, -1}})
	testing.expect(t, inv.slots[7].count == 2 && inv.slots[0] == {stone, 1})
	overlay_frame(&f, {mouse = at(&f, 0), wheel = {0, -1}}) // nothing in the rest to pull... 7 holds one
	testing.expect(t, inv.slots[0] == {stone, 2} && inv.slots[7].count == 1)
}

// Middle click: in the inventory it takes a full stack of the slot's item
// (with items.catalog); over the game it picks the block aimed at.
@(test)
test_pick_block :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	inv := &f.s.inventory
	stone, dirt := game.item_of_block(.Stone), game.item_of_block(.Dirt)

	inv.slots[7] = {dirt, 1}
	overlay_frame(&f, {mouse = overlay_slot_at(&f, 7), mouse_pressed = {.Middle}})
	testing.expect(t, inv.cursor == {dirt, 64}, "a full stack, from the catalog")
	inventory_close(f.app)
	testing.expect_value(t, game.inventory_count(inv, dirt), 65)

	// Aimed at stone.
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, world_init(&f.s.world, 64, 16, 1, virtual.arena_allocator(&arena)) == nil)
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
	inv.slots[1] = {dirt, 5}
	inv.slots[3] = {stone, 9}
	inv.selected = 1
	testing.expect(t, session_pick(f.s))
	testing.expect_value(t, inv.selected, 3) // the slot holding it
	// None holds it: a stack goes into the first empty slot (the hand's is full), and is held.
	inv.slots[3] = {}
	inv.selected = 1
	testing.expect(t, session_pick(f.s))
	testing.expect(
		t,
		inv.selected == 0 && inv.slots[0] == {stone, 64} && inv.slots[1] == {dirt, 5},
	)
	// The hand's slot is empty: used. A full hotbar: the hand's stack is replaced (and kept).
	inv^ = {}
	inv.selected = 2
	testing.expect(t, session_pick(f.s) && inv.slots[2] == {stone, 64})
	for i in 0 ..< game.HOTBAR_SLOTS {inv.slots[i] = {dirt, 2}}
	inv.selected = 4
	testing.expect(t, session_pick(f.s) && inv.slots[4] == {stone, 64})
	testing.expect_value(t, game.inventory_count(inv, dirt), 10)
	// Without items.catalog: only what the hotbar holds.
	clear(&f.s.grants)
	inv^ = {}
	testing.expect(t, !session_pick(f.s))
	// A block with no item (bedrock) picks nothing.
	append(&f.s.grants, game.Grant{pattern = "items.catalog", allow = true})
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
	for item in game.every_item() {
		icon, ok := f.app.item_icons[item]
		testing.expectf(t, ok, "%v has no icon", game.item_name(item))
		img := atlas.icons[icon]
		opaque := 0
		for p in img.pixels {if p.a > 0 {opaque += 1}}
		testing.expectf(t, opaque >= 24, "%v's icon is nearly blank", game.item_name(item))
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
	dirt := game.item_of_block(.Dirt)

	// The tab button switches; the rest of the inventory is not shown on it.
	overlay_frame(&f, {})
	l := inventory_layout(&f.app.ui, .Inventory)
	creative := ui.Vec2{l.title.x + 140 + f.app.ui.theme.spacing + 70, l.title.y + l.title.h / 2}
	overlay_frame(&f, {mouse = creative})
	overlay_frame(&f, {mouse = creative, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = creative, mouse_released = {.Left}})
	testing.expect_value(t, v.tab, Inventory_Tab.Creative)
	c := inventory_layout(&f.app.ui, .Creative)
	testing.expect(t, c.slots[10].w == 0 && c.slots[0].w > 0 && c.catalog.w > 0)
	testing.expect(t, c.slots[0] == l.slots[0], "the hotbar does not move between tabs")

	// A search narrows the catalog.
	testing.expect_value(t, len(matching_items("")), len(game.every_item()))
	found := matching_items("DIR")
	testing.expect(t, len(found) == 1 && found[0] == dirt)
	testing.expect_value(t, len(matching_items("no such item")), 0)

	// Clicking the first catalog item takes a stack; a click on a hotbar slot puts it there.
	first := game.every_item()[0]
	cell := ui.Vec2{c.catalog.x + INVENTORY_SLOT.x / 2, c.catalog.y + INVENTORY_SLOT.y / 2}
	overlay_frame(&f, {mouse = cell, mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect_value(t, inv.cursor, game.Stack{first, 64})
	slot := ui.Vec2{c.slots[4].x + 5, c.slots[4].y + 5}
	overlay_frame(&f, {mouse = slot, mouse_released = {.Left}})
	overlay_frame(&f, {mouse = slot, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = slot, mouse_released = {.Left}})
	testing.expect_value(t, inv.slots[4], game.Stack{first, 64})

	// Without items.catalog there is no Creative tab to be on.
	clear(&f.s.grants)
	overlay_frame(&f, {})
	testing.expect_value(t, v.tab, Inventory_Tab.Inventory)
}
