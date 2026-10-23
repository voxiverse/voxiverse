#version 460

// Placeholder pipeline for the M1 window + GPU bring-up: a hard-coded
// triangle, no vertex buffers.

layout(location = 0) out vec3 out_color;

const vec2 POSITIONS[3] = vec2[](vec2(0.0, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));
const vec3 COLORS[3] = vec3[](vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));

void main() {
	gl_Position = vec4(POSITIONS[gl_VertexIndex], 0.0, 1.0);
	out_color = COLORS[gl_VertexIndex];
}
