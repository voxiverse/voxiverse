package main

import "core:os"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:overlay"
import "client:screen"
import "client:ui"
import "common:game"
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
// shows the notice until it is opened again.
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
		contains_part(app.ui.texts[:], engine.tr(.Devchat_Notice)),
		"no notice of the reply",
	)
	press(t, app, engine.tr(.Devchat_Title))
	press(t, app, engine.tr(.Devchat_Close))
	testing.expect(
		t,
		!contains_part(app.ui.texts[:], engine.tr(.Devchat_Notice)),
		"the notice stayed after the chat was opened",
	)
	app.devchat.running = false
	free_all(context.temp_allocator)
}
