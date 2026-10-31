package engine

import "client:audio"
import "core:time"

// A power of two: 2^16 records are a few minutes of a busy session.
AUDIO_RING_RECORDS :: 1 << 16

Audio_Debug :: struct {
	recording:  bool,
	underruns:  u32, // as of the last look
	last:       time.Tick,
	written:    int,
	last_saved: bool,
	last_path:  string, // the file written last (owned, clones into the heap)
	frozen:     ^audio.Frozen, // the inspector's freeze (dev_audio_inspector.odin)
	autosaved:  time.Tick, // audio-last.vxac, written while the mixer is busy
}

// audio_ring_start begins the rolling capture (not in a benchmark, which has
// no live mixer).
audio_ring_start :: proc(app: ^App) {
	app.audio_debug.recording = audio.capture_start_ring(app.mixer, AUDIO_RING_RECORDS)
}
