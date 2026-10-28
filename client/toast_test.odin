package client

import "core:testing"

import "ui"

clicks: int // (the toast action's count)

count_click :: proc(app: ^App) {clicks += 1}

@(test)
test_toast_stack_and_cap :: proc(t: ^testing.T) {
	ts: Toasts
	defer toasts_destroy(&ts)
	for _ in 0 ..< 6 {toast_push(&ts, "n")}
	toast_push(&ts, "newest")
	testing.expect_value(t, len(ts.list), TOAST_MAX)
	testing.expect_value(t, ts.list[len(ts.list) - 1].text, "newest")
	// Lifetimes: each leaves TOAST_LIFE after it came.
	toasts_update(&ts, TOAST_LIFE - 0.5)
	toast_push(&ts, "late")
	toasts_update(&ts, 0.6)
	testing.expect_value(t, len(ts.list), 1)
	testing.expect_value(t, ts.list[0].text, "late")
	toasts_update(&ts, TOAST_LIFE)
	testing.expect_value(t, len(ts.list), 0)
}

@(test)
test_toast_look :: proc(t: ^testing.T) {
	slide, alpha := toast_look(0, false)
	testing.expect_value(t, slide, 0)
	testing.expect_value(t, alpha, 1)
	slide, alpha = toast_look(TOAST_SLIDE, false)
	testing.expect_value(t, slide, 1)
	slide, alpha = toast_look(TOAST_LIFE - TOAST_FADE / 2, false)
	testing.expect(t, alpha > 0.4 && alpha < 0.6, "fading out")
	// Reduce motion: in place and opaque the whole time.
	slide, alpha = toast_look(0, true)
	testing.expect(t, slide == 1 && alpha == 1)
	slide, alpha = toast_look(TOAST_LIFE - 0.1, true)
	testing.expect(t, slide == 1 && alpha == 1)
}

// A click runs the action once and takes the toast down; a toast without
// one is not clickable; the rest of the screen is not taken.
@(test)
test_toast_click :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer toasts_destroy(&f.app.toasts)
	app := f.app
	clicks = 0
	app.settings.reduce_motion = true // (in place from the first frame)
	toast(app, .Screenshot_Saved, on_click = count_click)
	frame := proc(f: ^Overlay_Fixture, in_: ui.Input) {
		ui.begin_frame(&f.app.ui, in_, SCREEN, 1)
		toasts_ui(f.app, &f.app.ui)
		ui.end_frame(&f.app.ui)
	}
	frame(&f, {})
	r, found := ui.find_widget(&app.ui, "toast")
	if !testing.expect(t, found, "the toast is a widget") {return}
	at := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	frame(&f, {mouse = at})
	frame(&f, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(&f, {mouse = at, mouse_released = {.Left}})
	testing.expect_value(t, clicks, 1)
	testing.expect_value(t, len(app.toasts.list), 0)
	frame(&f, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(&f, {mouse = at, mouse_released = {.Left}})
	testing.expect_value(t, clicks, 1) // (once)

	// Without an action: nothing to click, and it does not pause.
	toast(app, .Screenshot_Saved)
	frame(&f, {})
	_, found = ui.find_widget(&app.ui, "toast")
	testing.expect(t, !found)
	testing.expect(t, !world_paused(app))
	// What it says.
	testing.expect_value(t, app.toasts.list[0].text, "Screenshot saved")
}
