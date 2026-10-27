package render

import "core:math"
import "core:math/linalg"

// Camera matrices. View space is right-handed: x right, y up, looking down
// -z. Projection maps to Vulkan clip space (y down) with reverse Z and no
// far plane: depth is 1 at the near plane and approaches 0 at infinity,
// which keeps depth precision even across very long view distances.

perspective_reverse_z :: proc(fov_y, aspect, near: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(fov_y / 2)
	return {f / aspect, 0, 0, 0, 0, -f, 0, 0, 0, 0, 0, near, 0, 0, -1, 0}
}

// view_matrix for a camera at position turned yaw radians left from -z and
// pitched up by pitch radians.
view_matrix :: proc(position: [3]f32, yaw, pitch: f32) -> matrix[4, 4]f32 {
	rotation :=
		linalg.matrix4_rotate_f32(-pitch, {1, 0, 0}) * linalg.matrix4_rotate_f32(-yaw, {0, 1, 0})
	return rotation * linalg.matrix4_translate_f32(-position)
}

// forward is the direction the camera looks in.
forward :: proc(yaw, pitch: f32) -> [3]f32 {
	return {-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)}
}
