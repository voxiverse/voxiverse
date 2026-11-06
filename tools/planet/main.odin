package planet_tool

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"

import "common:base"
import "common:planet"

// The home world's relief: reads NOAA ETOPO5 and writes the committed relief file.
//
//	build planet import <ETOPO5.DAT> [out]
//	build planet maps [dir]          (PNGs of the climate model, default build/planet)
//
// The source is downloaded, never committed (assets/planet/README.md has where from).

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "maps" {
		dir := args[1] if len(args) > 1 else "build/planet"
		os.exit(0 if maps_main(dir) else 1)
	}
	if len(args) < 2 || args[0] != "import" {
		fmt.eprintln("usage: build planet import <ETOPO5.DAT> [out] | build planet maps [dir]")
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
