package planet_tool

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"

import "common:base"
import "common:game"
import "common:planet"

// The home world's relief: reads NOAA ETOPO5 and writes the committed relief file.
//
//	build planet import <ETOPO5.DAT> [out]
//	build planet climate [out]       (Earth's climate and rivers, built from the committed relief,
//	                                 to assets/planet/earth_climate.bin)
//	build planet maps [dir] [--address <a>] [--seed N]
//	                                 (PNGs of the climate model, default build/planet; with an
//	                                 address, of the world generated for it: the address as
//	                                 players write it or as a directory name, the seed 0 unless given)
//
// The source is downloaded, never committed (assets/planet/README.md has where from).

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "maps" {
		dir := "build/planet"
		address: Maybe(game.Address)
		seed := u64(0)
		rest := args[1:]
		for len(rest) > 0 {
			switch rest[0] {
			case "--address", "--seed":
				if len(rest) < 2 {
					fmt.eprintln("planet:", rest[0], "needs a value")
					os.exit(2)
				}
				if rest[0] == "--address" {
					a, ok := game.address_parse(rest[1], game.address_derive(seed).galaxy)
					if !ok {
						fmt.eprintln("planet: not an address:", rest[1])
						os.exit(2)
					}
					address = a
				} else {
					n, ok := strconv.parse_u64(rest[1])
					if !ok {
						fmt.eprintln("planet: not a number:", rest[1])
						os.exit(2)
					}
					seed = n
				}
				rest = rest[2:]
			case:
				dir = rest[0]
				rest = rest[1:]
			}
		}
		os.exit(0 if maps_main(dir, address, seed) else 1)
	}
	if len(args) >= 1 && args[0] == "climate" {
		out := args[1] if len(args) > 1 else "assets/planet/earth_climate.bin"
		os.exit(0 if climate_main(out) else 1)
	}
	if len(args) < 2 || args[0] != "import" {
		fmt.eprintln(
			"usage: build planet import <ETOPO5.DAT> [out] | build planet climate [out] | build planet maps [dir] [--address <a>] [--seed N]",
		)
		os.exit(2)
	}
	out := args[2] if len(args) > 2 else "assets/planet/earth_relief.bin"
	src, err := os.read_entire_file(args[1], context.allocator)
	if err != nil {
		fmt.eprintln("planet: cannot read", args[1])
		os.exit(1)
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, src, digest[:])
	fmt.printfln(
		"voxiverse %s; source SHA-256 %s",
		base.VERSION,
		string(hex.encode(digest[:], context.temp_allocator)),
	)
	relief, ok := planet.relief_from_etopo5(src)
	if !ok {
		fmt.eprintfln("planet: %s is not ETOPO5 (%d bytes expected)", args[1], planet.ETOPO5_SIZE)
		os.exit(1)
	}
	if werr := os.write_entire_file(out, planet.relief_encode(relief)); werr != nil {
		fmt.eprintln("planet: cannot write", out)
		os.exit(1)
	}
	fmt.printfln("wrote %s (hash %016x)", out, planet.relief_hash(relief))
}

// climate_main builds Earth's climate and rivers from the committed relief and writes the file.
climate_main :: proc(out: string) -> bool {
	relief, ok := planet.relief_decode(#load("../../assets/planet/earth_relief.bin"))
	if !ok {
		fmt.eprintln("planet: the committed relief file does not load")
		return false
	}
	defer planet.relief_destroy(&relief)
	p := planet.planet_build(relief)
	defer planet.planet_destroy(&p)
	rv := planet.rivers_build(p.land, p.precip)
	defer planet.rivers_destroy(&rv)
	data := planet.climate_encode(relief, p, rv)
	defer delete(data)
	if err := os.write_entire_file(out, data); err != nil {
		fmt.eprintln("planet: cannot write", out)
		return false
	}
	fmt.printfln("wrote %s (%d bytes, climate hash %016x)", out, len(data), planet.planet_hash(p))
	return true
}
