package client

import "core:strings"

import "client:platform"
import "client:ui"

// Toasts: short notices at the
// top right, newest on top, at most TOAST_MAX shown (older ones leave
// early), TOAST_LIFE seconds each: they slide in over TOAST_SLIDE and fade
// over the last TOAST_FADE. With Reduce motion they neither slide nor fade:
// shown, then removed. A toast may carry an action; a click on it runs it
// once and takes it down. They take the pointer only where they are (the
// rest of the screen is the layer below's), and do not pause anything.

TOAST_MAX :: 4
TOAST_LIFE :: 4.0
TOAST_SLIDE :: 0.2
TOAST_FADE :: 0.4

Toast :: struct {
	text:     string, // heap
	age:      f32,
	on_click: proc(app: ^App), // nil: not clickable
}

Toasts :: struct {
	list: [dynamic]Toast, // oldest first
}

toasts_destroy :: proc(t: ^Toasts) {
	for x in t.list {delete(x.text)}
	delete(t.list)
}

// toast shows a notice (a Text key and its arguments); on_click runs when it is clicked.
toast :: proc(app: ^App, key: Text, args: ..any, on_click: proc(app: ^App) = nil) {
	toast_push(&app.toasts, tr(key, ..args), on_click)
}

toast_push :: proc(t: ^Toasts, text: string, on_click: proc(app: ^App) = nil) {
	append(&t.list, Toast{text = strings.clone(text), on_click = on_click})
	for len(t.list) > TOAST_MAX {
		delete(t.list[0].text)
		ordered_remove(&t.list, 0)
	}
}

// toasts_update: a frame passes; the expired go.
toasts_update :: proc(t: ^Toasts, dt: f32) {
	for i := len(t.list) - 1; i >= 0; i -= 1 {
		t.list[i].age += dt
		if t.list[i].age >= TOAST_LIFE {
			delete(t.list[i].text)
			ordered_remove(&t.list, i)
		}
	}
}

// toast_look: how far a toast has slid in (0 off the edge .. 1 in place) and
// how opaque it is.
toast_look :: proc(age: f32, reduce_motion: bool) -> (slide, alpha: f32) {
	if reduce_motion {return 1, 1}
	slide = clamp(age / TOAST_SLIDE, 0, 1)
	alpha = clamp((TOAST_LIFE - age) / TOAST_FADE, 0, 1)
	return
}

// toasts_ui draws them (over everything, tooltips' layer) and runs a clicked one's action.
toasts_ui :: proc(app: ^App, ctx: ^ui.Context) {
	t := &app.toasts
	toasts_update(t, app.last_frame_ms / 1000)
	if len(t.list) == 0 {return}
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	th := &ctx.theme
	h := th.row_height + th.spacing
	clicked := -1
	for i := len(t.list) - 1; i >= 0; i -= 1 {
		x := &t.list[i]
		slide, alpha := toast_look(x.age, app.settings.reduce_motion)
		w := ui.measure_text(ctx, x.text, th.font_size) + 2 * th.padding
		row := len(t.list) - 1 - i // the newest at the top
		r := ui.Rect {
			ctx.screen.x + ctx.screen.w - (w + th.spacing) * slide,
			ctx.screen.y + th.spacing + f32(row) * h,
			w,
			th.row_height,
		}
		faded := th^
		faded.opacity *= alpha
		ui.theme_scope(ctx, faded)
		ui.fill_rect(ctx, r, th.menu_fill)
		ui.stroke_rect(ctx, r, th.border_width, th.border)
		ui.draw_text(ctx, r, x.text, th.font_size, th.text, .Center)
		if x.on_click != nil {
			ui.push_id_int(ctx, i)
			if it := ui.interact(ctx, ui.get_id(ctx, "toast"), r, false, "toast"); it.clicked {
				clicked = i
			}
			ui.pop_id(ctx)
		}
	}
	if clicked >= 0 {
		action := t.list[clicked].on_click
		delete(t.list[clicked].text)
		ordered_remove(&t.list, clicked)
		action(app)
	}
}

// open_screenshots: the folder the screenshots go in, in the file manager.
open_screenshots :: proc(app: ^App) {
	platform.open_folder(path_next_to_exe("screenshots"))
}
