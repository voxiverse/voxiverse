package audio

import "core:log"
import "core:os"

// wav_encode: interleaved stereo as a 32-bit float WAV.
wav_encode :: proc(x: []f32, rate: u32, allocator := context.allocator) -> []byte {
	bytes := len(x) * 4
	out := make([dynamic]byte, 0, 44 + bytes, allocator)
	u32le :: proc(out: ^[dynamic]byte, v: u32) {
		for i in 0 ..< 4 {append(out, byte(v >> (8 * u32(i))))}
	}
	u16le :: proc(out: ^[dynamic]byte, v: u16) {
		append(out, byte(v), byte(v >> 8))
	}
	append(&out, "RIFF")
	u32le(&out, u32(36 + bytes))
	append(&out, "WAVEfmt ")
	u32le(&out, 16)
	u16le(&out, 3) // IEEE float
	u16le(&out, 2)
	u32le(&out, rate)
	u32le(&out, rate * 8)
	u16le(&out, 8)
	u16le(&out, 32)
	append(&out, "data")
	u32le(&out, u32(bytes))
	for v in x {u32le(&out, transmute(u32)v)}
	return out[:]
}

// wav_write writes interleaved stereo to path as a 32-bit float WAV.
wav_write :: proc(path: string, x: []f32, rate: u32) -> bool {
	data := wav_encode(x, rate)
	defer delete(data)
	if err := os.write_entire_file(path, data); err != nil {
		log.warnf("audio: cannot write %s: %v", path, err)
		return false
	}
	return true
}
