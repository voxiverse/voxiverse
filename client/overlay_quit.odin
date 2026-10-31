package client


import "client:ui"

quit_dialog :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "quit dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 360, 140)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, tr(.Quit_Quit_Voxiverse), ui.cut_top(&inner, t.row_height), .Center)
	buttons := ui.cut_bottom(&inner, t.row_height)
	no := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, tr(.Quit_Quit), buttons) {app.quit = true}
	ui.default_focus(ctx) // (never quits by mistake)
	if ui.button(ctx, tr(.Dial_Cancel), no) {overlay_close(&app.overlays, .Quit_Dialog)}
}

// fps_overlay: frames per second, big enough to read at a glance, and
