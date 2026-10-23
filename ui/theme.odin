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
}
