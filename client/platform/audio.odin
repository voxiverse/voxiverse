package platform

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

// The sound card: the one audio service the platform gives. audio_open opens
// the system's default output for interleaved stereo f32 at the rate the
// caller mixes at, and from then until audio_close the system calls `fill`
// with a buffer of frames to fill. The system converts to the card's own
// rate and format (each backend asks it to) and follows the default output
// where it can; the mixer, the timing and everything else are the engine's.
//
//	ok, why := platform.audio_open(&out, 48000, fill, user)
//	... fill(user, out) is called, on the system's audio thread ...
//	platform.audio_close(&out) // no call to fill after it returns
//
// Linux: ALSA's `default` PCM through libasound, loaded at run time
// (audio_linux.odin). Windows: WASAPI, shared and event-driven
// (audio_windows.odin). macOS: the default output Audio Unit
// (audio_darwin.odin), which calls from a thread of its own; on Linux and
// Windows the output's own thread (audio_thread_other.odin) opens the device,
// says how that went, then feeds it until audio_close.

// Audio_Fill fills `out`: len(out) / AUDIO_CHANNELS frames, interleaved. It
// runs on a real-time thread with no context: it must not allocate, lock,
// log or block. The number of frames differs from call to call.
Audio_Fill :: #type proc "contextless" (user: rawptr, out: []f32)

AUDIO_CHANNELS :: 2

// AUDIO_BUFFER_MS: how much sound the output is asked to queue ahead of the
// speaker (Linux and Windows; macOS keeps the device's own buffer). Larger
// survives a busier machine, smaller answers sooner.
AUDIO_BUFFER_MS :: 40

Audio_Output :: struct {
	fill:     Audio_Fill,
	user:     rawptr,
	rate:     u32, // frames per second fill is asked for
	period:   u32, // (atomic) frames the system takes at a time, as settled
	buffer:   u32, // (atomic) frames queued ahead of the speaker, at most: the latency
	xruns:    u32, // (atomic) times the system ran dry (fill was late) and went on
	reopens:  u32, // (atomic) times the output was lost or moved and opened again
	// The output's own thread (Linux, Windows): it opens the device, posts
	// `ready`, and runs until `stopping`.
	thread:   ^thread.Thread,
	ready:    sync.Sema,
	stopping: bool, // (atomic)
	failure:  string, // why the open failed (in why_text)
	why_text: [256]u8,
	native:   Native_Audio, // per-OS state
}

// audio_open starts calling fill. a must stay at its address until
// audio_close. False, with why (temp allocator), when no output opens: the
// caller runs silent.
audio_open :: proc(
	a: ^Audio_Output,
	rate: u32,
	fill: Audio_Fill,
	user: rawptr,
) -> (
	ok: bool,
	why: string,
) {
	a^ = {
		fill = fill,
		user = user,
		rate = rate,
	}
	if failure := native_audio_open(a); failure != "" {
		why = strings.clone(failure, context.temp_allocator)
		a^ = {}
		return false, why
	}
	return true, ""
}

// audio_close stops the calls to fill (it returns after the last one) and
// closes the output.
audio_close :: proc(a: ^Audio_Output) {
	native_audio_close(a)
	a^ = {}
}

// audio_frames: the frames in `ms` milliseconds at `rate`.
audio_frames :: proc "contextless" (rate, ms: u32) -> u32 {
	return u32(u64(rate) * u64(ms) / 1000)
}

// audio_fail writes why the output failed into a.why_text and returns it.
@(private)
audio_fail :: proc(a: ^Audio_Output, format: string, args: ..any) -> string {
	return fmt.bprintf(a.why_text[:], format, ..args)
}
