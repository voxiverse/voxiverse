package main

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:menu"
import "client:overlay"
import "client:prompt"
import "client:testkit"
import "client:ui"
import "common:game"
import "common:protocol"

// The inventory overlay with the mouse: dragging a stack to another slot,
// right-click halves, shift-click to the hotbar, a number key, dropping
// outside; each a request predicted at once and sent.
@(test)
test_inventory_overlay :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	s := new(engine.Session)
	defer free(s)
	pipe: protocol.Pipe
	protocol.pipe_init(&pipe)
	defer protocol.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer delete(s.inv_pending)
	defer delete(app.inventory_search)
	s.state = .Playing
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game
	stone, dirt :=
		game.item_of_block(testkit.test_reg(), .Stone),
		game.item_of_block(testkit.test_reg(), .Dirt)
	s.inventory.slots[9] = {stone, 64, 0, 0}
	s.inventory.slots[0] = {dirt, 10, 0, 0}

	app.input.pressed = {.Tab}

	engine.actions_sync(app)
	menu.player_menu_keys(app)
	app.input.pressed = {}
	engine.actions_sync(app)
	testing.expect(t, menu.section_open(app, .Inventory))

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^engine.App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		overlay.draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	at :: proc(app: ^engine.App, slot: int) -> ui.Vec2 {
		ui.begin_frame(&app.ui, {}, SCREEN, 1)
		l := menu.inventory_layout(&app.ui, .Inventory)
		ui.end_frame(&app.ui)
		r := l.slots[slot]
		return {r.x + r.w / 2, r.y + r.h / 2}
	}
	inv := &s.inventory
	// Drag the stone from slot 9 to slot 20.
	frame(app, {mouse = at(app, 9), mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect(t, inv.cursor == {stone, 64, 0, 0})
	frame(app, {mouse = at(app, 20), mouse_down = {.Left}})
	frame(app, {mouse = at(app, 20), mouse_released = {.Left}})
	testing.expect(
		t,
		inv.slots[20] == {stone, 64, 0, 0} &&
		game.stack_empty(inv.slots[9]) &&
		game.stack_empty(inv.cursor),
	)
	// Right-click: half up; a click puts them in slot 21.
	frame(app, {mouse = at(app, 20), mouse_pressed = {.Right}, mouse_down = {.Right}})
	testing.expect(t, inv.cursor == {stone, 32, 0, 0} && inv.slots[20] == {stone, 32, 0, 0})
	frame(app, {mouse = at(app, 21), mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = at(app, 21), mouse_released = {.Left}})
	testing.expect(t, inv.slots[21] == {stone, 32, 0, 0} && game.stack_empty(inv.cursor))
	// Shift-click: into the hotbar (slot 0 holds dirt: the next free one).
	frame(
		app,
		{mouse = at(app, 21), mouse_pressed = {.Left}, mouse_down = {.Left}, modifiers = {.Shift}},
	)
	testing.expect(t, inv.slots[1] == {stone, 32, 0, 0} && game.stack_empty(inv.slots[21]))
	// A number key over a slot swaps it with that hotbar slot.
	app.input.pressed = {.Num_3}
	engine.actions_sync(app)
	frame(app, {mouse = at(app, 20)})
	app.input.pressed = {}
	engine.actions_sync(app)
	testing.expect(t, inv.slots[2] == {stone, 32, 0, 0} && game.stack_empty(inv.slots[20]))
	// Pick up the dirt; a click outside the panel drops it all.
	frame(app, {mouse = at(app, 0), mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = at(app, 0), mouse_released = {.Left}})
	frame(app, {mouse = {5, 5}, mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect(t, game.stack_empty(inv.cursor) && game.inventory_count(inv, dirt) == 0)
	testing.expect_value(t, len(s.inv_pending), 8) // each click, the swap, the drop
	// Closing with a stack on the cursor puts it back.
	frame(app, {mouse = at(app, 1), mouse_pressed = {.Right}, mouse_down = {.Right}})
	overlay.escape(app)
	testing.expect(t, !menu.section_open(app, .Inventory))
	testing.expect(t, game.stack_empty(inv.cursor) && game.inventory_count(inv, stone) == 64)
	// No catalog without the catalog ability: taking is refused before it is sent.
	s.mode = testkit.mode(s.reg, "survival")
	before := len(s.inv_pending)
	testing.expect(t, !engine.session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(dirt)}))
	testing.expect_value(t, len(s.inv_pending), before)
	free_all(context.temp_allocator)
}

// The characters screen: the account's characters to choose from; a click
// on one chooses it (the session joins as it).
@(test)
test_characters_screen :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	defer delete(app.new_character)
	s := new(engine.Session)
	defer free(s)
	pipe: protocol.Pipe
	protocol.pipe_init(&pipe)
	defer protocol.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer {for c in s.characters {delete(c)}; delete(s.characters)}
	defer {for n in s.notices {delete(n)}; delete(s.notices)}
	defer {for e in s.chat {delete(e.text)}; delete(s.chat)}
	defer virtual.arena_destroy(&s.arena)
	append(&s.characters, strings.clone("alice"), strings.clone("bob"))
	s.state = .Choosing
	s.reg = testkit.test_reg()
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
	testing.expect_value(t, s.state, engine.Session_State.Connecting)
	testing.expect_value(t, s.config.name, "bob")
	free_all(context.temp_allocator)
}

// A chest the server opened shows the overlay with the chest beside the
// inventory; a stack shift-clicked goes in (predicted, a request sent); the
// overlay closing sends the Close, and a chest that closes by itself takes
// the overlay down.
@(test)
test_chest_overlay :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	s := new(engine.Session)
	defer free(s)
	pipe: protocol.Pipe
	protocol.pipe_init(&pipe)
	defer protocol.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	defer delete(s.inv_pending)
	defer delete(app.inventory_search)
	s.state = .Playing
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game
	stone := game.item_of_block(testkit.test_reg(), .Stone)
	s.inventory.slots[9] = {stone, 64, 0, 0}

	menu.chest_sync(app)
	testing.expect(t, !menu.section_open(app, .Inventory), "opened with no chest")
	s.inventory.chest_open = true
	menu.chest_sync(app)
	testing.expect(t, menu.section_open(app, .Inventory))
	testing.expect_value(t, app.inventory_view.tab, engine.Inventory_Tab.Chest)

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^engine.App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		overlay.draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	l := menu.inventory_layout(&app.ui, .Chest)
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
		s.inventory.chest[0] == {stone, 64, 0, 0} && game.stack_empty(s.inventory.slots[9]),
		"shift-click did not move it in",
	)
	testing.expect_value(t, len(s.inv_pending), 1)
	// The chest closes by itself (walked away): the overlay goes.
	s.inventory.chest_open = false
	menu.chest_sync(app)
	testing.expect(t, !menu.section_open(app, .Inventory))
}

// ---------------------------------------------------------------------------
// The inventory and the statistics with a pad: pad events alone.
// ---------------------------------------------------------------------------

// pad_rig: a rig playing, with a pad in use, the catalog granted.
@(private = "file")
pad_rig :: proc(t: ^testing.T) -> ^Rig {
	r := rig_make(t)
	app, s := r.app, r.s
	s.reg = testkit.test_reg()
	app.session, app.screen = s, .Game
	s.state = .Playing
	s.mode = testkit.mode(s.reg, "creative")
	pad_connect(app, .Xbox)
	pad_frame(app)
	return r
}

// pad_cursor_to: the cursor on slot by directions alone.
@(private = "file")
pad_cursor_to :: proc(t: ^testing.T, app: ^engine.App, slot: int, loc := #caller_location) {
	v := &app.inventory_view
	for _ in 0 ..< 60 {
		if v.cursor == slot {return}
		l := menu.inventory_layout(&app.ui, v.tab)
		if v.cursor >= engine.CURSOR_CATALOG_BASE {
			pad_go(app, .Down)
			continue
		}
		a, b := l.slots[v.cursor], l.slots[slot]
		dx, dy := (b.x + b.w / 2) - (a.x + a.w / 2), (b.y + b.h / 2) - (a.y + a.h / 2)
		if abs(dx) > abs(dy) {
			pad_go(app, .Right if dx > 0 else .Left)
		} else {
			pad_go(app, .Down if dy > 0 else .Up)
		}
	}
	testing.expectf(
		t,
		v.cursor == slot,
		"the cursor never reached slot %d (on %d)",
		slot,
		v.cursor,
		loc = loc,
	)
}

@(test)
test_inventory_with_a_pad :: proc(t: ^testing.T) {
	r := pad_rig(t)
	defer rig_free(r)
	app, s := r.app, r.s
	inv := &s.inventory
	v := &app.inventory_view
	stone, dirt :=
		game.item_of_block(testkit.test_reg(), .Stone),
		game.item_of_block(testkit.test_reg(), .Dirt)
	inv.slots[9] = {stone, 64, 0, 0}
	inv.slots[0] = {dirt, 10, 0, 0}
	inv.selected = 2

	// Y opens it, the cursor on the hand's slot.
	pad_tap(app, .Y)
	testing.expect(t, menu.section_open(app, .Inventory))
	testing.expect_value(t, v.cursor, 2)

	// A picks the stack up, directions carry it, A puts it down.
	pad_cursor_to(t, app, 9)
	pad_tap(app, .A)
	testing.expect_value(t, inv.cursor, game.Stack{stone, 64, 0, 0})
	testing.expect(t, game.stack_empty(inv.slots[9]))
	pad_cursor_to(t, app, 20)
	pad_tap(app, .A)
	testing.expect_value(t, inv.slots[20], game.Stack{stone, 64, 0, 0})
	testing.expect(t, game.stack_empty(inv.cursor))

	// X takes half; A puts it back.
	pad_tap(app, .X)
	testing.expect_value(t, inv.cursor.count, 32)
	testing.expect_value(t, inv.slots[20].count, 32)
	pad_tap(app, .A)
	testing.expect_value(t, inv.slots[20].count, 64)

	// Y moves it to the hotbar.
	pad_tap(app, .Y)
	testing.expect(t, game.stack_empty(inv.slots[20]))
	in_hotbar := 0
	for i in 0 ..< game.HOTBAR_SLOTS {
		if inv.slots[i].item == stone {in_hotbar += int(inv.slots[i].count)}
	}
	testing.expect_value(t, in_hotbar, 64)

	// The prompts say what the buttons do here (with the bar on).
	app.settings.prompt_bar = true
	pad_frame(app)
	seen := prompt.prompts_seen(app)
	testing.expect(t, len(seen) >= 5, "the inventory's prompt bar is drawn")

	// The left stick's press: the Catalog. Up from the hotbar reaches the catalog; Y types a
	// search; A takes a stack; down to an empty hotbar slot, A puts it there.
	pad_tap(app, .Left_Stick)
	testing.expect_value(t, v.tab, engine.Inventory_Tab.Creative)
	pad_go(app, .Up)
	testing.expect(t, v.cursor >= engine.CURSOR_CATALOG_BASE, "the cursor is on the catalog")
	pad_tap(app, .Y)
	testing.expect(t, ui.osk_is_open(&app.ui), "Y on the catalog opens the keyboard")
	pad_type(t, app, "dirt")
	pad_tap(app, .Start)
	testing.expect(t, !ui.osk_is_open(&app.ui))
	testing.expect_value(t, string(app.inventory_search[:]), "dirt")
	pad_frame(app)
	pad_tap(app, .A)
	testing.expect(t, !game.stack_empty(inv.cursor))
	testing.expect(
		t,
		strings.contains(menu.item_title(testkit.test_reg(), inv.cursor.item), "dirt"),
	)
	taken := inv.cursor
	pad_go(app, .Down)
	testing.expect(
		t,
		v.cursor < engine.CURSOR_CATALOG_BASE,
		"Down from the catalog's last row reaches the hotbar",
	)
	pad_cursor_to(t, app, 4)
	pad_tap(app, .A)
	testing.expect_value(t, inv.slots[4], taken)
	testing.expect(t, game.stack_empty(inv.cursor))

	// B closes with the cursor's stack put back.
	pad_cursor_to(t, app, 0)
	pad_tap(app, .A)
	testing.expect_value(t, inv.cursor, game.Stack{dirt, 10, 0, 0})
	pad_tap(app, .B)
	testing.expect(t, !menu.section_open(app, .Inventory))
	testing.expect(t, game.stack_empty(inv.cursor))
	testing.expect_value(t, inv.slots[0], game.Stack{dirt, 10, 0, 0})

	// A chest the server opened: its slots are reachable.
	inv.chest[0] = {stone, 5, 0, 0}
	inv.chest_open = true
	pad_frame(app)
	testing.expect(t, menu.section_open(app, .Inventory))
	testing.expect_value(t, v.tab, engine.Inventory_Tab.Chest)
	pad_cursor_to(t, app, game.CHEST_BASE)
	pad_tap(app, .A)
	testing.expect_value(t, inv.cursor, game.Stack{stone, 5, 0, 0})
	pad_cursor_to(t, app, game.CHEST_BASE + 6)
	pad_tap(app, .A)
	testing.expect_value(t, inv.chest[6], game.Stack{stone, 5, 0, 0})
	pad_tap(app, .B)
	testing.expect(t, !menu.section_open(app, .Inventory))
	free_all(context.temp_allocator)
}

@(test)
test_stats_with_a_pad :: proc(t: ^testing.T) {
	r := pad_rig(t)
	defer rig_free(r)
	app, s := r.app, r.s
	v := &app.stats_view
	append(
		&s.player_stats.lines,
		strings.clone("blocks.placed.stone 4"),
		strings.clone("blocks.broken.dirt 2"),
	)
	s.player_stats.pages = 2

	// View opens the menu (the inventory first), RB steps to the statistics, then round
	// through the map and the journal; LB steps back; the statistics' list is focused; A
	// opens a group.
	pad_tap(app, .Back)
	testing.expect(t, menu.section_open(app, .Inventory))
	pad_tap(app, .Right_Bumper)
	testing.expect(t, menu.section_open(app, .Statistics))
	pad_tap(app, .Right_Bumper) // (round)
	testing.expect(t, menu.section_open(app, .Map))
	pad_tap(app, .Right_Bumper)
	testing.expect(t, menu.section_open(app, .Journal))
	pad_tap(app, .Right_Bumper)
	testing.expect(t, menu.section_open(app, .Inventory))
	pad_tap(app, .Left_Bumper)
	testing.expect(t, menu.section_open(app, .Journal))
	pad_tap(app, .Left_Bumper)
	pad_tap(app, .Left_Bumper)
	testing.expect(t, menu.section_open(app, .Statistics))
	pad_frame(app)
	testing.expect_value(t, ui.focused_label(&app.ui), "stats rows")
	testing.expect_value(t, len(v.expanded), 0)
	pad_tap(app, .A)
	testing.expect_value(t, len(v.expanded), 1)
	pad_tap(app, .A) // and closes it
	testing.expect_value(t, len(v.expanded), 0)

	// A search, typed on the keyboard.
	pad_focus(t, app, "stats search")
	pad_tap(app, .A)
	testing.expect(t, ui.osk_is_open(&app.ui))
	pad_type(t, app, "dirt")
	pad_tap(app, .Start)
	testing.expect_value(t, string(v.filter[:]), "dirt")

	// Next page.
	pad_focus(t, app, "Next")
	pad_tap(app, .A)
	testing.expect_value(t, v.page, 1)

	// B closes it; View opens it again (at the statistics, shown last) and closes it.
	pad_tap(app, .B)
	testing.expect(t, !menu.section_open(app, .Statistics))
	pad_tap(app, .Back)
	testing.expect(t, menu.section_open(app, .Statistics))
	pad_tap(app, .Back)
	testing.expect(t, !menu.section_open(app, .Statistics))
	free_all(context.temp_allocator)
}

// The layout: two panes, the equipment (the doll round the preview, the character's
// numbers under it) or an open chest's slots with Take all on the left, the bag on the
// right; Creative's catalog over both; the hotbar in one place on every tab; all of it on
// a 1280x720 screen.
@(test)
test_inventory_layout_sections :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	ui.begin_frame(&f.app.ui, {}, SCREEN, 1)
	defer ui.end_frame(&f.app.ui)
	plain := menu.inventory_layout(&f.app.ui, .Inventory)
	chest := menu.inventory_layout(&f.app.ui, .Chest)
	creative := menu.inventory_layout(&f.app.ui, .Creative)
	inside :: proc(outer, r: ui.Rect) -> bool {
		return(
			r.x >= outer.x &&
			r.y >= outer.y &&
			r.x + r.w <= outer.x + outer.w &&
			r.y + r.h <= outer.y + outer.h \
		)
	}
	testing.expect(t, plain.preview.w > 0 && plain.preview.h > 0, "the preview shows")
	testing.expect(t, inside(plain.left, plain.preview) && inside(plain.left, plain.hand))
	testing.expect(t, plain.stats.w > 0 && inside(plain.left, plain.stats))
	for e in game.Equip_Slot {
		testing.expectf(
			t,
			inside(plain.left, plain.slots[game.EQUIP_BASE + int(e)]),
			"%v is on the doll",
			e,
		)
	}
	testing.expect(
		t,
		plain.left.x + plain.left.w <= plain.right.x,
		"the equipment left of the bag",
	)
	for i in game.HOTBAR_SLOTS ..< game.INVENTORY_SLOTS {
		testing.expect(
			t,
			inside(plain.right, plain.slots[i]) && inside(chest.right, chest.slots[i]),
		)
	}
	testing.expect(t, plain.sort.w > 0 && plain.search.w > 0 && inside(plain.right, plain.search))
	testing.expect_value(t, chest.preview.w, 0)
	testing.expect_value(t, chest.slots[game.EQUIP_BASE].w, 0)
	for i in game.CHEST_BASE ..< game.ALL_SLOTS {
		testing.expect(t, inside(chest.left, chest.slots[i]), "the chest's slots in the left pane")
	}
	testing.expect(t, chest.take_all.w > 0 && inside(chest.left, chest.take_all))
	testing.expect(t, creative.catalog.w > 0 && creative.slots[game.HOTBAR_SLOTS].w == 0)
	for i in 0 ..< game.HOTBAR_SLOTS {
		testing.expect(t, plain.slots[i] == chest.slots[i] && plain.slots[i] == creative.slots[i])
	}
	// Everything is on the screen.
	for l in ([]menu.Inventory_Layout{plain, chest, creative}) {
		testing.expect(t, l.panel.x >= 0 && l.panel.y >= 0)
		testing.expect(t, l.panel.x + l.panel.w <= SCREEN.x && l.panel.y + l.panel.h <= SCREEN.y)
		for r in l.slots {if r.w > 0 {testing.expect(t, inside(l.panel, r))}}
	}
}

// Sort is one request the server applies; the search dims what does not
// match; a tooltip lists the name, the description and the modifiers.
@(test)
test_inventory_sort_search_and_tooltip :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	reg := testkit.test_reg()
	stone, dirt := game.item_of_block(reg, .Stone), game.item_of_block(reg, .Dirt)
	f.s.inventory.slots[6] = {dirt, 3, 0, 0}
	f.s.inventory.slots[9] = {stone, 5, 0, 0}
	f.s.inventory.slots[12] = {dirt, 4, 0, 0}
	overlay_frame(&f, {})
	sort := ui.Vec2{}
	if r, ok := ui.find_widget(&f.app.ui, "Sort"); ok {sort = {r.x + r.w / 2, r.y + r.h / 2}}
	testing.expect(t, sort != {}, "a Sort button")
	before := len(f.s.inv_pending)
	overlay_frame(&f, {mouse = sort})
	overlay_frame(&f, {mouse = sort, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = sort, mouse_released = {.Left}})
	testing.expect_value(t, len(f.s.inv_pending), before + 1)
	// (Predicted at once: the dirt merged and the stacks in item order.)
	grid := f.s.inventory.slots[game.HOTBAR_SLOTS:game.INVENTORY_SLOTS]
	lo, hi := min(stone, dirt), max(stone, dirt)
	testing.expect_value(t, grid[0].item, lo)
	counts := map[game.Item]int{}
	defer delete(counts)
	for s in grid {if !game.stack_empty(s) {counts[s.item] += s.count}}
	testing.expect_value(t, counts[dirt], 7)
	testing.expect_value(t, counts[stone], 5)
	testing.expect(t, game.stack_empty(grid[2]) && grid[1].item == hi)

	testing.expect(t, menu.stack_matches(reg, {stone, 1, 0, 0}, "STO"))
	testing.expect(t, !menu.stack_matches(reg, {dirt, 1, 0, 0}, "sto"))
	testing.expect(t, !menu.stack_matches(reg, {}, "a"))

	boots := game.item_of_armor(.Boots)
	lines := menu.item_lines(reg, boots)
	testing.expect_value(t, len(lines), 5)
	testing.expect_value(t, lines[0], "boots")
	testing.expect_value(t, lines[1], "Common boots")
	testing.expect_value(t, lines[2], "Speed +10%")
	testing.expect_value(t, lines[3], "Jump +10%")
	testing.expect_value(t, lines[4], "Worn on the feet.")
	charm := menu.item_lines(reg, game.item_of_material(.Feather_Charm))
	testing.expect_value(t, charm[1], "Uncommon trinket")
	testing.expect_value(t, charm[2], "Air jumps +1")
	none := menu.item_lines(reg, stone) // (a block's item: its name and type, no description)
	testing.expect_value(t, len(none), 2)
	testing.expect_value(t, none[1], "Common block")
}

// A chest's Take all moves everything that fits into the inventory (each stack a quick
// move); a tooltip compares an item with what is worn where it would go.
@(test)
test_chest_take_all_and_compare :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	reg := testkit.test_reg()
	inv := &f.s.inventory
	stone, dirt := game.item_of_block(reg, .Stone), game.item_of_block(reg, .Dirt)
	inv.chest[0], inv.chest[7] = {stone, 5, 0, 0}, {dirt, 2, 0, 0}
	inv.chest_open = true
	overlay_frame(&f, {})
	testing.expect_value(t, f.app.inventory_view.tab, engine.Inventory_Tab.Chest)
	take, found := ui.find_widget(&f.app.ui, "Take all")
	if !testing.expect(t, found, "a Take all button") {return}
	at := ui.Vec2{take.x + take.w / 2, take.y + take.h / 2}
	overlay_frame(&f, {mouse = at})
	overlay_frame(&f, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
	overlay_frame(&f, {mouse = at, mouse_released = {.Left}})
	testing.expect_value(t, game.inventory_count(inv, stone), 5)
	testing.expect_value(t, game.inventory_count(inv, dirt), 2)
	for st in inv.chest {testing.expect(t, game.stack_empty(st), "the chest is empty")}

	// Jump boots against the boots worn: compared, and the difference said.
	inv.chest_open = false
	boots := game.item_of_armor(.Boots)
	jump, _ := game.item_by_name(reg, "jump_boots")
	inv.equipment[.Feet] = {boots, 1, 0, 0}
	inv.slots[6] = {jump, 1, 0, 0}
	with, worn := menu.item_compared(reg, inv, 6)
	testing.expect(t, with == inv.equipment[.Feet] && !worn)
	_, worn = menu.item_compared(reg, inv, game.EQUIP_BASE + int(game.Equip_Slot.Feet))
	testing.expect(t, worn, "the boots worn are the ones worn")
	overlay_frame(&f, {mouse = overlay_slot_at(&f, 6)})
	said :: proc(app: ^engine.App, text: string) -> bool {
		for x in app.ui.texts {if x == text {return true}}
		return false
	}
	testing.expect(t, said(f.app, "jump boots") && said(f.app, "Rare boots"), "its name and type")
	testing.expect(t, said(f.app, "Speed +20%  (+10)"), "better than the boots")
	testing.expect(t, said(f.app, "Jump +0%  (-10)"), "worse at jumping")
	testing.expect(t, said(f.app, "Compared with boots"))
	// On the top layer, its box opaque: nothing under it shows through.
	tip := f.app.ui.output.layers[.Tooltip].vertices
	testing.expect(t, len(tip) >= 4 && tip[0].color.a == 255, "the tooltip is opaque, on top")
}

// A small window (640x360): while the player menu is open the UI is scaled down for its
// panel to fit, so every slot, button and tab is on the screen and reachable; closed, the
// HUD keeps its scale.
@(test)
test_player_menu_fits_a_small_window :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	app := f.app
	app.window.width, app.window.height = 640, 360
	scale := engine.ui_scale(app)
	testing.expect(t, scale < 1, "scaled down for the menu")
	inside :: proc(outer, r: ui.Rect) -> bool {
		return(
			r.x >= outer.x &&
			r.y >= outer.y &&
			r.x + r.w <= outer.x + outer.w &&
			r.y + r.h <= outer.y + outer.h \
		)
	}
	for tab in engine.Inventory_Tab {
		ui.begin_frame(&app.ui, {}, {640, 360}, scale)
		l := menu.inventory_layout(&app.ui, tab)
		screen := app.ui.screen
		ui.end_frame(&app.ui)
		testing.expectf(t, inside(screen, l.panel), "%v: the panel fits", tab)
		for r in l.slots {if r.w > 0 {testing.expectf(t, inside(screen, r), "%v: a slot off the screen", tab)}}
		for r in ([]ui.Rect{l.sort, l.search, l.take_all, l.catalog, l.title}) {
			if r.w > 0 {testing.expectf(t, inside(screen, r), "%v: a control off the screen", tab)}
		}
	}
	// The section tabs and a click on one, at that scale.
	ui.begin_frame(&app.ui, {}, {640, 360}, scale)
	overlay.draw_overlays(app, &app.ui)
	ui.end_frame(&app.ui)
	journal, found := ui.find_widget(&app.ui, "Journal (J)")
	testing.expect(t, found && inside(app.ui.screen, journal), "the Journal tab is on the screen")
	menu.player_menu_close(app)
	testing.expect_value(t, engine.ui_scale(app), 1)
}
