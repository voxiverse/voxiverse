package gpu

import "core:log"
import vk "vendor:vulkan"

import "../base"

// GPU timing. Every frame is one section, and so is every begin_label /
// end_label pair inside it: a timestamp is written at each boundary, read back
// once that frame slot's fence has signalled (FRAMES_IN_FLIGHT frames later),
// added to gpu_frame_stats and, in profiling builds, put on the trace's GPU
// track. With VK_KHR_calibrated_timestamps the GPU events sit on the same
// clock as CPU events; without it, each frame is anchored at the moment its
// results were read (good for durations, approximate for alignment).

MAX_GPU_SECTIONS :: 64
@(private)
GPU_SECTION_NAME_MAX :: 47
@(private)
NO_QUERY :: max(u32)

@(private)
Gpu_Section :: struct {
	name:        [GPU_SECTION_NAME_MAX]u8,
	name_len:    u8,
	begin_query: u32,
	end_query:   u32,
}

@(private)
Frame_Timing :: struct {
	pool:          vk.QueryPool,
	sections:      [MAX_GPU_SECTIONS]Gpu_Section,
	section_count: int,
	query_count:   u32,
	open:          [MAX_GPU_SECTIONS]int, // stack of unfinished sections
	open_count:    int,
}

// gpu_frame_summary reports GPU frame times so far (ms).
gpu_frame_summary :: proc(g: ^Gpu) -> base.Frame_Summary {
	return base.frame_stats_summary(&g.gpu_frame_stats)
}

@(private)
timing_log_summary :: proc(g: ^Gpu) {
	s := gpu_frame_summary(g)
	if s.count == 0 {return}
	log.infof(
		"gpu frame times frames=%d avg_ms=%.3f p50=%.3f p99=%.3f max=%.3f",
		s.count,
		s.avg,
		s.p50,
		s.p99,
		s.max,
	)
}

@(private)
timing_init :: proc(g: ^Gpu, t: ^Frame_Timing, index: int) -> bool {
	if !g.timing {return true}
	info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = MAX_GPU_SECTIONS * 2,
	}
	check(vk.CreateQueryPool(g.device, &info, nil, &t.pool)) or_return
	set_name(g, .QUERY_POOL, u64(t.pool), "frame timestamps")
	return true
}

@(private)
timing_destroy :: proc(g: ^Gpu, t: ^Frame_Timing) {
	if t.pool != 0 {vk.DestroyQueryPool(g.device, t.pool, nil)}
}

// timing_frame_begin reads the slot's previous results (its fence has
// signalled), then resets the pool and opens the "frame" section.
@(private)
timing_frame_begin :: proc(g: ^Gpu, t: ^Frame_Timing, cmd: vk.CommandBuffer) {
	if !g.timing {return}
	timing_collect(g, t)
	vk.CmdResetQueryPool(cmd, t.pool, 0, MAX_GPU_SECTIONS * 2)
	t.section_count, t.query_count, t.open_count = 0, 0, 0
	timing_section_begin(g, t, cmd, "frame")
}

@(private)
timing_frame_end :: proc(g: ^Gpu, t: ^Frame_Timing, cmd: vk.CommandBuffer) {
	if !g.timing {return}
	assert(t.open_count == 1, "gpu: begin_label without a matching end_label in this frame")
	timing_section_end(g, t, cmd)
}

@(private)
timing_section_begin :: proc(g: ^Gpu, t: ^Frame_Timing, cmd: vk.CommandBuffer, name: string) {
	if !g.timing || t.section_count == MAX_GPU_SECTIONS {return}
	s := &t.sections[t.section_count]
	s.name_len = u8(copy(s.name[:], name))
	s.begin_query = t.query_count
	s.end_query = NO_QUERY
	vk.CmdWriteTimestamp2(cmd, {.ALL_COMMANDS}, t.pool, t.query_count)
	t.query_count += 1
	t.open[t.open_count] = t.section_count
	t.open_count += 1
	t.section_count += 1
}

@(private)
timing_section_end :: proc(g: ^Gpu, t: ^Frame_Timing, cmd: vk.CommandBuffer) {
	if !g.timing || t.open_count == 0 {return}
	t.open_count -= 1
	s := &t.sections[t.open[t.open_count]]
	s.end_query = t.query_count
	vk.CmdWriteTimestamp2(cmd, {.ALL_COMMANDS}, t.pool, t.query_count)
	t.query_count += 1
}

@(private)
timing_collect :: proc(g: ^Gpu, t: ^Frame_Timing) {
	if t.section_count == 0 {return}
	results: [MAX_GPU_SECTIONS * 2]u64
	result := vk.GetQueryPoolResults(
		g.device,
		t.pool,
		0,
		t.query_count,
		int(t.query_count) * size_of(u64),
		&results[0],
		size_of(u64),
		{._64},
	)
	if result != .SUCCESS {
		log.warnf("gpu timestamp results unavailable: %v", result)
		return
	}

	// Anchor: a (GPU ticks, trace ns) pair.
	anchor_ticks, anchor_ns: u64 = results[t.sections[0].end_query], u64(base.trace_clock_ns())
	if g.calibrated {
		infos := [2]vk.CalibratedTimestampInfoKHR {
			{sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = .DEVICE},
			{sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = g.host_time_domain},
		}
		pair: [2]u64
		deviation: u64
		if vk.GetCalibratedTimestampsKHR(g.device, 2, &infos[0], &pair[0], &deviation) ==
		   .SUCCESS {
			anchor_ticks, anchor_ns = pair[0], u64(base.host_clock_to_ns(pair[1]))
		}
	}
	to_ns :: proc(g: ^Gpu, ticks, anchor_ticks, anchor_ns: u64) -> i64 {
		// Timestamps only have timestampValidBits bits; take the signed
		// difference within that width.
		delta := (ticks - anchor_ticks) & g.timestamp_mask
		signed :=
			i64(delta) if delta <= g.timestamp_mask >> 1 else -i64((~delta + 1) & g.timestamp_mask)
		return i64(anchor_ns) + i64(f64(signed) * f64(g.timestamp_period))
	}

	frame := t.sections[0]
	if frame.end_query != NO_QUERY {
		ticks := (results[frame.end_query] - results[frame.begin_query]) & g.timestamp_mask
		base.frame_stats_add(&g.gpu_frame_stats, f32(f64(ticks) * f64(g.timestamp_period) / 1e6))
	}

	// A benchmark's metrics: each pass's time this frame (the render
	// package's labels, by name).
	if base.metrics_recording() {
		ms: [base.Metric]f32
		seen: bit_set[base.Metric]
		for &s in t.sections[:t.section_count] {
			if s.end_query == NO_QUERY {continue}
			for entry in GPU_SECTION_METRICS {
				if entry.name != string(s.name[:s.name_len]) {continue}
				ticks := (results[s.end_query] - results[s.begin_query]) & g.timestamp_mask
				ms[entry.metric] += f32(f64(ticks) * f64(g.timestamp_period) / 1e6)
				seen += {entry.metric}
			}
		}
		// The frame's time without the offscreen copy: the same work at any window size.
		ms[.Gpu_Frame] -= ms[.Gpu_Present_Copy]
		for m in seen {base.metric_add(m, ms[m])}
	}

	if !base.profiling_enabled() {return}
	// Emit begins and ends in query order, which is recording order, so
	// nested sections come out nested.
	event_section: [MAX_GPU_SECTIONS * 2]int
	for &e in event_section[:t.query_count] {e = -1}
	for s, i in t.sections[:t.section_count] {
		event_section[s.begin_query] = i
		if s.end_query != NO_QUERY {event_section[s.end_query] = i}
	}
	for q in 0 ..< t.query_count {
		i := event_section[q]
		if i < 0 {continue}
		s := &t.sections[i]
		ns := to_ns(g, results[q], anchor_ticks, anchor_ns)
		if q == s.begin_query {
			base.profile_gpu_begin(string(s.name[:s.name_len]), ns)
		} else {
			base.profile_gpu_end(ns)
		}
	}
}

// GPU_SECTION_METRICS: the sections (begin_label names) that are metrics.
@(private, rodata)
GPU_SECTION_METRICS := [?]struct {
	name:   string,
	metric: base.Metric,
} {
	{"frame", .Gpu_Frame},
	{"world", .Gpu_World},
	{"water", .Gpu_Water},
	{"sky", .Gpu_Sky},
	{"entities", .Gpu_Entities},
	{"ui", .Gpu_UI},
	{"present copy", .Gpu_Present_Copy},
}

// timing_setup decides at device creation whether timestamps work on this
// queue and whether they can be calibrated to the trace clock.
@(private)
timing_setup :: proc(g: ^Gpu, valid_bits: u32, period: f32, calibration_available: bool) {
	g.timing = valid_bits > 0 && period > 0
	if !g.timing {
		log.info("gpu timestamps not supported on this queue; no GPU timing")
		return
	}
	g.timestamp_period = period
	g.timestamp_mask = max(u64) if valid_bits >= 64 else (u64(1) << valid_bits) - 1
	if !calibration_available {
		log.info("gpu GPU timing on (approximate alignment in traces)")
		base.profile_name_gpu_track(false)
		return
	}

	host_domain: vk.TimeDomainKHR =
		.QUERY_PERFORMANCE_COUNTER when ODIN_OS == .Windows else .CLOCK_MONOTONIC_RAW
	count: u32
	vk.GetPhysicalDeviceCalibrateableTimeDomainsKHR(g.physical, &count, nil)
	domains := make([]vk.TimeDomainKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceCalibrateableTimeDomainsKHR(g.physical, &count, raw_data(domains))
	has_device, has_host := false, false
	for d in domains {
		has_device ||= d == .DEVICE
		has_host ||= d == host_domain
	}
	g.calibrated = has_device && has_host
	g.host_time_domain = host_domain
	base.profile_name_gpu_track(g.calibrated)
	log.infof("gpu timing on calibrated=%v", g.calibrated)
}
