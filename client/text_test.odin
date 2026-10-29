package client

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
