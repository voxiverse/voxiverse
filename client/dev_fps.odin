package client

import "common:base"

// Fps: what the FPS counter shows, measured over the last half second:
// steady enough to read, quick enough to follow a change.
Fps :: struct {
	fps:       f32, // frames per second
	frame_ms:  f32, // average frame time
	gpu_ms:    f32, // average GPU time per frame (0: not measured)
	// The window being measured:
	frames:    int,
	ms:        f32,
	gpu_count: int, // the GPU statistics when it began
	gpu_sum:   f64,
}

FPS_WINDOW_MS :: 500

// fps_update counts a frame that took frame_ms; gpu: the GPU's frame times
// (they arrive a couple of frames late, so they are averaged separately).
fps_update :: proc(f: ^Fps, frame_ms: f32, gpu: ^base.Frame_Stats) {
	f.frames += 1
	f.ms += frame_ms
	if f.ms < FPS_WINDOW_MS {return}
	f.fps = f32(f.frames) * 1000 / f.ms
	f.frame_ms = f.ms / f32(f.frames)
	if n := gpu.count - f.gpu_count; n > 0 {f.gpu_ms = f32((gpu.sum - f.gpu_sum) / f64(n))}
	f.frames, f.ms = 0, 0
	f.gpu_count, f.gpu_sum = gpu.count, gpu.sum
}
