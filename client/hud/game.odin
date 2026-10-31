package hud


import "client:engine"
import "client:overlay"
import "client:screen"
import "client:ui"

game_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game")
	defer ui.pop_id(ctx)
	s := app.session
	switch s.state {
	case .Connecting:
		screen.loading_screen(app, ctx)
		return
	case .Choosing:
		engine.characters_screen(app, ctx)
		return
	case .Playing, .Failed:
		if s.loading != nil {
			screen.loading_screen(app, ctx)
			return
		}
	}
	engine.name_tags(app, ctx)
	if engine.world_paused(app) {return}
	overlay.chat_feed(app, ctx)
	hud_draw(app, ctx)
	player_list_draw(app, ctx)
}

// hud_draw: the crosshair, the hotbar, the hearts and the item-name popup
// (all of what F1 hides: hud_keys).
hud_draw :: proc(app: ^engine.App, ctx: ^ui.Context) {
	if app.hud_hidden {return}
	s := app.session
	c := ui.rect_center(ctx.screen, 0, 0)
	t := &ctx.theme
	if engine.crosshair_shown(s) {
		ui.fill_rect(ctx, {c.x - 8, c.y - 1, 16, 2}, t.crosshair)
		ui.fill_rect(ctx, {c.x - 1, c.y - 8, 2, 16}, t.crosshair)
	}
	hotbar(ctx, s, &app.item_icons)
	engine.weapon_hud(ctx, s)
	health_bar(ctx, s)
	hud_popup(app, ctx)
}

// game_menu: over the game (alone in our own world, the world stands still


// hud_keys: F1 hides the HUD and shows it again (not saved).
hud_keys :: proc(app: ^engine.App) {
	if engine.action_pressed(&app.actions, .Toggle_HUD) {app.hud_hidden = !app.hud_hidden}
}
