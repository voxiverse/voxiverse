#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// The sky (render/sky_pass.odin): one triangle covering the screen, drawn
// after the world at the far plane, so it fills only what the world left.
// Each corner's view ray is worked out here; points on the near plane are
// linear in screen position, so interpolating them is exact.

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) out vec3 out_ray;

void main() {
	Scene s = push.scene;
	vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
	vec4 near = s.inv_view_proj * vec4(p, 1.0, 1.0);
	out_ray = near.xyz / near.w - s.camera.xyz;
	gl_Position = vec4(p, 0.0, 1.0); // depth 0: far (reverse Z)
}
