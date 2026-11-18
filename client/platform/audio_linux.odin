package platform

import "core:c"
import "core:dynlib"
import "core:reflect"
import "core:sync"
import "core:sys/linux"
import "core:time"

// The sound card on Linux: ALSA's `default` PCM, which is the sound server's
// (PipeWire or PulseAudio route it) where one runs, through libasound loaded
// at run time like libX11: a machine without it starts and runs silent.
// snd_pcm_set_params asks for interleaved stereo f32 at the caller's rate
// with a buffer of AUDIO_BUFFER_MS (ALSA makes periods of a quarter of it),
// and lets the plugins resample. The thread waits for room (snd_pcm_wait,
// at most AUDIO_WAIT_MS, so a stop is seen soon) and writes what fits. An
// underrun or a suspend is recovered (snd_pcm_recover); a PCM that cannot
// be recovered is closed and the default opened again every AUDIO_RETRY.
// /dev/snd is never opened directly: that would bypass the sound server.

@(private = "file")
Alsa :: struct {
	__handle:         dynlib.Library,
	pcm_open:         proc "c" (pcm: ^rawptr, name: cstring, stream: c.int, mode: c.int) -> c.int,
	pcm_set_params:   proc "c" (
		pcm: rawptr,
		format, access: c.int,
		channels, rate: c.uint,
		soft_resample: c.int,
		latency_us: c.uint,
	) -> c.int,
	pcm_get_params:   proc "c" (pcm: rawptr, buffer_size, period_size: ^c.ulong) -> c.int,
	pcm_wait:         proc "c" (pcm: rawptr, timeout_ms: c.int) -> c.int,
	pcm_avail_update: proc "c" (pcm: rawptr) -> c.long,
	pcm_writei:       proc "c" (pcm: rawptr, buffer: rawptr, frames: c.ulong) -> c.long,
	pcm_recover:      proc "c" (pcm: rawptr, err: c.int, silent: c.int) -> c.int,
	pcm_drop:         proc "c" (pcm: rawptr) -> c.int,
	pcm_close:        proc "c" (pcm: rawptr) -> c.int,
	strerror:         proc "c" (err: c.int) -> cstring,
}

@(private = "file")
alsa: Alsa

@(private = "file")
SND_PCM_STREAM_PLAYBACK :: 0
@(private = "file")
SND_PCM_NONBLOCK :: 1
@(private = "file")
SND_PCM_FORMAT_FLOAT_LE :: 14
@(private = "file")
SND_PCM_ACCESS_RW_INTERLEAVED :: 3

// AUDIO_BLOCK: the most frames filled at a time (the thread's own buffer).
@(private = "file")
AUDIO_BLOCK :: 1024
@(private = "file")
AUDIO_WAIT_MS :: 100
@(private = "file")
AUDIO_RETRY :: 500 * time.Millisecond

Native_Audio :: struct {
	pcm:   rawptr, // snd_pcm_t; nil while lost
	block: [AUDIO_CHANNELS * AUDIO_BLOCK]f32,
}

@(private)
native_audio_start :: proc(a: ^Audio_Output) -> string {
	if alsa.__handle == nil {
		// Every field but __handle must resolve.
		count, ok := dynlib.initialize_symbols(&alsa, "libasound.so.2", "snd_")
		if !ok || count != reflect.struct_field_count(Alsa) - 1 {
			why := audio_fail(a, "libasound.so.2 not loaded (%s)", dynlib.last_error())
			if alsa.__handle != nil {dynlib.unload_library(alsa.__handle)}
			alsa = {}
			return why
		}
	}
	return pcm_open(a)
}

@(private)
native_audio_run :: proc(a: ^Audio_Output) {
	n := &a.native
	for !sync.atomic_load(&a.stopping) {
		if n.pcm == nil {
			time.sleep(AUDIO_RETRY)
			if pcm_open(a) == "" {sync.atomic_add(&a.reopens, 1)}
			continue
		}
		if err := pcm_feed(a); err < 0 {
			if err == -c.long(linux.Errno.EPIPE) || err == -c.long(linux.Errno.ESTRPIPE) {
				sync.atomic_add(&a.xruns, 1)
			}
			if alsa.pcm_recover(n.pcm, c.int(err), 1) < 0 {pcm_close(a)}
		}
	}
}

@(private)
native_audio_stop :: proc(a: ^Audio_Output) {
	pcm_close(a)
}

@(private)
native_audio_wake :: proc(a: ^Audio_Output) {
	// (the thread waits AUDIO_WAIT_MS at most)
}

@(private)
native_audio_free :: proc(a: ^Audio_Output) {}

// pcm_open opens the default PCM, settles its buffer and period, and leaves
// it prepared: it starts when the first writes fill it.
@(private = "file")
pcm_open :: proc(a: ^Audio_Output) -> string {
	n := &a.native
	pcm: rawptr
	if r := alsa.pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK); r < 0 {
		return audio_fail(a, "snd_pcm_open default: %s", alsa.strerror(r))
	}
	if r := alsa.pcm_set_params(
		pcm,
		SND_PCM_FORMAT_FLOAT_LE,
		SND_PCM_ACCESS_RW_INTERLEAVED,
		AUDIO_CHANNELS,
		c.uint(a.rate),
		1,
		AUDIO_BUFFER_MS * 1000,
	); r < 0 {
		alsa.pcm_close(pcm)
		return audio_fail(a, "snd_pcm_set_params: %s", alsa.strerror(r))
	}
	buffer, period: c.ulong
	if r := alsa.pcm_get_params(pcm, &buffer, &period); r < 0 {
		alsa.pcm_close(pcm)
		return audio_fail(a, "snd_pcm_get_params: %s", alsa.strerror(r))
	}
	sync.atomic_store(&a.buffer, u32(buffer))
	sync.atomic_store(&a.period, u32(period))
	n.pcm = pcm
	return ""
}

@(private = "file")
pcm_close :: proc(a: ^Audio_Output) {
	n := &a.native
	if n.pcm == nil {return}
	alsa.pcm_drop(n.pcm)
	alsa.pcm_close(n.pcm)
	n.pcm = nil
}

// pcm_feed waits for room and fills it. Negative: an ALSA error to recover.
@(private = "file")
pcm_feed :: proc(a: ^Audio_Output) -> c.long {
	n := &a.native
	if r := alsa.pcm_wait(n.pcm, AUDIO_WAIT_MS); r <= 0 {return c.long(r)} 	// 0: timed out
	avail := alsa.pcm_avail_update(n.pcm)
	for avail > 0 && !sync.atomic_load(&a.stopping) {
		frames := min(int(avail), AUDIO_BLOCK)
		a.fill(a.user, n.block[:AUDIO_CHANNELS * frames])
		for done := 0; done < frames; {
			r := alsa.pcm_writei(n.pcm, &n.block[AUDIO_CHANNELS * done], c.ulong(frames - done))
			if r == -c.long(linux.Errno.EAGAIN) {
				// (fuller than avail said: wait for the rest to fit)
				if w := alsa.pcm_wait(n.pcm, AUDIO_WAIT_MS); w < 0 {return c.long(w)}
				if sync.atomic_load(&a.stopping) {return 0}
				continue
			}
			if r < 0 {return r}
			done += int(r)
		}
		avail -= c.long(frames)
	}
	return avail if avail < 0 else 0
}
