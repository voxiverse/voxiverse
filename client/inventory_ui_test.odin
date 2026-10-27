package client

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "../common/game"
import "font"
import "platform"
import "ui"

// The inventory overlay with the mouse: dragging a stack to another slot,
// right-click halves, shift-click to the hotbar, a number key, dropping
// outside; each a request predicted at once and sent.
@(test)
test_inventory_overlay :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	s := new(Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer delete(s.inv_pending)
	defer delete(app.inventory_search)
	s.state = .Playing
	app.session = s
	defer app.session = nil
	app.screen = .Game
	stone, dirt := game.item_of_block(.Stone), game.item_of_block(.Dirt)
	s.inventory.slots[9] = {stone, 64}
	s.inventory.slots[0] = {dirt, 10}

	app.input.pressed = {.E}
	inventory_keys(app)
	app.input.pressed = {}
	testing.expect(t, overlay_is_open(&app.overlays, .Inventory))

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	at :: proc(app: ^App, slot: int) -> ui.Vec2 {
		ui.begin_frame(&app.ui, {}, SCREEN, 1)
		l := inventory_layout(&app.ui, .Inventory)
		ui.end_frame(&app.ui)
		r := l.slots[slot]
		return {r.x + r.w / 2, r.y + r.h / 2}
	}
	inv := &s.inventory
	// Drag the stone from slot 9 to slot 20.
	frame(app, {mouse = at(app, 9), mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect(t, inv.cursor == {stone, 64})
	frame(app, {mouse = at(app, 20), mouse_down = {.Left}})
	frame(app, {mouse = at(app, 20), mouse_released = {.Left}})
	testing.expect(
		t,
		inv.slots[20] == {stone, 64} &&
		game.stack_empty(inv.slots[9]) &&
		game.stack_empty(inv.cursor),
	)
	// Right-click: half up; a click puts them in slot 21.
	frame(app, {mouse = at(app, 20), mouse_pressed = {.Right}, mouse_down = {.Right}})
	testing.expect(t, inv.cursor == {stone, 32} && inv.slots[20] == {stone, 32})
	frame(app, {mouse = at(app, 21), mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = at(app, 21), mouse_released = {.Left}})
	testing.expect(t, inv.slots[21] == {stone, 32} && game.stack_empty(inv.cursor))
	// Shift-click: into the hotbar (slot 0 holds dirt: the next free one).
	frame(
		app,
		{mouse = at(app, 21), mouse_pressed = {.Left}, mouse_down = {.Left}, modifiers = {.Shift}},
	)
	testing.expect(t, inv.slots[1] == {stone, 32} && game.stack_empty(inv.slots[21]))
	// A number key over a slot swaps it with that hotbar slot.
	app.input.pressed = {.Num_3}
	frame(app, {mouse = at(app, 20)})
	app.input.pressed = {}
	testing.expect(t, inv.slots[2] == {stone, 32} && game.stack_empty(inv.slots[20]))
	// Pick up the dirt; a click outside the panel drops it all.
	frame(app, {mouse = at(app, 0), mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = at(app, 0), mouse_released = {.Left}})
	frame(app, {mouse = {5, 5}, mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect(t, game.stack_empty(inv.cursor) && game.inventory_count(inv, dirt) == 0)
	testing.expect_value(t, len(s.inv_pending), 8) // each click, the swap, the drop
	// Closing with a stack on the cursor puts it back.
	frame(app, {mouse = at(app, 1), mouse_pressed = {.Right}, mouse_down = {.Right}})
	escape(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Inventory))
	testing.expect(t, game.stack_empty(inv.cursor) && game.inventory_count(inv, stone) == 64)
	// No catalog without items.catalog: taking is refused before it is sent.
	before := len(s.inv_pending)
	testing.expect(t, !session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(dirt)}))
	testing.expect_value(t, len(s.inv_pending), before)
	free_all(context.temp_allocator)
}

// The characters screen: the account's characters to choose from; a click
// on one chooses it (the session joins as it).
@(test)
test_characters_screen :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	defer delete(app.new_character)
	s := new(Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer {for c in s.characters {delete(c)}; delete(s.characters)}
	defer {for n in s.notices {delete(n)}; delete(s.notices)}
	defer {for e in s.chat {delete(e.text)}; delete(s.chat)}
	defer virtual.arena_destroy(&s.arena)
	append(&s.characters, strings.clone("alice"), strings.clone("bob"))
	s.state = .Choosing
	app.session = s
	defer app.session = nil
	app.screen = .Game
	SCREEN :: ui.Vec2{1280, 720}
	th := &app.ui.theme
	rows := len(s.characters) + 3
	column := ui.rect_center(
		{0, 0, SCREEN.x, SCREEN.y},
		360,
		f32(rows) * (th.row_height + th.spacing) + 80,
	)
	bob := ui.Vec2 {
		column.x + 180,
		column.y + 80 + (th.row_height + th.spacing) + th.row_height / 2,
	}
	ui.begin_frame(&app.ui, {mouse = bob}, SCREEN, 1)
	app_ui(app, &app.ui)
	ui.end_frame(&app.ui)
	ui.begin_frame(
		&app.ui,
		{mouse = bob, mouse_pressed = {.Left}, mouse_down = {.Left}},
		SCREEN,
		1,
	)
	app_ui(app, &app.ui)
	ui.end_frame(&app.ui)
	ui.begin_frame(&app.ui, {mouse = bob, mouse_released = {.Left}}, SCREEN, 1)
	app_ui(app, &app.ui)
	ui.end_frame(&app.ui)
	testing.expect_value(t, s.state, Session_State.Connecting)
	testing.expect_value(t, s.config.name, "bob")
	free_all(context.temp_allocator)
}

// A chest the server opened shows the overlay with the chest beside the
// inventory; a stack shift-clicked goes in (predicted, a request sent); the
// overlay closing sends the Close, and a chest that closes by itself takes
// the overlay down.
@(test)
test_chest_overlay :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	s := new(Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer delete(s.inv_pending)
	defer delete(app.inventory_search)
	s.state = .Playing
	app.session = s
	defer app.session = nil
	app.screen = .Game
	stone := game.item_of_block(.Stone)
	s.inventory.slots[9] = {stone, 64}

	chest_sync(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Inventory), "opened with no chest")
	s.inventory.chest_open = true
	chest_sync(app)
	testing.expect(t, overlay_is_open(&app.overlays, .Inventory))
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Chest)

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	l := inventory_layout(&app.ui, .Chest)
	ui.end_frame(&app.ui)
	for i in 0 ..< game.CHEST_SLOTS {
		testing.expectf(t, l.slots[game.CHEST_BASE + i].w > 0, "chest slot %d has no place", i)
	}
	testing.expect(t, l.slots[game.EQUIP_BASE].w == 0, "equipment shown beside a chest")
	for a in 0 ..< game.ALL_SLOTS {
		for b in a + 1 ..< game.ALL_SLOTS {
			ra, rb := l.slots[a], l.slots[b]
			if ra.w == 0 || rb.w == 0 {continue}
			overlap :=
				ra.x < rb.x + rb.w &&
				rb.x < ra.x + ra.w &&
				ra.y < rb.y + rb.h &&
				rb.y < ra.y + ra.h
			testing.expectf(t, !overlap, "slots %d and %d overlap", a, b)
		}
	}
	r := l.slots[9]
	frame(
		app,
		{
			mouse = {r.x + r.w / 2, r.y + r.h / 2},
			mouse_pressed = {.Left},
			mouse_down = {.Left},
			modifiers = {.Shift},
		},
	)
	testing.expect(
		t,
		s.inventory.chest[0] == {stone, 64} && game.stack_empty(s.inventory.slots[9]),
		"shift-click did not move it in",
	)
	testing.expect_value(t, len(s.inv_pending), 1)
	// The chest closes by itself (walked away): the overlay goes.
	s.inventory.chest_open = false
	chest_sync(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Inventory))
}

// Q and E step the tabs: Inventory, Creative, then Statistics (its own
// overlay; the inventory closes). E no longer closes the inventory, Escape
// does. Over a slot Q still drops; off the slots it steps back.
@(test)
test_inventory_tabs_by_keys :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	defer stats_view_destroy(&f.app.stats_view)
	app := f.app
	away := ui.Vec2{-100, -100}
	press :: proc(f: ^Overlay_Fixture, key: platform.Key, mouse: ui.Vec2) {
		f.app.input.pressed = {key}
		overlay_frame(f, {mouse = mouse})
		f.app.input.pressed = {}
	}
	inventory_open_ := proc(app: ^App) -> bool {return overlay_is_open(&app.overlays, .Inventory)}
	overlay_frame(&f, {mouse = away}) // (drawn once: the key that opened it is spent)
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Inventory)

	// E does not close it: the inventory key only opens.
	app.input.pressed = {.E}
	inventory_keys(app)
	app.input.pressed = {}
	testing.expect(t, inventory_open_(app))

	press(&f, .E, away)
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Creative)
	press(&f, .E, away)
	testing.expect(t, !inventory_open_(app), "Statistics closes the inventory")
	testing.expect(t, overlay_is_open(&app.overlays, .Stats))
	overlay_frame(&f, {mouse = away}) // (the overlay drawn: its first frame spends the key that opened it)
	press(&f, .Q, away)
	testing.expect(t, !overlay_is_open(&app.overlays, .Stats))
	testing.expect(t, inventory_open_(app))
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Creative)
	overlay_frame(&f, {mouse = away})
	press(&f, .Q, away)
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Inventory)

	// Over a slot, Q drops (and does not step); E steps.
	stone := game.item_of_block(.Stone)
	f.s.inventory.slots[9] = {stone, 64}
	before := len(f.s.inv_pending)
	press(&f, .Q, overlay_slot_at(&f, 9))
	testing.expect_value(t, len(f.s.inv_pending), before + 1)
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Inventory)
	// Off the slots, Q steps (around, to Statistics) and drops nothing.
	before = len(f.s.inv_pending)
	press(&f, .Q, away)
	testing.expect_value(t, len(f.s.inv_pending), before)
	testing.expect(t, overlay_is_open(&app.overlays, .Stats))

	// Escape closes whichever is open.
	escape(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Stats))
	app.input.pressed = {.E}
	inventory_keys(app)
	app.input.pressed = {}
	testing.expect(t, inventory_open_(app))
	escape(app)
	testing.expect(t, !inventory_open_(app))
}
