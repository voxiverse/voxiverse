package client


import "ui"

game_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game")
	defer ui.pop_id(ctx)
	s := app.session
	switch s.state {
	case .Connecting:
		loading_screen(app, ctx)
		return
	case .Choosing:
		characters_screen(app, ctx)
		return
	case .Playing, .Failed:
		if s.loading != nil {
			loading_screen(app, ctx)
			return
		}
	}
	name_tags(app, ctx)
	if world_paused(app) {return}
	chat_feed(app, ctx)
	// Crosshair.
	c := ui.rect_center(ctx.screen, 0, 0)
	t := &ctx.theme
	ui.fill_rect(ctx, {c.x - 8, c.y - 1, 16, 2}, t.crosshair)
	ui.fill_rect(ctx, {c.x - 1, c.y - 8, 2, 16}, t.crosshair)
	hotbar(ctx, s, &app.item_icons)
	health_bar(ctx, s)
}

// game_menu: over the game (alone in our own world, the world stands still

