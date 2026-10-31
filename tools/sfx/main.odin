package sfx_tool

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import "client:sfx"

// Writes every synthesized sound effect to build/sounds/<name>.wav (16-bit
// mono at sfx.RATE), to listen to them outside the game:
//
//	build sfx
main :: proc() {
	dir := filepath.join({"build", "sounds"}) or_else "sounds"
	os.remove_all(dir) // no leftovers of sounds that are gone
	os.make_directory_all(dir)
	count := 0
	for m in sfx.Material {
		for a in sfx.Action {
			for v in 0 ..< sfx.VARIANTS {
				name := fmt.tprintf("%v_%v_%d.wav", m, a, v)
				write_wav(
					filepath.join({dir, name}) or_else name,
					sfx.block_sound(m, a, v),
				) or_continue
				count += 1
			}
		}
	}
	for c in sfx.Sheep_Sound {
		for v in 0 ..< sfx.VARIANTS {
			name := fmt.tprintf("Sheep_%v_%d.wav", c, v)
			write_wav(filepath.join({dir, name}) or_else name, sfx.sheep_sound(c, v)) or_continue
			count += 1
		}
	}
	for p in sfx.Player_Sound {
		for v in 0 ..< sfx.VARIANTS {
			name := fmt.tprintf("Player_%v_%d.wav", p, v)
			write_wav(filepath.join({dir, name}) or_else name, sfx.player_sound(p, v)) or_continue
			count += 1
		}
	}
	fmt.printfln("sfx: wrote %d sounds to %s", count, dir)
}

write_wav :: proc(path: string, samples: []f32) -> bool {
	data := make([]u8, 44 + 2 * len(samples))
	defer delete(data)
	copy(data[0:], "RIFF")
	endian.put_u32(data[4:], .Little, u32(36 + 2 * len(samples)))
	copy(data[8:], "WAVEfmt ")
	endian.put_u32(data[16:], .Little, 16)
	endian.put_u16(data[20:], .Little, 1) // PCM
	endian.put_u16(data[22:], .Little, 1) // mono
	endian.put_u32(data[24:], .Little, sfx.RATE)
	endian.put_u32(data[28:], .Little, sfx.RATE * 2)
	endian.put_u16(data[32:], .Little, 2)
	endian.put_u16(data[34:], .Little, 16)
	copy(data[36:], "data")
	endian.put_u32(data[40:], .Little, u32(2 * len(samples)))
	for x, i in samples {
		endian.put_i16(data[44 + 2 * i:], .Little, i16(clamp(x, -1, 1) * 32767))
	}
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("sfx: cannot write %s: %v", path, err)
		return false
	}
	return true
}
