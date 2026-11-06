package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "client:engine"
import "client:overlay"
import "client:screen"
import "client:testkit"
import "client:ui"
import "common:game"
import "common:netcode"
import "server:collector"

// One frame of the title screen with the overlays over it.
@(private = "file")
frame :: proc(app: ^engine.App, input: ui.Input = {}) {
	engine.actions_sync(app)
	ui.begin_frame(&app.ui, input, {1280, 720}, 1)
	screen.title_screen(app, &app.ui)
	overlay.draw_overlays(app, &app.ui)
	ui.end_frame(&app.ui)
	app.input.pressed, app.input.pad_pressed = {}, {}
}

@(private = "file")
press :: proc(t: ^testing.T, app: ^engine.App, label: string, loc := #caller_location) -> bool {
	r, found := ui.find_widget(&app.ui, label)
	if !testing.expectf(
		t,
		found && r.w > 0,
		"no %q on the screen",
		label,
		loc = loc,
	) {return false}
	p := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	frame(app, {mouse = p})
	frame(app, {mouse = p, mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = p, mouse_released = {.Left}})
	frame(app, {mouse = {-100, -100}})
	return true
}

@(private = "file")
contains_part :: proc(texts: []string, part: string) -> bool {
	for s in texts {if strings.contains(s, part) {return true}}
	return false
}

// Developer chat: no button while the setting is empty; with it, the title
// screen opens the chat, a message written there is kept (waiting while it
// is not sent), Close closes it, and a reply that arrives while it is closed
// shows a toast once.
@(test)
test_devchat_screen :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	engine.line_editor_init(&app.devchat_line)
	defer engine.line_editor_destroy(&app.devchat_line)
	file := "build/test/devchat_screen.jsonl"
	os.make_directory_all("build/test")
	os.remove(file)
	defer os.remove(file)

	frame(app)
	_, found := ui.find_widget(&app.ui, engine.tr(.Devchat_Title))
	testing.expect(t, !found, "the chat's button shows with the setting empty")

	// On (no thread here: nothing is sent; the conversation is the file's).
	collector.chat_open(&app.devchat.chat, file, {}, game.account_key_make())
	app.devchat.running = true
	defer collector.chat_close(&app.devchat.chat)
	frame(app)
	if !press(t, app, engine.tr(.Devchat_Title)) {return}
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Devchat), "the chat did not open")
	testing.expect(
		t,
		contains_part(app.ui.texts[:], engine.tr(.Devchat_Empty)),
		"the empty chat says nothing",
	)

	append(&app.devchat_line.text, ..transmute([]u8)string("the sky is square"))
	press(t, app, engine.tr(.Devchat_Send))
	entries, _, waiting, _ := collector.chat_view(&app.devchat.chat)
	testing.expect(
		t,
		len(entries) == 1 && entries[0].text == "the sky is square",
		"the message was not kept",
	)
	testing.expect_value(t, waiting, 1)
	testing.expect_value(t, len(app.devchat_line.text), 0)
	testing.expect(
		t,
		contains_part(app.ui.texts[:], "the sky is square"),
		"the message is not shown",
	)
	testing.expect(
		t,
		contains_part(app.ui.texts[:], engine.tr(.Devchat_Not_Sent)),
		"not said to wait",
	)

	press(t, app, engine.tr(.Devchat_Close))
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Devchat), "Close did not close it")

	app.devchat.chat.new_replies = 1 // (a reply came in)
	frame(app)
	testing.expect(
		t,
		len(app.toasts.list) == 1 &&
		strings.contains(app.toasts.list[0].text, engine.tr(.Devchat_Notice, "")[:20]),
		"no toast for the reply",
	)
	for toast in app.toasts.list {delete(toast.text)}
	clear(&app.toasts.list)
	defer delete(app.toasts.list)
	press(t, app, engine.tr(.Devchat_Title))
	press(t, app, engine.tr(.Devchat_Close))

	// F9 (rebindable) opens it and closes it.
	in_: ui.Input
	app.input.pressed = {.F9}
	engine.actions_sync(app)
	handle_global_keys(app, &in_)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Devchat), "F9 did not open the chat")
	app.input.pressed = {.F9}
	engine.actions_sync(app)
	handle_global_keys(app, &in_)
	testing.expect(
		t,
		!engine.overlay_is_open(&app.overlays, .Devchat),
		"F9 did not close the chat",
	)
	app.devchat.running = false
	free_all(context.temp_allocator)
}

// A frame of the game with the overlays over it (a remote session with
// nothing in it: the menus and the chat only).
@(private = "file")
game_frame :: proc(app: ^engine.App, input: ui.Input = {}) {
	engine.actions_sync(app)
	ui.begin_frame(&app.ui, input, {1280, 720}, 1)
	overlay.draw_overlays(app, &app.ui)
	ui.end_frame(&app.ui)
	app.input.pressed, app.input.pad_pressed = {}, {}
}

@(private = "file")
game_press :: proc(t: ^testing.T, app: ^engine.App, label: string, loc := #caller_location) {
	r, found := ui.find_widget(&app.ui, label)
	if !testing.expectf(t, found && r.w > 0, "no %q on the screen", label, loc = loc) {return}
	p := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	game_frame(app, {mouse = p})
	game_frame(app, {mouse = p, mouse_pressed = {.Left}, mouse_down = {.Left}})
	game_frame(app, {mouse = p, mouse_released = {.Left}})
	game_frame(app, {mouse = {-100, -100}})
}

// The chat from the pause menu against an in-process collector: a message
// typed (a new line with Shift+Enter) and sent shows in the conversation and
// reaches the collector's inbox with the context attached; a reply that
// arrives is shown as a toast once the screen is closed.
@(test)
test_devchat_from_the_pause_menu :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	engine.line_editor_init(&app.devchat_line)
	defer engine.line_editor_destroy(&app.devchat_line)
	s := new(engine.Session)
	defer free(s)
	s.state, s.remote = .Playing, true
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game
	app.devchat_attach = true

	lake := "build/test/devchat_ui_lake"
	file := "build/test/devchat_ui.jsonl"
	os.remove_all(lake)
	os.remove(file)
	defer os.remove_all(lake)
	defer os.remove(file)
	admin := game.account_key_make()
	os.make_directory_all(lake)
	_ = os.write_entire_file(
		fmt.tprintf("%s/admins.cfg", lake),
		transmute([]u8)game.account_text(admin.account),
	)
	PORT :: 40_001
	sim: netcode.Simnet
	netcode.simnet_init(&sim)
	defer netcode.simnet_destroy(&sim)
	col: collector.Collector
	if !testing.expect(t, collector.collector_open(&col, lake, PORT, &sim)) {return}
	defer collector.collector_close(&col)
	Rig :: struct {
		sim: ^netcode.Simnet,
		col: ^collector.Collector,
	}
	rig := Rig{&sim, &col}
	chat := &app.devchat.chat
	collector.chat_open(chat, file, {net.IP4_Address{127, 0, 0, 1}, PORT}, admin, &sim)
	defer collector.chat_close(chat)
	chat.idle_data = &rig
	chat.idle = proc(data: rawptr) {
		r := (^Rig)(data)
		r.sim.now = time.tick_add(r.sim.now, 5 * time.Millisecond)
		collector.collector_step(r.col, r.sim.now)
	}
	app.devchat.running = true
	defer app.devchat.running = false

	engine.overlay_open(&app.overlays, .Game_Menu)
	game_frame(app)
	game_press(t, app, engine.tr(.Devchat_Title))
	if !testing.expect(t, engine.overlay_is_open(&app.overlays, .Devchat)) {return}

	// Typed: "up", Shift+Enter, "down"; then Enter sends.
	game_frame(app, {text = {'u', 'p'}})
	app.ui.input.modifiers = {}
	game_frame(app, {keys_pressed = {.Enter}, modifiers = {.Shift}})
	game_frame(app, {text = {'d', 'o', 'w', 'n'}})
	testing.expect_value(t, string(app.devchat_line.text[:]), "up\ndown")
	game_frame(app, {keys_pressed = {.Enter}})
	collector.chat_pass(chat)
	game_frame(app)
	entries, status, waiting, _ := collector.chat_view(chat)
	testing.expect_value(t, status, collector.Chat_Status.Connected)
	testing.expect_value(t, waiting, 0)
	testing.expect(t, len(entries) == 1 && entries[0].text == "up\ndown", "message not kept")
	testing.expect(t, len(entries) == 1 && entries[0].has_pos, "the position was not attached")
	testing.expect(
		t,
		contains_part(app.ui.texts[:], "down"),
		"the message is not in the conversation",
	)
	inbox := fmt.tprintf("%s/devchat/%s/in", lake, game.account_text(admin.account))
	files, _ := os.read_all_directory_by_path(inbox, context.temp_allocator)
	testing.expect_value(t, len(files), 1)

	game_press(t, app, engine.tr(.Devchat_Close))
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Devchat), "Close did not close it")

	// A reply arrives while it is closed: a toast.
	out := fmt.tprintf("%s/devchat/%s/out", lake, game.account_text(admin.account))
	os.make_directory_all(out)
	_ = os.write_entire_file(
		fmt.tprintf("%s/0001.json", out),
		transmute([]u8)string(`{"id":"0001","time":1000,"text":"seen, thanks"}`),
	)
	collector.chat_pass(chat)
	game_frame(app)
	testing.expect(
		t,
		len(app.toasts.list) == 1 &&
		strings.contains(app.toasts.list[0].text, "Reply from the developers"),
		"no toast for the reply",
	)
	game_frame(app)
	testing.expect_value(t, len(app.toasts.list), 1) // once
	for toast in app.toasts.list {delete(toast.text)}
	delete(app.toasts.list)
	free_all(context.temp_allocator)
}
