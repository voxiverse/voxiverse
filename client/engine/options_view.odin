package engine

Options_Tab :: enum u8 {
	Video,
	Audio,
	Controls,
	Accessibility,
	Profile,
}

Options_View :: struct {
	tab:            Options_Tab,
	scroll:         f32, // pixels
	listening:      Action, // the binding waiting for its button (None: none)
	listening_pad:  bool, // ... on the pad, not the keyboard
	listening_game: int, // while listening is Game_1: the game's binding waiting (game_bind_key: its actions, then its keys)
}
