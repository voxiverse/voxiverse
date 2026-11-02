package game

import "core:fmt"
import "core:slice"

import "common:base"

// A pack of the pack tests (here, not in a _test file, so the tests of the
// server and the client use the same one): "testpack" with the block marble,
// whose texture is a PNG and whose sounds are an Ogg. The PNG is drawn by
// code (a 16x16 gradient), the Ogg is testdata/click.ogg.

@(private = "file")
TEST_CLICK := #load("testdata/click.ogg")
TEST_LONG := #load("testdata/long_sound.ogg") // 5.1 s: made by `build ogg make-test-files`

TEST_MARBLE_PNG :: "assets/textures/marble.png"
TEST_MARBLE_OGG :: "assets/sounds/click.ogg"

// test_marble_pixels: the PNG's pixels (what the registry must decode).
test_marble_pixels :: proc() -> Texture_Image {
	pixels: Texture_Image
	for y in 0 ..< TEXTURE_SIZE {
		for x in 0 ..< TEXTURE_SIZE {
			pixels[y * TEXTURE_SIZE + x] = {u8(x * 16), u8(y * 16), u8(x * y), 255 - u8(x * 3)}
		}
	}
	return pixels
}

test_click_ogg :: proc() -> []u8 {return TEST_CLICK}

test_long_ogg :: proc() -> []u8 {return TEST_LONG}

// test_asset_pack: marble with its light, and its image and sounds. Files are
// in `allocator` (a server test that runs ticks must not use the temp one:
// each tick frees it).
test_asset_pack :: proc(
	light := 7,
	sound_files := []string{TEST_MARBLE_OGG},
	allocator := context.temp_allocator,
) -> Pack_Source {
	context.temp_allocator = allocator // (everything below is made in it)
	pixels := test_marble_pixels()
	png, _ := base.png_encode(
		TEXTURE_SIZE,
		TEXTURE_SIZE,
		slice.to_bytes(pixels[:]),
		context.temp_allocator,
	)
	files := make([dynamic]Pack_File, context.temp_allocator)
	text :: proc(s: string) -> []u8 {return transmute([]u8)s}
	append(
		&files,
		Pack_File {
			"pack.json",
			text(
				`{"format": 1, "namespace": "testpack", "version": "1.0.0", "title": "T", "requires": ["voxiverse"]}`,
			),
		},
	)
	append(
		&files,
		Pack_File {
			"data/blocks/marble.json",
			text(
				fmt.tprintf(
					`{{"marble": {{"textures": {{"all": "testpack:marble"}}, "light": %d, "sound": "testpack:marble"}}}}`,
					light,
				),
			),
		},
	)
	append(
		&files,
		Pack_File {
			"assets/textures/marble.json",
			text(`{"marble": {"image": "` + TEST_MARBLE_PNG + `"}}`),
		},
	)
	append(&files, Pack_File{TEST_MARBLE_PNG, png})
	quoted := make([dynamic]string, context.temp_allocator)
	for f in sound_files {append(&quoted, fmt.tprintf(`"%s"`, f))}
	joined := ""
	for q, i in quoted {joined = fmt.tprintf("%s%s%s", joined, ", " if i > 0 else "", q)}
	append(
		&files,
		Pack_File {
			"assets/sounds/marble.json",
			text(fmt.tprintf(`{{"marble": {{"break": [%s], "step": [%s]}}}}`, joined, joined)),
		},
	)
	append(&files, Pack_File{TEST_MARBLE_OGG, TEST_CLICK})
	return {"testpack", files[:]}
}

// sim_test: a pack with a creeping substance and fire, defined without engine code:
// the rule language's test pack. Its channels, blocks, tag and rules are the constants
// below; sim_test_pack adds files of the caller's (broken rules for the refusal tests).
SIM_TEST_MANIFEST :: `{"format": 1, "namespace": "sim_test", "version": "1.0.0", "title": "Simulation test pack", "requires": ["voxiverse"]}`
SIM_TEST_CHANNELS :: `{"wetness": {"bits": 4, "default": 0, "saved": true, "replicated": true}, "secret": {"bits": 8, "default": 0, "saved": true, "replicated": false}, "potency": {"bits": 4, "default": 0, "saved": true, "replicated": true}}`
SIM_TEST_BLOCKS :: `{"creep": {"collides": true, "opaque": true, "breakable": true, "textures": {"all": "voxiverse:stone"}}, "fire": {"collides": false, "opaque": false, "targetable": false, "breakable": true, "light": 15, "textures": {"all": "voxiverse:water"}}}`
SIM_TEST_TAG :: `{"flammable": {"values": ["voxiverse:planks", "voxiverse:log", "voxiverse:leaves", "voxiverse:wool"]}}`
SIM_TEST_CREEP :: `{
  "creep": {
    "blocks": ["sim_test:creep"],
    "trigger": "scheduled",
    "delay": 10,
    "do": [
      "require self.potency > 0",
      {"repeat": 2, "do": [
        "pick t -1..1 -1..1 -1..1",
        "require t is voxiverse:stone",
        "set t sim_test:creep",
        "set t.potency self.potency - 1",
        "schedule t 10"
      ]}
    ]
  }
}`
SIM_TEST_FIRE :: `{
  "fire": {
    "blocks": ["sim_test:fire"],
    "trigger": "scheduled",
    "delay": 15,
    "wake": ["placed", "neighbour"],
    "do": [
      {"if": "count box(-1..1, -1..1, -1..1) is #sim_test:flammable == 0",
       "then": ["set self voxiverse:air", "stop"]},
      "schedule self 15",
      {"repeat": 3, "do": [
        "pick t -1..1 -1..1 -1..1",
        "require t is #sim_test:flammable",
        "chance 3",
        "set t sim_test:fire"
      ]},
      "chance 6",
      "set self voxiverse:air"
    ]
  }
}`

sim_test_pack :: proc(
	extra: []Pack_File = nil,
	with_rules := true,
	allocator := context.temp_allocator,
	creep := SIM_TEST_CREEP,
) -> Pack_Source {
	files := make([dynamic]Pack_File, allocator)
	text :: proc(s: string) -> []u8 {return transmute([]u8)s}
	append(&files, Pack_File{"pack.json", text(SIM_TEST_MANIFEST)})
	append(&files, Pack_File{"data/channels/test.json", text(SIM_TEST_CHANNELS)})
	append(&files, Pack_File{"data/blocks/substances.json", text(SIM_TEST_BLOCKS)})
	append(&files, Pack_File{"data/block_tags/flammable.json", text(SIM_TEST_TAG)})
	if with_rules {
		append(&files, Pack_File{"data/sim/creep.json", text(creep)})
		append(&files, Pack_File{"data/sim/fire.json", text(SIM_TEST_FIRE)})
	}
	append(&files, ..extra)
	return {"sim_test", files[:]}
}
