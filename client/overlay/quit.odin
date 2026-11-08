package overlay


import "client:engine"
import "client:ui"

quit_dialog :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "quit dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 360, 140)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, engine.tr(.Quit_Quit_Voxiverse), ui.cut_top(&inner, t.row_height), .Center)
	buttons := ui.cut_bottom(&inner, t.row_height)
	btn_w := (buttons.w - t.spacing) / 2
	ui.begin_row(ctx, buttons, t.spacing)
	defer ui.end_row(ctx)
	if ui.button(ctx, engine.tr(.Quit_Quit), ui.next(ctx, btn_w)) {app.quit = true}
	ui.default_focus(ctx) // (never quits by mistake)
	if ui.button(
		ctx,
		engine.tr(.Dial_Cancel),
		ui.next(ctx, btn_w),
	) {engine.overlay_close(&app.overlays, .Quit_Dialog)}
}

// fps_overlay: frames per second, big enough to read at a glance, and
