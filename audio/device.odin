package audio

import "core:log"
import ma "vendor:miniaudio"

// The sound card, through miniaudio (only its device layer: it opens the
// default output and calls us for samples; mixing is ours). No device (a
// server, CI) is not an error: the game runs silent.
//
//	audio.device_open(&dev, &mixer) // sets mixer.rate, then starts
//	... audio.play(&mixer, ...) ...
//	audio.device_close(&dev)

Device :: struct {
	device: ma.device,
	open:   bool,
}

// DEVICE_RATE: what we ask for; miniaudio converts if the card differs.
DEVICE_RATE :: 48000

// device_open starts playing m through the default output. m must stay at
// its address until device_close; sounds are added before this. False:
// no sound (logged), and m is never mixed.
device_open :: proc(d: ^Device, m: ^Mixer) -> bool {
	config := ma.device_config_init(.playback)
	config.playback.format = .f32
	config.playback.channels = 2
	config.sampleRate = DEVICE_RATE
	config.performanceProfile = .low_latency
	config.dataCallback = data_callback
	config.pUserData = m
	if r := ma.device_init(nil, &config, &d.device); r != .SUCCESS {
		log.warnf("audio no output device, running silent result=%v", r)
		return false
	}
	m.rate = d.device.sampleRate
	if r := ma.device_start(&d.device); r != .SUCCESS {
		log.warnf("audio device would not start, running silent result=%v", r)
		ma.device_uninit(&d.device)
		return false
	}
	d.open = true
	log.infof("audio device open rate=%d", m.rate)
	return true
}

device_close :: proc(d: ^Device) {
	if d.open {ma.device_uninit(&d.device)} 	// stops the callbacks first
	d^ = {}
}

@(private = "file")
data_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frames: u32) {
	m := (^Mixer)(device.pUserData)
	mix(m, ([^]f32)(output)[:frames * 2])
}
