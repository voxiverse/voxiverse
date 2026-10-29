package client

import "core:math"
import "core:testing"

import "../common/game"
import "mesh"
import "render"

// The view model (docs/milestones/M48k.md): a mesh for each held kind, its own
// projection, the animations' states, the third-person hand, F1.

@(private = "file")
item_named :: proc(reg: ^game.Registry, name: string) -> game.Item {
	i, ok := game.registry_item(reg, name)
	if !ok {panic(name)}
	return i
}

@(private = "file")
extent :: proc(m: ^Held_Mesh) -> (lo, hi: [3]f32) {
	lo, hi = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
	for v in m.vertices {
		lo = {min(lo.x, v.pos.x), min(lo.y, v.pos.y), min(lo.z, v.pos.z)}
		hi = {max(hi.x, v.pos.x), max(hi.y, v.pos.y), max(hi.z, v.pos.z)}
	}
	return
}

@(test)
test_a_mesh_for_each_held_kind :: proc(t: ^testing.T) {
	reg := test_reg()
	cache: Held_Cache
	defer held_cache_destroy(&cache)
	Case :: struct {
		item: string,
		kind: Held_Kind,
	}
	for c in ([]Case{{"dirt", .Block}, {"stone", .Block}, {"planks_stairs", .Block}, {"planks_slab", .Block}, {"planks_fence", .Block}, {"planks_door", .Block}, {"pistol", .Model}, {"rifle", .Model}, {"sniper", .Model}, {"rocket_launcher", .Model}, {"hoe", .Flat}}) {
		item := item_named(reg, c.item)
		e := held_entry(&cache, reg, item)
		testing.expectf(t, e.kind == c.kind, "%s: kind %v, want %v", c.item, e.kind, c.kind)
		testing.expectf(t, held_quads(&e.mesh) > 0, "%s makes a mesh", c.item)
		testing.expectf(t, len(e.mesh.vertices) % 6 == 0, "%s is whole quads", c.item)
	}
	// Materials and armor are flat items; nothing in hand is nothing.
	flat := 0
	for item in game.every_item(reg) {
		info, _ := game.item_info(reg, item)
		_, is_armor := info.armor.?
		if info.block != .Air || info.model != nil {continue} 	// (seeds place a plant)
		if !is_armor && !(item >= game.MATERIAL_ITEMS && item < game.ARMOR_ITEMS) {continue}
		e := held_entry(&cache, reg, item)
		testing.expectf(
			t,
			e.kind == .Flat && held_quads(&e.mesh) > 0,
			"%s is a flat mesh",
			info.name,
		)
		flat += 1
	}
	testing.expectf(t, flat >= 4, "materials and armor were checked (%d)", flat)
	testing.expect_value(t, held_entry(&cache, reg, game.NO_ITEM).kind, Held_Kind.None)
}

@(test)
test_the_shaped_blocks_are_meshed :: proc(t: ^testing.T) {
	reg := test_reg()
	seen := 0
	for item in game.every_item(reg) {
		info, _ := game.item_info(reg, item)
		if info.block == .Air {continue}
		m := held_mesh_block(reg, info.block)
		defer held_mesh_destroy(&m)
		// The block's own mesh: mesh_chunk over the same snapshot, quad for quad.
		snapshot := new(mesh.Snapshot)
		defer free(snapshot)
		snapshot[mesh.snapshot_index(0, 0, 0)] = info.block
		quads: [dynamic]mesh.Vertex
		defer delete(quads)
		mesh.mesh_chunk(reg, snapshot, nil, &quads, merge = false)
		testing.expectf(
			t,
			held_quads(&m) == len(quads) / 4,
			"%s: %d quads, mesh_chunk %d",
			info.name,
			held_quads(&m),
			len(quads) / 4,
		)
		seen += 1
		lo, hi := extent(&m)
		if held_quads(&m) > 0 {
			testing.expectf(
				t,
				lo.x >= -HELD_BLOCK_SCALE && hi.x <= HELD_BLOCK_SCALE,
				"%s fits",
				info.name,
			)
		}
	}
	testing.expect(t, seen > 40, "every block item was meshed")
	// A cube is six quads; a stair has more faces than a cube.
	dirt := held_mesh_block(reg, .Dirt)
	defer held_mesh_destroy(&dirt)
	testing.expect_value(t, held_quads(&dirt), 6)
	for item in game.every_item(reg) {
		info, _ := game.item_info(reg, item)
		if info.block == .Air || reg.blocks.render[info.block] == game.SHAPE_CUBE {continue}
		m := held_mesh_block(reg, info.block)
		defer held_mesh_destroy(&m)
		testing.expectf(t, held_quads(&m) >= 1, "%s", info.name)
	}
	stairs_info, _ := game.item_info(reg, item_named(reg, "planks_stairs"))
	stairs := held_mesh_block(reg, stairs_info.block)
	defer held_mesh_destroy(&stairs)
	testing.expect(t, held_quads(&stairs) > 6, "a stair has more faces than a cube")
}

@(test)
test_hidden_voxel_faces_are_not_made :: proc(t: ^testing.T) {
	// Two voxels side by side share a face: 10 quads, not 12.
	cells := [][4]u8{{255, 0, 0, 255}, {0, 255, 0, 255}}
	m := held_mesh_grid({2, 1, 1}, cells, {0, 0, 0}, 1)
	defer held_mesh_destroy(&m)
	testing.expect_value(t, held_quads(&m), 10)
	one := held_mesh_grid({1, 1, 1}, cells[:1], {0.5, 0.5, 0.5}, 1)
	defer held_mesh_destroy(&one)
	testing.expect_value(t, held_quads(&one), 6)
	lo, hi := extent(&one)
	testing.expect_value(t, lo, [3]f32{-0.5, -0.5, -0.5}) // the grip is the middle
	testing.expect_value(t, hi, [3]f32{0.5, 0.5, 0.5})
}

@(test)
test_weapon_models_are_as_big_as_promised :: proc(t: ^testing.T) {
	reg := test_reg()
	for name in ([]string{"pistol", "rifle", "sniper", "rocket_launcher"}) {
		item := item_named(reg, name)
		info, _ := game.item_info(reg, item)
		model := &reg.models[info.model.?]
		m := held_mesh_model(model)
		defer held_mesh_destroy(&m)
		testing.expectf(t, held_quads(&m) > 20, "%s has a mesh", name)
		s := model_extent(model)
		lo, hi := extent(&m)
		testing.expectf(t, hi.x - lo.x <= f32(s.x) * HELD_VOXEL + 1e-4, "%s width", name)
		testing.expectf(t, hi.y - lo.y <= f32(s.y) * HELD_VOXEL + 1e-4, "%s height", name)
		testing.expectf(t, hi.z - lo.z <= f32(s.z) * HELD_VOXEL + 1e-4, "%s length", name)
		// The front (the muzzle) is -z of the grip, the stock behind it.
		testing.expectf(
			t,
			lo.z < 0 && hi.z > 0 && -lo.z > hi.z * 0.5,
			"%s points forward from its grip",
			name,
		)
	}
}

@(private = "file")
model_extent :: proc(m: ^game.Model_Def) -> [3]int {
	return game.model_size(m)
}

@(test)
test_extruded_icon :: proc(t: ^testing.T) {
	reg := test_reg()
	item := item_named(reg, "hoe")
	info, _ := game.item_info(reg, item)
	m, ok := held_mesh_icon(item, info)
	defer held_mesh_destroy(&m)
	testing.expect(t, ok, "a hoe has a sprite")
	lo, hi := extent(&m)
	// 16 pixels across at most, HELD_THICKNESS deep.
	testing.expect(t, hi.x - lo.x <= 16 * HELD_PIXEL + 1e-4)
	testing.expect(t, abs((hi.z - lo.z) - HELD_THICKNESS * HELD_PIXEL) < 1e-4, "given a thickness")
	// A block's item has no sprite of its own.
	stone := item_named(reg, "stone")
	sinfo, _ := game.item_info(reg, stone)
	_, has := held_mesh_icon(stone, sinfo)
	testing.expect(t, !has, "a block is not a flat item")
}

@(test)
test_the_arm_is_the_avatars :: proc(t: ^testing.T) {
	m := held_mesh_arm({196, 64, 52, 255})
	defer held_mesh_destroy(&m)
	testing.expect_value(t, held_quads(&m), 12) // two boxes
	lo, hi := extent(&m)
	testing.expect_value(t, lo, [3]f32{-0.075, -0.65, -0.075})
	testing.expect_value(t, hi, [3]f32{0.075, 0.1, 0.075})
	sleeve, skin := 0, 0
	for v in m.vertices {
		if v.color == ([4]u8{196, 64, 52, 255}) {sleeve += 1}
		if v.color == AVATAR_SKIN {skin += 1}
	}
	testing.expect_value(t, sleeve, 36)
	testing.expect_value(t, skin, 36)
}

@(test)
test_the_view_model_projection_ignores_the_fov :: proc(t: ^testing.T) {
	s: Session
	s.reg = test_reg()
	aspect := f32(16.0 / 9.0)
	want := view_model_projection(aspect)
	for fov in ([]f32{30, 70, 110, 140}) {
		for kick in ([]f32{0, 1}) {
			for zoom in ([]f32{0, 1}) {
				s.fov_kick, s.zoom, s.zoom_to = kick, zoom, 0.25
				settings := Settings {
					fov = fov,
				}
				// The world's field of view moves with all of it ...
				if kick == 0 && zoom == 0 {
					testing.expect_value(t, camera_fov(&s, settings), fov)
				}
				// ... the view model's matrix with none of it.
				testing.expect_value(t, view_model_projection(aspect), want)
			}
		}
	}
	// The vertical focal length is a 60 degree field's, whatever the aspect;
	// the aspect only squeezes x.
	wide := view_model_projection(2.0)
	testing.expect_value(t, wide[1][1], want[1][1])
	testing.expect(t, wide[0][0] < want[0][0])
	testing.expect(t, abs(math.abs(want[1][1]) - 1 / math.tan(f32(VIEW_MODEL_FOV) / 2)) < 1e-5)
}

@(private = "file")
step :: proc(vm: ^Vm_State, seconds: f32, in_: Vm_Inputs) -> (pose: Vm_Pose) {
	in_ := in_
	in_.dt = 1.0 / 100
	for _ in 0 ..< int(seconds * 100 + 0.5) {pose = vm_update(vm, in_)}
	return
}

@(test)
test_swing_and_place_run_their_time :: proc(t: ^testing.T) {
	vm: Vm_State
	vm_event(&vm, .Swing)
	mid := step(&vm, VM_SWING_SECONDS / 2, {})
	testing.expect(t, mid.pitch < -0.5 && mid.yaw > 0.3, "a swing arcs at its middle")
	testing.expect(t, vm.swing > 0, "still swinging halfway")
	end := step(&vm, VM_SWING_SECONDS / 2 + 0.03, {})
	testing.expect_value(t, vm.swing, 0)
	testing.expect_value(t, end, Vm_Pose{})
	testing.expect(t, !vm_animating(&vm), "at rest again")

	vm_event(&vm, .Place)
	mid = step(&vm, VM_PLACE_SECONDS / 2, {})
	testing.expect(
		t,
		mid.offset.z < -0.05 && mid.offset.y < -0.04,
		"a place pushes forward and down",
	)
	end = step(&vm, VM_PLACE_SECONDS / 2 + 0.03, {})
	testing.expect_value(t, vm.place, 0)
	testing.expect_value(t, end, Vm_Pose{})
}

@(test)
test_recoil_kicks_and_settles :: proc(t: ^testing.T) {
	vm: Vm_State
	vm_event(&vm, .Shot)
	p := step(&vm, 0.01, {})
	testing.expect(t, p.offset.z > 0.02 && p.pitch > 0.03, "a shot kicks back and up")
	first := vm.recoil
	p = step(&vm, 0.2, {})
	testing.expect(t, vm.recoil < first * 0.2, "the kick decays")
	step(&vm, 1.0, {})
	testing.expect_value(t, vm.recoil, 0)
	// Automatic fire adds up to a cap, not beyond.
	for _ in 0 ..< 40 {
		vm_event(&vm, .Shot)
		step(&vm, 0.1, {})
		testing.expect(t, vm.recoil <= VM_RECOIL_CAP + 1e-5, "capped")
	}
	testing.expect(t, vm.recoil > 0.3, "a burst keeps the weapon up")
}

@(test)
test_reload_dips_for_the_reload_time :: proc(t: ^testing.T) {
	vm: Vm_State
	vm_event(&vm, .Reload, 1.4)
	p := step(&vm, 0.7, {})
	testing.expect(t, p.offset.y < -0.2 && p.pitch < -0.4, "dipped at the middle")
	testing.expect(t, vm_animating(&vm), "under way")
	step(&vm, 0.65, {})
	testing.expect(t, vm_animating(&vm), "still under way at 1.35 s")
	p = step(&vm, 0.1, {})
	testing.expect(t, !vm_animating(&vm), "done at 1.4 s")
	testing.expect_value(t, p, Vm_Pose{})
	// Another weapon in hand: nothing carries over.
	vm_event(&vm, .Reload, 2.5)
	step(&vm, 0.5, {})
	vm_reset(&vm)
	testing.expect(t, !vm_animating(&vm))
}

@(test)
test_sway_and_bob_follow_the_comfort_settings :: proc(t: ^testing.T) {
	off := Vm_Inputs {
		comfort   = false,
		bob_phase = 1.0,
		bob_amp   = 1,
	}
	on := off
	on.comfort = true
	vm: Vm_State
	p := step(&vm, 0.5, off)
	testing.expect_value(t, p, Vm_Pose{})
	p = step(&vm, 0.5, on)
	testing.expect(t, p.offset != {}, "the sway and the bob move it")
	still := on
	still.bob_amp = 0
	p = step(&vm, 0.3, still)
	testing.expect(
		t,
		p.offset != {} && abs(p.offset.y) <= 2 * VM_SWAY_HEIGHT,
		"idle: only the sway",
	)
	// The settings: bobbing off, or reduce motion on, turns both off.
	testing.expect(t, vm_comfort(Settings{view_bobbing = true}))
	testing.expect(t, !vm_comfort(Settings{view_bobbing = false}))
	testing.expect(t, !vm_comfort(Settings{view_bobbing = true, reduce_motion = true}))
	// ... the actions still play.
	vm2: Vm_State
	vm_event(&vm2, .Swing)
	p = step(&vm2, 0.1, off)
	testing.expect(t, p.pitch < 0, "a swing plays with bobbing off")
}

@(test)
test_the_sniper_hides_while_zoomed :: proc(t: ^testing.T) {
	vm: Vm_State
	hidden :: proc(vm: ^Vm_State, zoom: f32, zooms: bool) -> bool {
		return vm_update(vm, {dt = 0.01, zoom = zoom, zooms = zooms}).hidden
	}
	testing.expect(t, !hidden(&vm, 0, true))
	testing.expect(t, !hidden(&vm, VM_SCOPE_HIDE - 0.01, true))
	testing.expect(t, hidden(&vm, VM_SCOPE_HIDE + 0.01, true))
	testing.expect(t, hidden(&vm, 1, true))
	testing.expect(t, !hidden(&vm, 0.1, true), "back below it: shown again")
	testing.expect(t, !hidden(&vm, 1, false), "a weapon without a zoom is never hidden")
}

@(test)
test_the_hand_holds_each_kind :: proc(t: ^testing.T) {
	at :: proc(m: Mat4, p: [3]f32) -> [3]f32 {
		r := m * [4]f32{p.x, p.y, p.z, 1}
		return {r.x, r.y, r.z}
	}
	dir :: proc(m: Mat4, p: [3]f32) -> [3]f32 {
		r := m * [4]f32{p.x, p.y, p.z, 0}
		return {r.x, r.y, r.z}
	}
	shoulder := [3]f32{0.375, 1.3, 0}
	// A gun aimed: the grip is out in front of the shoulder at its height, the
	// muzzle points the way the avatar looks (-z), its top is up.
	gun := avatar_hand_matrix(.Model, shoulder, 0, AVATAR_AIMED)
	hand := at(gun, {})
	testing.expect(
		t,
		hand.z < -0.45 && abs(hand.y - shoulder.y) < 0.1,
		"the grip is in front of the shoulder",
	)
	testing.expect(t, abs(hand.x - shoulder.x) < 1e-4)
	front := dir(gun, {0, 0, -1})
	testing.expect(t, front.z < -0.99, "the muzzle points forward")
	testing.expect(t, dir(gun, {0, 1, 0}).y > 0.99, "the top is up")
	// Turned by the avatar's yaw (a quarter turn left: forward is -x).
	turned := avatar_hand_matrix(.Model, shoulder, math.PI / 2, AVATAR_AIMED)
	testing.expect(t, dir(turned, {0, 0, -1}).x < -0.99)
	// A block is carried raised, less than a gun is aimed; it is in front.
	block := avatar_hand_matrix(.Block, shoulder, 0, AVATAR_RAISED)
	testing.expect(t, at(block, {}).z < -0.3 && at(block, {}).y < hand.y)
	// At rest (nothing held, the arm hangs) a flat item would be below the shoulder.
	flat := avatar_hand_matrix(.Flat, shoulder, 0, 0)
	testing.expect(t, at(flat, {}).y < shoulder.y - 0.4)
}

@(test)
test_the_arm_follows_the_item_in_the_view :: proc(t: ^testing.T) {
	// The item's grip is the hand: the arm's hand end (0, -0.55, 0) is at the grip.
	for kind in ([]Held_Kind{.Model, .Block, .Flat}) {
		item := view_pose_matrix(kind, {})
		arm := view_arm_matrix(kind, item)
		hand := arm * [4]f32{0, -0.55, 0, 1}
		grip := item * [4]f32{0, 0, 0, 1}
		testing.expectf(
			t,
			abs(hand.x - grip.x) < 1e-4 &&
			abs(hand.y - grip.y) < 1e-4 &&
			abs(hand.z - grip.z) < 1e-4,
			"%v",
			kind,
		)
		// In front of the camera, at the lower right.
		testing.expectf(
			t,
			grip.z < -0.3 && grip.x > 0.1 && grip.y < 0,
			"%v rests at the lower right",
			kind,
		)
	}
}

@(test)
test_f1_and_the_camera_decide_if_the_view_model_is_shown :: proc(t: ^testing.T) {
	testing.expect(t, view_model_shown(.First, false, {}))
	testing.expect(t, !view_model_shown(.First, true, {}), "F1 hides it with the HUD")
	testing.expect(t, !view_model_shown(.Third_Behind, false, {}), "not in third person")
	testing.expect(t, !view_model_shown(.Third_Facing, false, {}))
	testing.expect(t, !view_model_shown(.First, false, Vm_Pose{hidden = true}), "a zoomed sniper")
	// Hidden: nothing is added to the pass.
	d: render.Held_Draw
	render.held_draw_init(&d)
	defer render.held_draw_destroy(&d)
	arm := held_mesh_arm({1, 2, 3, 255})
	defer held_mesh_destroy(&arm)
	item := held_mesh_grid({1, 1, 1}, [][4]u8{{9, 9, 9, 255}}, {}, 1)
	defer held_mesh_destroy(&item)
	if view_model_shown(.First, true, {}) {view_model_add(&d, .Model, &item, &arm, {})}
	testing.expect(t, render.held_empty(&d))
	view_model_add(&d, .Model, &item, &arm, {})
	testing.expect_value(t, len(d.view), 72 + 36)
	// An empty hand: the arm alone.
	render.held_draw_clear(&d)
	view_model_add(&d, .None, &item, &arm, {})
	testing.expect_value(t, len(d.view), 72)
}

// The biggest model's frame is a few thousand vertices moved by one matrix;
// what that costs is the `viewmodel` benchmark (`build bench viewmodel`).
@(test)
test_the_biggest_model_is_thousands_of_vertices :: proc(t: ^testing.T) {
	d, ok := view_model_bench_frame(test_reg())
	defer render.held_draw_destroy(&d)
	testing.expect(t, ok)
	testing.expect(t, len(d.view) > 1000, "the biggest model is a few thousand vertices")
}
