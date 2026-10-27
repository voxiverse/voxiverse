package ui

// Theme: colours (sRGB) and metrics (UI units). The default is the black and
// white OLED look: black surfaces, white text and outlines, hover inverts.

Theme :: struct {
	background:     Color, // panels
	text:           Color,
	text_muted:     Color,
	border:         Color,
	hover:          Color, // fill of hovered/pressed widgets
	hover_text:     Color,
	pressed:        Color,
	focus_ring:     Color,
	disabled_alpha: u8,
	backdrop:       Color, // behind modals
	selection:      Color, // text selection
	font_size:      f32,
	title_size:     f32,
	row_height:     f32,
	padding:        f32,
	spacing:        f32,
	border_width:   f32,
	opacity:        f32, // 0..1: multiplies the alpha of everything drawn
	// Fills and inks the screens draw (defaults are the old literals).
	slot_fill:      Color, // slots, dial cells, tooltips
	faint_border:   Color,
	list_fill:      Color,
	list_border:    Color,
	row_hover:      Color,
	row_selected:   Color,
	text_shadow:    Color,
	preview_fill:   Color,
	warning:        Color, // a key bound twice
	crosshair:      Color,
	hud_fill:       Color,
	menu_fill:      Color,
	console_fill:   Color,
	log_warn:       Color,
	log_error:      Color,
	health_full:    Color,
	health_empty:   Color,
	meter_back:     Color,
	meter_fill:     Color,
	graph_back:     Color,
	graph_line:     Color,
}

DEFAULT_THEME :: Theme {
	background     = {0, 0, 0, 255},
	text           = {255, 255, 255, 255},
	text_muted     = {140, 140, 140, 255},
	border         = {255, 255, 255, 255},
	hover          = {255, 255, 255, 255},
	hover_text     = {0, 0, 0, 255},
	pressed        = {200, 200, 200, 255},
	focus_ring     = {255, 255, 255, 255},
	disabled_alpha = 90,
	backdrop       = {0, 0, 0, 190},
	selection      = {90, 90, 90, 255},
	font_size      = 16,
	title_size     = 40,
	row_height     = 36,
	padding        = 10,
	spacing        = 10,
	border_width   = 1,
	opacity        = 1,
	slot_fill      = {0, 0, 0, 230},
	faint_border   = {255, 255, 255, 60},
	list_fill      = {0, 0, 0, 140},
	list_border    = {255, 255, 255, 50},
	row_hover      = {255, 255, 255, 40},
	row_selected   = {255, 255, 255, 18},
	text_shadow    = {0, 0, 0, 255},
	preview_fill   = {10, 12, 18, 255},
	warning        = {220, 90, 70, 255},
	crosshair      = {255, 255, 255, 200},
	hud_fill       = {0, 0, 0, 235},
	menu_fill      = {0, 0, 0, 170},
	console_fill   = {0, 0, 0, 255},
	log_warn       = {255, 200, 80, 255},
	log_error      = {255, 100, 100, 255},
	health_full    = {226, 56, 66, 255},
	health_empty   = {70, 24, 28, 255},
	meter_back     = {40, 40, 40, 255},
	meter_fill     = {90, 170, 220, 255},
	graph_back     = {20, 20, 20, 255},
	graph_line     = {230, 160, 60, 255},
}

// Theme_Saved is what theme_scope hands back to its deferred end.
Theme_Saved :: struct {
	ctx:   ^Context,
	theme: Theme,
}

// theme_scope makes t the current theme until the scope ends (deferred
// theme_unscope restores the saved one exactly). Nested scopes compose: a
// caller changes a copy of ctx.theme (`t.opacity *= 0.6`).
@(deferred_out = theme_unscope)
theme_scope :: proc(ctx: ^Context, t: Theme) -> Theme_Saved {
	saved := Theme_Saved{ctx, ctx.theme}
	if ctx.theme_depth >= len(ctx.theme_stack) {
		ctx.errors += 1
		ctx.theme_over += 1 // its end is ignored too
		return saved
	}
	ctx.theme_stack[ctx.theme_depth] = saved.theme
	ctx.theme_depth += 1
	ctx.theme = t
	return saved
}

theme_unscope :: proc(saved: Theme_Saved) {
	ctx := saved.ctx
	if ctx.theme_over > 0 {
		ctx.theme_over -= 1
		return
	}
	if ctx.theme_depth == 0 {return}
	ctx.theme_depth -= 1
	ctx.theme = saved.theme
}
