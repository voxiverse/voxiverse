package render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

import "client:gpu"
import "common:base"

// `--check hiz`: the depth pyramid and
// the occlusion test on the GPU against their CPU twins, on lavapipe in CI,
// outside the frames.
//
// (a) The pyramid: depth images of several sizes (uneven footprints among
//     them), filled from a fixed hash and from a CPU raster of boxes, built
//     by hiz.comp, read back and compared with hiz_reference: every texel of
//     every level bit-exact (a minimum of floats is exact).
// (b) The test: HIZ_CHECK_BOXES generated boxes seen by four cameras,
//     against a pyramid of a raster; every verdict of occlusion_check.comp
//     equal to occlusion_reference's. The generator keeps boxes away from
//     the boundaries where rounding could decide (HIZ_DEPTH_MARGIN,
//     HIZ_TEXEL_MARGIN, HIZ_NDC_MARGIN) and the check fails as "not a test"
//     unless at least a quarter of the verdicts are each way.

HIZ_CHECK_BOXES :: 4096
HIZ_DEPTH_MARGIN :: 1e-5
HIZ_TEXEL_MARGIN :: 1e-3
HIZ_NDC_MARGIN :: 1e-5

// Raster_Camera: a camera the CPU raster and the check generate scenes with.
Raster_Camera :: struct {
	eye:        [3]f32,
	yaw, pitch: f32,
	fov:        f32, // vertical, radians
	aspect:     f32,
	near:       f32,
}

Raster_Box :: struct {
	lo, hi: [3]f32,
}

raster_view_proj :: proc(c: Raster_Camera) -> matrix[4, 4]f32 {
	return perspective_reverse_z(c.fov, c.aspect, c.near) * view_matrix(c.eye, c.yaw, c.pitch)
}

// Raster_Rays: what raster_ray needs of a camera, worked out once.
Raster_Rays :: struct {
	right, up, back: [3]f32, // the view's axes in the world
	sx, sy:          f32, // NDC to view-space slope
}

raster_rays :: proc(c: Raster_Camera) -> Raster_Rays {
	f := 1 / math.tan(c.fov / 2)
	rotation :=
		linalg.matrix4_rotate_f32(-c.pitch, {1, 0, 0}) *
		linalg.matrix4_rotate_f32(-c.yaw, {0, 1, 0})
	// The view's rotation is orthonormal: its inverse is its transpose, whose
	// columns are the rows here.
	return {
		right = {rotation[0, 0], rotation[0, 1], rotation[0, 2]},
		up = {rotation[1, 0], rotation[1, 1], rotation[1, 2]},
		back = {rotation[2, 0], rotation[2, 1], rotation[2, 2]},
		sx = c.aspect / f,
		sy = 1 / f,
	}
}

// raster_ray: the world direction through a pixel centre at NDC (u, v),
// scaled so a step of 1 along it is a step of 1 in w (the view depth).
raster_ray :: proc(r: Raster_Rays, u, v: f32) -> [3]f32 {
	return r.right * (u * r.sx) - r.up * (v * r.sy) - r.back
}

// box_enter: where a ray from origin along dir enters the box, and leaves.
box_enter :: proc(origin, dir: [3]f32, b: Raster_Box) -> (enter, exit: f32) {
	enter, exit = -max(f32), max(f32)
	for axis in 0 ..< 3 {
		if dir[axis] == 0 {
			if origin[axis] < b.lo[axis] || origin[axis] > b.hi[axis] {return 1, 0}
			continue
		}
		t0 := (b.lo[axis] - origin[axis]) / dir[axis]
		t1 := (b.hi[axis] - origin[axis]) / dir[axis]
		if t0 > t1 {t0, t1 = t1, t0}
		enter, exit = max(enter, t0), min(exit, t1)
	}
	return
}

// box_pixel_depth: the box's depth at a pixel centre (the raster's rule: a
// ray through it, the depth near / w where it enters); +inf when the eye is
// inside the box, 0 (the far plane) when the ray misses it.
box_pixel_depth :: proc(c: Raster_Camera, dir: [3]f32, b: Raster_Box) -> f32 {
	enter, exit := box_enter(c.eye, dir, b)
	if enter > exit || exit <= 0 {return 0}
	if enter <= 0 {return math.INF_F32}
	return c.near / enter
}

// hiz_raster draws boxes into a depth buffer (row by row, cleared to 0, the
// far plane): at each pixel centre the nearest box's depth.
hiz_raster :: proc(depth: []f32, size: [2]u32, c: Raster_Camera, boxes: []Raster_Box) {
	for &d in depth {d = 0}
	rays := raster_rays(c)
	for y in 0 ..< size.y {
		v := (f32(y) + 0.5) / f32(size.y) * 2 - 1
		for x in 0 ..< size.x {
			u := (f32(x) + 0.5) / f32(size.x) * 2 - 1
			dir := raster_ray(rays, u, v)
			d := &depth[y * size.x + x]
			for b in boxes {d^ = max(d^, box_pixel_depth(c, dir, b))}
		}
	}
}

// box_visible_in: whether some pixel of the box is nearer than the depth
// buffer there (the raster's own rule): what the occlusion test must never
// call occluded.
box_visible_in :: proc(depth: []f32, size: [2]u32, c: Raster_Camera, b: Raster_Box) -> bool {
	// Only the pixels its corners' rectangle covers, when every corner is in
	// front of the eye (else every pixel).
	view_proj := raster_view_proj(c)
	x0, y0, x1, y1 := 0, 0, int(size.x) - 1, int(size.y) - 1
	in_front := true
	rmin, rmax := [2]f32{1e30, 1e30}, [2]f32{-1e30, -1e30}
	for i in 0 ..< 8 {
		p := [4]f32 {
			b.hi.x if i & 1 != 0 else b.lo.x,
			b.hi.y if i & 2 != 0 else b.lo.y,
			b.hi.z if i & 4 != 0 else b.lo.z,
			1,
		}
		q := view_proj * p
		if q.w <= 0 {
			in_front = false
			break
		}
		rmin = {min(rmin.x, q.x / q.w), min(rmin.y, q.y / q.w)}
		rmax = {max(rmax.x, q.x / q.w), max(rmax.y, q.y / q.w)}
	}
	if in_front {
		// A pixel or two of slack: the rectangle only narrows the search.
		x0 = max(x0, int(math.floor((rmin.x * 0.5 + 0.5) * f32(size.x))) - 2)
		x1 = min(x1, int(math.floor((rmax.x * 0.5 + 0.5) * f32(size.x))) + 2)
		y0 = max(y0, int(math.floor((rmin.y * 0.5 + 0.5) * f32(size.y))) - 2)
		y1 = min(y1, int(math.floor((rmax.y * 0.5 + 0.5) * f32(size.y))) + 2)
	}
	rays := raster_rays(c)
	for y in y0 ..= y1 {
		v := (f32(y) + 0.5) / f32(size.y) * 2 - 1
		for x in x0 ..= x1 {
			u := (f32(x) + 0.5) / f32(size.x) * 2 - 1
			if box_pixel_depth(c, raster_ray(rays, u, v), b) >
			   depth[y * int(size.x) + x] {return true}
		}
	}
	return false
}

// random_box: a box of sides in [small, large] round a point at a distance
// in [near, far] in front of the camera, within a cone round its view.
random_box :: proc(
	r: ^base.Rng,
	c: Raster_Camera,
	near, far, small, large: f32,
	spread: f32 = 1.2,
) -> Raster_Box {
	u := base.rng_f32_range(r, -spread, spread)
	v := base.rng_f32_range(r, -spread, spread)
	at := c.eye + raster_ray(raster_rays(c), u, v) * base.rng_f32_range(r, near, far)
	half :=
		[3]f32 {
			base.rng_f32_range(r, small, large),
			base.rng_f32_range(r, small, large),
			base.rng_f32_range(r, small, large),
		} /
		2
	return {at - half, at + half}
}

// box_near_eye: the box comes within `gap` of the eye.
box_near_eye :: proc(c: Raster_Camera, b: Raster_Box, gap: f32) -> bool {
	for axis in 0 ..< 3 {
		if c.eye[axis] < b.lo[axis] - gap || c.eye[axis] > b.hi[axis] + gap {return false}
	}
	return true
}

// hiz_check runs both halves; what differed (none: it passed), in the temp
// allocator.
hiz_check :: proc(p: ^World_Pass, g: ^gpu.Gpu) -> (failures: [dynamic]string) {
	failures = make([dynamic]string, context.temp_allocator)
	defer {
		// The frames remake the pyramid for their own depth image.
		gpu.wait_idle(g)
		p.hiz.depth_version = 0
	}
	SIZES :: [?][2]u32{{640, 360}, {1280, 720}, {1366, 768}, {3, 2}, {1, 1}}
	for size in SIZES {
		for fill in 0 ..< 2 {
			depth := make([]f32, size.x * size.y, context.temp_allocator)
			if fill == 0 {
				// A fixed hash, in [0, 1] (no denormals: 24 bits over 2^24).
				for &d, i in depth {
					h := u32(i) * 0x9e3779b1 ~ size.x * 0x85ebca6b
					h ~= h >> 15
					h *= 0x2c1b3c6d
					h ~= h >> 12
					d = f32(h >> 8) / f32(1 << 24)
				}
			} else {
				c, boxes := check_scene(0, size)
				hiz_raster(depth, size, c, boxes)
			}
			if !pyramid_case(
				p,
				g,
				depth,
				size,
				fmt.tprintf("%dx%d %s", size.x, size.y, fill == 0 ? "hash" : "raster"),
				&failures,
			) {
				return
			}
			if len(failures) > 20 {return}
		}
	}
	occlusion_cases(p, g, &failures)
	return
}

// check_scene: camera k's scene for the check: a wall part of the way and
// boxes round it (no box near the eye: depths stay within [0, 1]).
@(private = "file")
check_scene :: proc(k: int, size: [2]u32) -> (c: Raster_Camera, boxes: []Raster_Box) {
	r := base.rng_make(u64(87 + k))
	c = {
		eye    = {
			base.rng_f32_range(&r, -5, 5),
			base.rng_f32_range(&r, -5, 5),
			base.rng_f32_range(&r, -5, 5),
		},
		yaw    = base.rng_f32_range(&r, -math.PI, math.PI),
		pitch  = base.rng_f32_range(&r, -0.8, 0.8),
		fov    = math.PI / 2.5,
		aspect = f32(size.x) / f32(size.y),
		near   = 0.1,
	}
	list := make([dynamic]Raster_Box, context.temp_allocator)
	// A wall across most of the view.
	append(&list, random_box(&r, c, 14, 18, 30, 34, 0.1))
	for len(list) < 24 {
		b := random_box(&r, c, 4, 50, 1, 9)
		if !box_near_eye(c, b, 1) {append(&list, b)}
	}
	return c, list[:]
}

// pyramid_case: half (a) for one depth image.
@(private = "file")
pyramid_case :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	depth: []f32,
	size: [2]u32,
	name: string,
	failures: ^[dynamic]string,
) -> bool {
	fail :: proc(failures: ^[dynamic]string, format: string, args: ..any) {
		append(failures, fmt.tprintf(format, ..args))
	}
	image, ok := gpu.create_image(
		g,
		size.x,
		size.y,
		gpu.DEPTH_FORMAT,
		gpu.DEPTH_USAGE + {.TRANSFER_DST},
		"hiz check depth",
	)
	if !ok {
		fail(failures, "%s: could not make its depth image", name)
		return false
	}
	defer gpu.destroy_image(g, &image)
	if !hiz_resize(&p.hiz, g, image) {
		fail(failures, "%s: could not make the pyramid", name)
		return false
	}
	h := &p.hiz
	texels := 0
	for level in 0 ..< h.mips {
		m := hiz_mip_size(h.size, level)
		texels += int(m.x * m.y)
	}
	usage := vk.BufferUsageFlags{.TRANSFER_SRC, .TRANSFER_DST}
	upload, readback: gpu.Buffer
	defer {
		gpu.destroy_buffer(g, &upload)
		gpu.destroy_buffer(g, &readback)
	}
	upload, ok = gpu.create_buffer(g, len(depth) * 4, usage, true, "hiz check upload")
	if ok {readback, ok = gpu.create_buffer(g, texels * 4, usage, true, "hiz check readback")}
	if !ok {
		fail(failures, "%s: could not make its buffers", name)
		return false
	}
	copy(([^]f32)(upload.mapped)[:len(depth)], depth)
	run, started := gpu.one_shot_begin(g)
	if !started {
		fail(failures, "%s: could not record its commands", name)
		return false
	}
	depth_upload(run.cmd, image, upload)
	hiz_build(h, g, run.cmd, image)
	regions := make([dynamic]vk.BufferImageCopy, context.temp_allocator)
	offset := 0
	for level in 0 ..< h.mips {
		m := hiz_mip_size(h.size, level)
		append(
			&regions,
			vk.BufferImageCopy {
				bufferOffset = vk.DeviceSize(offset * 4),
				imageSubresource = {aspectMask = {.COLOR}, mipLevel = level, layerCount = 1},
				imageExtent = {m.x, m.y, 1},
			},
		)
		offset += int(m.x * m.y)
	}
	vk.CmdCopyImageToBuffer(
		run.cmd,
		h.image.handle,
		.GENERAL,
		readback.handle,
		u32(len(regions)),
		raw_data(regions),
	)
	memory_barrier(run.cmd, {.COPY}, {.TRANSFER_WRITE}, {.HOST}, {.HOST_READ})
	if !gpu.one_shot_end(g, &run) {
		fail(failures, "%s: its commands did not run", name)
		return false
	}
	want := hiz_reference(depth, size, context.temp_allocator)
	if want.size != h.size || want.mips != h.mips {
		fail(
			failures,
			"%s: pyramid %v %d levels, the reference's %v %d",
			name,
			h.size,
			h.mips,
			want.size,
			want.mips,
		)
		return true
	}
	got := ([^]u32)(readback.mapped)
	offset = 0
	for level in 0 ..< h.mips {
		m := hiz_mip_size(h.size, level)
		wrong := 0
		for w, i in want.levels[level] {
			if got[offset + i] != transmute(u32)w {
				if wrong < 3 {
					fail(
						failures,
						"%s: level %d texel (%d, %d): %v, not %v",
						name,
						level,
						u32(i) % m.x,
						u32(i) / m.x,
						transmute(f32)got[offset + i],
						w,
					)
				}
				wrong += 1
			}
		}
		if wrong > 3 {fail(failures, "%s: level %d: %d texels differ in all", name, level, wrong)}
		offset += int(m.x * m.y)
	}
	return true
}

// depth_upload records the copy of a depth image's values from a buffer,
// leaving it as a frame's rendering leaves it (DEPTH_ATTACHMENT_OPTIMAL,
// written by the depth tests).
@(private = "file")
depth_upload :: proc(cmd: vk.CommandBuffer, image: gpu.Image, upload: gpu.Buffer) {
	to_copy := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		dstStageMask     = {.COPY},
		dstAccessMask    = {.TRANSFER_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .TRANSFER_DST_OPTIMAL,
		image            = image.handle,
		subresourceRange = gpu.whole_image(image),
	}
	image_barriers(cmd, {to_copy})
	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.DEPTH}, layerCount = 1},
		imageExtent = {image.width, image.height, 1},
	}
	vk.CmdCopyBufferToImage(cmd, upload.handle, image.handle, .TRANSFER_DST_OPTIMAL, 1, &region)
	to_depth := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COPY},
		srcAccessMask    = {.TRANSFER_WRITE},
		dstStageMask     = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .COMPUTE_SHADER},
		dstAccessMask    = {
			.DEPTH_STENCIL_ATTACHMENT_READ,
			.DEPTH_STENCIL_ATTACHMENT_WRITE,
			.SHADER_SAMPLED_READ,
		},
		oldLayout        = .TRANSFER_DST_OPTIMAL,
		newLayout        = .DEPTH_ATTACHMENT_OPTIMAL,
		image            = image.handle,
		subresourceRange = gpu.whole_image(image),
	}
	image_barriers(cmd, {to_depth})
}

// Occlusion_Check_Push matches occlusion_check.comp's push constants.
@(private = "file")
Occlusion_Check_Push :: struct {
	view_proj: matrix[4, 4]f32,
	boxes:     u64,
	verdicts:  u64,
	hiz:       Hiz_Info,
	count:     u32,
}

@(private = "file")
Check_Box :: struct {
	lo, hi: [4]f32,
}

// occlusion_cases: half (b).
@(private = "file")
occlusion_cases :: proc(p: ^World_Pass, g: ^gpu.Gpu, failures: ^[dynamic]string) {
	fail :: proc(failures: ^[dynamic]string, format: string, args: ..any) {
		append(failures, fmt.tprintf(format, ..args))
	}
	SIZE :: [2]u32{640, 360}
	N :: HIZ_CHECK_BOXES
	image, ok := gpu.create_image(
		g,
		SIZE.x,
		SIZE.y,
		gpu.DEPTH_FORMAT,
		gpu.DEPTH_USAGE + {.TRANSFER_DST},
		"hiz check depth",
	)
	if !ok {
		fail(failures, "occlusion: could not make its depth image")
		return
	}
	defer gpu.destroy_image(g, &image)
	if !hiz_resize(&p.hiz, g, image) {
		fail(failures, "occlusion: could not make the pyramid")
		return
	}
	usage := vk.BufferUsageFlags{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS, .TRANSFER_SRC}
	upload, boxes_buffer, verdicts: gpu.Buffer
	defer {
		gpu.destroy_buffer(g, &upload)
		gpu.destroy_buffer(g, &boxes_buffer)
		gpu.destroy_buffer(g, &verdicts)
	}
	upload, ok = gpu.create_buffer(g, int(SIZE.x * SIZE.y) * 4, usage, true, "hiz check upload")
	if ok {boxes_buffer, ok = gpu.create_buffer(g, N * size_of(Check_Box), usage, true, "hiz check boxes")}
	if ok {verdicts, ok = gpu.create_buffer(g, N * 4, usage, true, "hiz check verdicts")}
	if !ok {
		fail(failures, "occlusion: could not make its buffers")
		return
	}
	depth := make([]f32, SIZE.x * SIZE.y, context.temp_allocator)
	boxes := make([]Raster_Box, N, context.temp_allocator)
	for k in 0 ..< 4 {
		c, occluders := check_scene(k, SIZE)
		hiz_raster(depth, SIZE, c, occluders)
		want := hiz_reference(depth, SIZE, context.temp_allocator)
		view_proj := raster_view_proj(c)
		// Boxes away from every boundary rounding could decide.
		r := base.rng_make(u64(1000 + k))
		verdict := make([]bool, N, context.temp_allocator)
		occluded_count, tries := 0, 0
		for i := 0; i < N; tries += 1 {
			if tries > 50 * N {
				fail(failures, "occlusion camera %d: only %d boxes clear of the boundaries", k, i)
				return
			}
			b := random_box(&r, c, 0.5, 60, 0.05, 6, 1.6)
			v := occlusion_reference(view_proj, b.lo, b.hi, &want)
			if v.depth_margin < HIZ_DEPTH_MARGIN ||
			   v.texel_margin < HIZ_TEXEL_MARGIN ||
			   v.ndc_margin < HIZ_NDC_MARGIN {continue}
			boxes[i], verdict[i] = b, v.occluded
			if v.occluded {occluded_count += 1}
			i += 1
		}
		if occluded_count < N / 4 || N - occluded_count < N / 4 {
			fail(
				failures,
				"occlusion camera %d: %d of %d boxes occluded: not a test of both verdicts",
				k,
				occluded_count,
				N,
			)
		}
		copy(([^]f32)(upload.mapped)[:len(depth)], depth)
		for b, i in boxes {
			([^]Check_Box)(boxes_buffer.mapped)[i] = {
				{b.lo.x, b.lo.y, b.lo.z, 0},
				{b.hi.x, b.hi.y, b.hi.z, 0},
			}
		}
		for &b in verdicts.mapped[:verdicts.size] {b = 0xa5}
		run, started := gpu.one_shot_begin(g)
		if !started {
			fail(failures, "occlusion: could not record its commands")
			return
		}
		depth_upload(run.cmd, image, upload)
		hiz_build(&p.hiz, g, run.cmd, image)
		gpu.bind_globals_compute(g, run.cmd)
		vk.CmdBindPipeline(run.cmd, .COMPUTE, p.occlusion_check.handle)
		push := Occlusion_Check_Push {
			view_proj = view_proj,
			boxes     = gpu.buffer_address(g, boxes_buffer),
			verdicts  = gpu.buffer_address(g, verdicts),
			hiz       = hiz_info(&p.hiz),
			count     = N,
		}
		gpu.push_constants(g, run.cmd, &push)
		vk.CmdDispatch(run.cmd, (N + 63) / 64, 1, 1)
		memory_barrier(run.cmd, {.COMPUTE_SHADER}, {.SHADER_STORAGE_WRITE}, {.HOST}, {.HOST_READ})
		if !gpu.one_shot_end(g, &run) {
			fail(failures, "occlusion: its commands did not run")
			return
		}
		got := ([^]u32)(verdicts.mapped)
		wrong := 0
		for i in 0 ..< N {
			if got[i] != u32(verdict[i]) {
				if wrong < 5 {
					fail(
						failures,
						"occlusion camera %d box %d %v: the GPU says %d, the reference %v",
						k,
						i,
						boxes[i],
						got[i],
						verdict[i],
					)
				}
				wrong += 1
			}
		}
		if wrong > 5 {fail(failures, "occlusion camera %d: %d of %d verdicts differ", k, wrong, N)}
	}
}
