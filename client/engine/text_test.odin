package engine

import "core:testing"

@(test)
test_text_keys_have_strings :: proc(t: ^testing.T) {
	for key in Text {
		testing.expectf(t, TEXT_EN[key] != "", "%v has no string", key)
	}
}

@(test)
test_tr_positional :: proc(t: ^testing.T) {
	testing.expect_value(t, tr(.Title_Version, "1.2"), "Voxiverse 1.2")
	testing.expect_value(t, tr(.Title_Singleplayer), "Singleplayer")
	// A placeholder with no argument stays as written.
	testing.expect_value(t, tr(.Title_Version), "Voxiverse {0}")
}

@(test)
test_life_line :: proc(t: ^testing.T) {
	testing.expect_value(t, life_line({.None, 0, 0}), "No life")
	testing.expect_value(
		t,
		life_line({.Animals, 3, 4020}),
		"Plants and animals; three peoples, about 4 000 years of history",
	)
	testing.expect_value(
		t,
		life_line({.Animals, 1, 650}),
		"Plants and animals; one people, about 700 years of history",
	)
	free_all(context.temp_allocator)
}
