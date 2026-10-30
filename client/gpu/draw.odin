package gpu

import vk "vendor:vulkan"

// Draw counting. Every draw call goes through draw, draw_indexed or
// draw_indexed_indirect, which record it and count it: the frame's draws and
// triangles (Gpu.draws, reset by begin_frame), and each timed section's share
// (the trace's GPU track gives them per pass). An indirect call counts as its
// commands in calls, and once in api_calls.

Draw_Counts :: struct {
	calls:     int, // draws: an indirect call's commands each
	api_calls: int, // vkCmdDraw* calls
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
	g.draws.api_calls += 1
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
	g.draws.api_calls += 1
	g.draws.triangles += int(index_count / 3 * instance_count)
}

// draw_indexed_indirect records vkCmdDrawIndexedIndirect of count commands
// (tightly packed vk.DrawIndexedIndirectCommand) at offset in buffer, in as
// few calls as the device's maxDrawIndirectCount allows. triangles: what
// the commands draw; calls: how many of them draw anything (-1: all). Where
// the GPU wrote the commands, the caller counts them as it can (the GPU's
// own count, a few frames late).
draw_indexed_indirect :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	buffer: vk.Buffer,
	offset: int,
	count: u32,
	triangles: int,
	calls := -1,
) {
	STRIDE :: size_of(vk.DrawIndexedIndirectCommand)
	limit := max(g.max_draw_indirect_count, 1)
	for done := u32(0); done < count; {
		n := min(count - done, limit)
		vk.CmdDrawIndexedIndirect(
			cmd,
			buffer,
			vk.DeviceSize(offset + int(done) * STRIDE),
			n,
			STRIDE,
		)
		g.draws.api_calls += 1
		done += n
	}
	g.draws.calls += int(count) if calls < 0 else calls
	g.draws.triangles += triangles
}
