package client

import "core:fmt"

import "../base"
import "ui"

title_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "title")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 400, 4 * t.row_height + 3 * t.spacing + 120)
	ui.title(ctx, "Voxiverse", ui.cut_top(&column, 80))
	ui.cut_top(&column, 40)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.default_focus(ctx)
	if ui.button(ctx, "Singleplayer", ui.next(ctx)) {
		universes_refresh(&app.universes)
		app.screen = .Universes
	}
	if ui.button(ctx, "Multiplayer", ui.next(ctx)) {multiplayer_open(app)}
	if ui.button(ctx, "Options", ui.next(ctx)) {
		app.options.tab = .Video
		app.screen = .Options
	}
	if ui.button(ctx, "Quit Game", ui.next(ctx)) {overlay_open(&app.overlays, .Quit_Dialog)}
	if app.message != "" {
		ui.label(ctx, app.message, ui.next(ctx), .Center, t.text_muted)
	}
	// The version, small and grey in the lower left (Minecraft's place for it).
	small := t.font_size * 0.75
	ui.draw_text(
		ctx,
		{ctx.screen.x + 8, ctx.screen.y + ctx.screen.h - small - 6, ctx.screen.w / 2, small},
		fmt.tprintf("Voxiverse %s", base.version_text()),
		small,
		t.text_muted,
	)
}

