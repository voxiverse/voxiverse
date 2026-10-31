package overlay

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:game"
import "server:core"

// The Open to LAN dialog: the guests' game mode, whether
// guests may use commands, and Open; once the world is open it shows where to
// join. The choices are two rules of the world (`default_game_mode`,
// `guest_role`), changed through the commands, so they are journalled like any
// `/rule`; opening is the `open_lan` command. The transport is not touched.

// GUESTS_ROLE: what Allow commands gives (the role of permissions.cfg that
// has the commands nodes; off gives only the default role everyone has).
GUESTS_ROLE :: "mod"

// lan_commands: what Open sends, in order.
lan_commands :: proc(s: ^engine.Session, d: engine.Lan_Dialog) -> [3]string {
	role := GUESTS_ROLE if d.commands else "default"
	return {
		fmt.tprintf("rule default_game_mode %s", s.reg.game_modes[d.mode].id),
		fmt.tprintf("rule guest_role %s", role),
		"open_lan",
	}
}

lan_dialog_ui :: proc(app: ^engine.App, ctx: ^ui.Context) {
	s := app.session
	if s == nil || len(s.reg.game_modes) == 0 {return}
	d := &app.lan
	ui.push_id(ctx, "lan dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	port := core.stats(&s.server).port
	rows: f32 = 4 if port == 0 else 5
	box := ui.rect_center(ctx.screen, 440, rows * t.row_height + (rows + 1) * t.spacing + 80)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, t.padding)
	ui.title(ctx, engine.tr(.Lan_Title), ui.cut_top(&inner, 60))
	ui.layout_begin(ctx, inner)
	defer ui.layout_end(ctx)
	if port == 0 {
		names := make([]string, len(s.reg.game_modes), context.temp_allocator)
		for _, i in s.reg.game_modes {names[i] = game.mode_label(s.reg, i)}
		ui.default_focus(ctx)
		ui.choice(ctx, engine.tr(.Lan_Guest_Mode), &d.mode, names, ui.next(ctx))
		ui.checkbox(ctx, engine.tr(.Lan_Allow_Commands), &d.commands, ui.next(ctx))
		if ui.button(ctx, engine.tr(.Lan_Open), ui.next(ctx), disabled = d.started) {
			d.started = true
			for command in lan_commands(s, d^) {engine.send_message(s, game.Command{command})}
		}
		if d.started {ui.label(ctx, engine.tr(.Lan_Opening), ui.next(ctx), .Center, t.text_muted)}
		if ui.button(
			ctx,
			engine.tr(.Dial_Cancel),
			ui.next(ctx),
		) {engine.overlay_close(&app.overlays, .Open_To_LAN)}
	} else {
		ui.label(ctx, engine.tr(.Lan_Open_On), ui.next(ctx), .Center)
		ui.label(ctx, lan_join_text(d^, port), ui.next(ctx), .Center)
		ui.label(
			ctx,
			engine.tr(.Lan_Mode_Is, game.mode_label(s.reg, d.mode)),
			ui.next(ctx),
			.Center,
			t.text_muted,
		)
		ui.default_focus(ctx)
		if ui.button(
			ctx,
			engine.tr(.Lan_Done),
			ui.next(ctx),
		) {engine.overlay_close(&app.overlays, .Open_To_LAN)}
		if ui.button(ctx, engine.tr(.Game_Menu_Close_LAN), ui.next(ctx)) {
			engine.close_lan(app)
			engine.overlay_close(&app.overlays, .Open_To_LAN)
		}
	}
}

// lan_join_text: "address:port" (or the port alone when no address was found).
lan_join_text :: proc(d: engine.Lan_Dialog, port: int) -> string {
	if d.address_n == 0 {return engine.tr(.Lan_Port, port)}
	dd := d
	return fmt.tprintf("%s:%d", string(dd.address[:dd.address_n]), port)
}
