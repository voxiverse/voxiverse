package console

import "core:math"
import "core:testing"

// `camera at`'s numbers: where, then the yaw and the pitch in degrees (the pitch held
// short of straight up and down, as `look` holds it); anything else is refused.
@(test)
test_camera_at_parse :: proc(t: ^testing.T) {
	view, ok := camera_at_parse({"56.5", "12", "-30", "90", "-95"})
	testing.expect(t, ok)
	testing.expect_value(t, view.position, [3]f64{56.5, 12, -30})
	testing.expect(t, abs(view.yaw - math.PI / 2) < 1e-5)
	testing.expect(t, abs(view.pitch - math.to_radians(f32(-89))) < 1e-5)
	_, ok = camera_at_parse({"1", "2", "3", "4"})
	testing.expect(t, !ok, "four numbers")
	_, ok = camera_at_parse({"1", "2", "x", "4", "5"})
	testing.expect(t, !ok, "not a number")
}
