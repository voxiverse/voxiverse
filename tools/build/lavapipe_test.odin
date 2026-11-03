package build

import "core:testing"

// The software-driver pins are complete: SHA-256 in hex and URLs of the same versions.
@(test)
test_lavapipe_pin :: proc(t: ^testing.T) {
	testing.expect(t, lavapipe_pin_valid(), "a lavapipe or Vulkan runtime pin is malformed")
}
