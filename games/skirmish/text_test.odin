package skirmish

import "core:testing"

import "common:base"

// Every key of Skirmish's text has its English.
@(test)
test_every_text_has_its_english :: proc(t: ^testing.T) {
	key, missing := base.text_missing(TEXT_EN)
	testing.expectf(t, !missing, "no text for %v", key)
}
