package gpu

import vk "vendor:vulkan"

// Draw counting. Every draw call goes through draw or draw_indexed, which record it
// and count it: the frame's calls and triangles (Gpu.draws, reset by begin_frame),
// and each timed section's share (the trace's GPU track gives them per pass).

Draw_Counts :: struct {
	calls:     int,
	triangles: int,
}

// draw records vkCmdDraw. lines: the bound pipeline draws a line list (no triangles).
draw :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	vertex_count: u32,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
	lines := false,
) {
	vk.CmdDraw(cmd, vertex_count, instance_count, first_vertex, first_instance)
	g.draws.calls += 1
	if !lines {g.draws.triangles += int(vertex_count / 3 * instance_count)}
}

// draw_indexed records vkCmdDrawIndexed of a triangle list.
draw_indexed :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	index_count: u32,
	instance_count: u32 = 1,
	first_index: u32 = 0,
	vertex_offset: i32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, first_instance)
	g.draws.calls += 1
	g.draws.triangles += int(index_count / 3 * instance_count)
}
