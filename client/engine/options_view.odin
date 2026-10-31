package engine

Options_Tab :: enum u8 {
	Video,
	Audio,
	Controls,
	Accessibility,
	Profile,
}

Options_View :: struct {
	tab:           Options_Tab,
	scroll:        f32, // pixels
	listening:     Action, // the binding waiting for its button (None: none)
	listening_pad: bool, // ... on the pad, not the keyboard
}
