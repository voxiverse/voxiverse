package game

// Voxel models (data/models/<name>.json): a small grid of voxels with a
// palette of three or four colours, what a weapon looks like in a hand. Model
// space: +x right, +y up, -z front (the muzzle's end).

MODEL_MAX_SIZE :: 16 // voxels along an axis
MODEL_MAX_COLORS :: 4
MODEL_MIN_COLORS :: 3

Model_Def :: struct {
	id:      string,
	size:    [3]u8, // length (z), height (y), width (x): the columns, rows and slices of the picture
	colors:  u8, // 3 or 4
	palette: [MODEL_MAX_COLORS][4]u8, // sRGB
	voxels:  []u8, // 0 empty, 1..colors a palette colour; index x + z * width + y * width * length
	grip:    [3]u8, // the voxel the hand closes round: x, y, z in model space
}

// model_size: the extent in voxels as x (width), y (height), z (length).
model_size :: proc(m: ^Model_Def) -> [3]int {
	return {int(m.size[2]), int(m.size[1]), int(m.size[0])}
}

// model_voxel: the colour number at x, y, z (0: empty, or outside the model).
model_voxel :: proc(m: ^Model_Def, x, y, z: int) -> u8 {
	s := model_size(m)
	if x < 0 || y < 0 || z < 0 || x >= s.x || y >= s.y || z >= s.z {return 0}
	return m.voxels[x + z * s.x + y * s.x * s.z]
}
