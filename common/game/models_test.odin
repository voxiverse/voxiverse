package game

import "core:strings"
import "core:testing"

// Voxel models are data: the base pack's weapons, a pack that adds a model and
// the item that holds it with no code, and the exact messages of broken ones.

@(private = "file")
GOOD_MODEL :: `{"pocket_gun": {"size": [4, 3, 1], "palette": ["#2b2d33", "#6f7480", "#a5acb8"],
	"slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}`

@(test)
test_base_models :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	for name in ([]string{"pistol", "rifle", "sniper", "rocket_launcher"}) {
		item, ok := registry_item(reg, name)
		testing.expect(t, ok, name)
		info, _ := registry_item_info(reg, item)
		at, has := info.model.?
		testing.expectf(t, has, "%s has a model", name)
		if !has {continue}
		m := &reg.models[at]
		testing.expectf(t, strings.has_suffix(m.id, name), "%s holds %s", name, m.id)
		testing.expectf(t, m.colors == 3 || m.colors == 4, "%s has 3 or 4 colours", name)
		s := model_size(m)
		testing.expectf(t, s.x <= 16 && s.y <= 16 && s.z <= 16, "%s fits 16 cubed", name)
		n := 0
		for v in m.voxels {if v != 0 {n += 1}}
		testing.expectf(t, n > 10, "%s has voxels", name)
		g := m.grip
		testing.expectf(
			t,
			int(g.x) < s.x && int(g.y) < s.y && int(g.z) < s.z,
			"%s's grip is inside it",
			name,
		)
	}
	// The front is column 0: the pistol's slide begins at its very front.
	item, _ := registry_item(reg, "pistol")
	info, _ := registry_item_info(reg, item)
	m := &reg.models[info.model.?]
	testing.expect_value(t, model_voxel(m, 0, int(m.size[1]) - 1, 0), u8(3))
	testing.expect_value(t, model_voxel(m, 9, 0, 0), u8(0)) // outside
}

@(test)
test_pack_adds_a_model_and_its_item :: proc(t: ^testing.T) {
	reg, errs := build_with(
		pack_of(
			"testpack",
			[]File {
				{"data/models/gun.json", GOOD_MODEL},
				{"data/items/gun.json", `{"gun": {"stack": 1, "model": "testpack:pocket_gun"}}`},
			},
		),
	)
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	defer registry_destroy(reg)
	gun, _ := registry_item(reg, "testpack:gun")
	info, _ := registry_item_info(reg, gun)
	at, has := info.model.?
	testing.expect(t, has, "the item holds the model")
	m := &reg.models[at]
	testing.expect_value(t, m.id, "testpack:pocket_gun")
	testing.expect_value(t, m.size, [3]u8{4, 3, 1})
	testing.expect_value(t, m.colors, u8(3))
	testing.expect_value(t, m.palette[2], [4]u8{0xa5, 0xac, 0xb8, 255})
	testing.expect_value(t, m.grip, [3]u8{0, 1, 2}) // model space: slice, up from the bottom, column
	// Row 0 is the top, column 0 the front: "2211" is the top row's front to back.
	testing.expect_value(t, model_voxel(m, 0, 2, 0), u8(2))
	testing.expect_value(t, model_voxel(m, 0, 2, 3), u8(1))
	testing.expect_value(t, model_voxel(m, 0, 1, 0), u8(0))
	testing.expect_value(t, model_voxel(m, 0, 0, 2), u8(1))
	// The registry's hash follows the model.
	changed, _ := strings.replace(GOOD_MODEL, "2211", "2221", 1, context.temp_allocator)
	other, _ := build_with(
		pack_of(
			"testpack",
			[]File {
				{"data/models/gun.json", changed},
				{"data/items/gun.json", `{"gun": {"stack": 1, "model": "testpack:pocket_gun"}}`},
			},
		),
	)
	if other == nil {return}
	defer registry_destroy(other)
	testing.expect(t, other.hash != reg.hash, "a changed voxel changes the hash")
}

@(test)
test_broken_models :: proc(t: ^testing.T) {
	Case :: struct {
		model, message: string,
	}
	cases := []Case {
		{
			`{"m": {"size": [4, 3, 1], "palette": ["#111111", "#222222", "#333333"], "slices": [["2211", "..14", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:93: "4" is not in the palette of 3 colours`,
		},
		{
			`{"m": {"size": [4, 3, 1], "palette": ["#111111", "#222222", "#333333"], "slices": [["22111", "..11", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:85: a row is a text of 4 characters (the length)`,
		},
		{
			`{"m": {"size": [4, 3, 1], "palette": ["#111111", "#222222", "#333333"], "slices": [["2211", "..11", "..1."]], "grip": [4, 1, 0]}}`,
			`testpack/data/models/m.json:1:119: grip is [column, row, slice], a voxel inside the size`,
		},
		{
			`{"m": {"size": [4, 3, 1], "palette": ["#111111", "#222222", "#333333", "#444444", "#555555"], "slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:38: palette is 3 or 4 colours such as "#a5acb8"`,
		},
		{
			`{"m": {"size": [4, 3, 2], "palette": ["#111111", "#222222", "#333333"], "slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:83: slices is a list of 2 slices (the width), got another count`,
		},
		{
			`{"m": {"size": [0, 3, 1], "palette": ["#111111", "#222222", "#333333"], "slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:16: size is [length, height, width], each a whole number 1..16`,
		},
		{
			`{"m": {"size": [4, 3, 1], "palette": ["#111111", "#222222", "#333333"], "slices": [["....", "....", "...."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:83: a model has at least one voxel`,
		},
		{
			`{"m": {"size": [4, 3, 1], "palette": ["red", "#222222", "#333333"], "slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}`,
			`testpack/data/models/m.json:1:39: a palette colour is "#rrggbb"`,
		},
	}
	for c, i in cases {
		_, bad := build_with(pack_of("testpack", []File{{"data/models/m.json", c.model}}))
		testing.expectf(
			t,
			errors_text(bad) == c.message,
			"case %d: got %q, want %q",
			i,
			errors_text(bad),
			c.message,
		)
	}
	// An item that names a model that is not there.
	_, bad := build_with(
		pack_of(
			"testpack",
			[]File{{"data/items/gun.json", `{"gun": {"model": "voxiverse:pistl"}}`}},
		),
	)
	testing.expect_value(
		t,
		errors_text(bad),
		`testpack/data/items/gun.json:1:19: "voxiverse:pistl" is not a model; did you mean "voxiverse:pistol"?`,
	)
}
