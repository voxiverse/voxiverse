package client

import "core:math"
import "core:math/linalg"

import "render"
import "ui"

// The view model (docs/milestones/M48k.md): the avatar's right arm and what it
// holds, drawn over the world from the camera, in a pass of its own with a
// fixed field of view. Its animations are a pure state (Vm_State) the session
// feeds with events (a swing, a place, a shot, a reload) and steps with the
// frame's time and the comfort settings; nothing animated is sent.
//
// Third person uses the same meshes in the avatar's hand (avatar_hand).

VIEW_MODEL_FOV :: 60 * math.RAD_PER_DEG // vertical; never the FOV setting's
VIEW_MODEL_NEAR :: 0.02

VM_SWING_SECONDS :: 0.28
VM_PLACE_SECONDS :: 0.22
VM_RECOIL_KICK :: 1.0 // added by a shot
VM_RECOIL_CAP :: 2.0 // what an automatic weapon adds up to
VM_RECOIL_DECAY :: 12.0 // a second
VM_SCOPE_HIDE :: 0.25 // the sniper's model is hidden above this much zoom
VM_SWAY_HEIGHT :: 0.004 // blocks
VM_BOB_HEIGHT :: 0.014
VM_BOB_SIDE :: 0.010

Mat4 :: matrix[4, 4]f32

Vm_Event :: enum u8 {
	Swing, // the attack or break button
	Place, // a block placed, something used
	Shot, // a weapon fired (or a rocket)
	Reload, // a reload begins (its time is the weapon's)
}

Vm_State :: struct {
	swing:       f32, // seconds into the swing (0: none)
	place:       f32, // seconds into the place motion (0: none)
	recoil:      f32, // 0 ..= VM_RECOIL_CAP, decaying
	reload_age:  f32, // seconds into the reload
	reload_time: f32, // its length (0: none)
	clock:       f32, // seconds, for the idle sway
}

// Vm_Inputs: what the frame says about the world around the hand.
Vm_Inputs :: struct {
	dt:        f32,
	comfort:   bool, // "View bobbing" on and Reduce motion off: the sway and the bob play
	bob_phase: f32, // the camera's own (s.bob_phase) and amplitude (s.bob_amp)
	bob_amp:   f32,
	zoom:      f32, // 0 ..= 1: how far the held weapon's zoom has come
	zooms:     bool, // the held weapon has a zoom (the sniper)
}

// Vm_Pose: where the hand's item is, as offsets from its rest place (view
// space, radians about the grip), and whether it is hidden.
Vm_Pose :: struct {
	offset: [3]f32,
	pitch:  f32,
	yaw:    f32,
	roll:   f32,
	hidden: bool,
}

vm_event :: proc(vm: ^Vm_State, e: Vm_Event, seconds: f32 = 0) {
	switch e {
	case .Swing:
		vm.swing = 1e-4
	case .Place:
		vm.place = 1e-4
	case .Shot:
		vm.recoil = min(vm.recoil + VM_RECOIL_KICK, VM_RECOIL_CAP)
	case .Reload:
		vm.reload_age, vm.reload_time = 1e-4, max(seconds, 0.1)
	}
}

// vm_reset: another item in hand: no motion carries over.
vm_reset :: proc(vm: ^Vm_State) {
	vm^ = {
		clock = vm.clock,
	}
}

@(private = "file")
smooth :: proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

// vm_update: the timers run on by dt and the pose of this moment.
vm_update :: proc(vm: ^Vm_State, in_: Vm_Inputs) -> (pose: Vm_Pose) {
	vm.clock += in_.dt
	if vm.swing > 0 {
		vm.swing += in_.dt
		if vm.swing >= VM_SWING_SECONDS {vm.swing = 0}
	}
	if vm.place > 0 {
		vm.place += in_.dt
		if vm.place >= VM_PLACE_SECONDS {vm.place = 0}
	}
	if vm.reload_time > 0 {
		vm.reload_age += in_.dt
		if vm.reload_age >= vm.reload_time {vm.reload_age, vm.reload_time = 0, 0}
	}
	vm.recoil *= math.exp(-VM_RECOIL_DECAY * in_.dt)
	if vm.recoil < 0.001 {vm.recoil = 0}

	if in_.zooms && in_.zoom > VM_SCOPE_HIDE {
		pose.hidden = true
	}
	if vm.swing > 0 {
		// An arc down and across: the front dips, the item turns to the left.
		s := math.sin(vm.swing / VM_SWING_SECONDS * math.PI)
		pose.offset += {-0.10, -0.06, -0.08} * s
		pose.pitch -= 0.75 * s
		pose.yaw += 0.55 * s
		pose.roll -= 0.30 * s
	}
	if vm.place > 0 {
		s := math.sin(vm.place / VM_PLACE_SECONDS * math.PI)
		pose.offset += {-0.03, -0.07, -0.10} * s
		pose.pitch -= 0.25 * s
	}
	if vm.recoil > 0 {
		pose.offset += {0, 0.006, 0.05} * vm.recoil
		pose.pitch += 0.09 * vm.recoil
	}
	if vm.reload_time > 0 {
		p := vm.reload_age / vm.reload_time
		f := smooth(0, 0.22, p) * (1 - smooth(0.78, 1, p))
		pose.offset += {0.04, -0.28, 0.02} * f
		pose.pitch -= 0.55 * f
		pose.roll += 0.35 * f
	}
	if in_.comfort {
		pose.offset.x += VM_SWAY_HEIGHT * math.sin(vm.clock * 1.3)
		pose.offset.y += VM_SWAY_HEIGHT * math.sin(vm.clock * 1.9 + 1)
		pose.offset.y += VM_BOB_HEIGHT * in_.bob_amp * math.sin(in_.bob_phase * 2)
		pose.offset.x += VM_BOB_SIDE * in_.bob_amp * math.sin(in_.bob_phase)
	}
	return
}

// vm_animating: some motion is under way (tests).
vm_animating :: proc(vm: ^Vm_State) -> bool {
	return vm.swing > 0 || vm.place > 0 || vm.recoil > 0 || vm.reload_time > 0
}

// --- Placing the hand's item.

mat_translate :: proc(v: [3]f32) -> Mat4 {
	return linalg.matrix4_translate_f32(v)
}

mat_rot :: proc(angle: f32, axis: [3]f32) -> Mat4 {
	return linalg.matrix4_rotate_f32(angle, axis)
}

// held_in_arm: where an item sits in the arm's own space (the shoulder at the
// origin, the arm along -y, its hand at -0.65): the grip in the hand, the
// item's front along the arm's length. A gun or a block points the way the arm
// does, a flat item's diagonal runs along it with its picture facing outward.
held_in_arm :: proc(kind: Held_Kind) -> Mat4 {
	hand := mat_translate({0, -0.55, 0})
	switch kind {
	case .Flat:
		return hand * mat_rot(math.PI / 2, {0, 1, 0}) * mat_rot(1.25 * math.PI, {0, 0, 1})
	case .Block, .Model, .None:
	}
	return hand * mat_rot(-math.PI / 2, {1, 0, 0})
}

// view_rest: where the item's grip rests in view space (before any
// animation), by kind. Camera at the origin, looking down -z.
view_rest :: proc(kind: Held_Kind) -> Mat4 {
	switch kind {
	case .Model:
		return mat_translate({0.29, -0.24, -0.72}) * mat_rot(0.05, {0, 1, 0})
	case .Block:
		return mat_translate({0.36, -0.30, -0.88}) * mat_rot(0.6, {0, 1, 0})
	case .Flat:
		return mat_translate({0.33, -0.25, -0.78}) * mat_rot(0.25, {1, 0, 0})
	case .None:
	}
	return mat_translate({0.36, -0.46, -0.40}) * mat_rot(-0.30, {1, 0, 0})
}

// view_pose_matrix: the item's place in view space with the animation's pose:
// the offsets, then the rotations about the grip.
view_pose_matrix :: proc(kind: Held_Kind, pose: Vm_Pose) -> Mat4 {
	return(
		mat_translate(pose.offset) *
		view_rest(kind) *
		mat_rot(pose.roll, {0, 0, 1}) *
		mat_rot(pose.yaw, {0, 1, 0}) *
		mat_rot(pose.pitch, {1, 0, 0}) \
	)
}

// view_arm_matrix: the arm that carries the item at `item` (the item's grip is
// the hand): the arm's space to view space. An empty hand has no item: the
// arm's place is the rest place itself.
view_arm_matrix :: proc(kind: Held_Kind, item: Mat4) -> Mat4 {
	if kind == .None {return item}
	// The arm comes up from below: turned about the grip so its far end sinks.
	return item * mat_rot(VIEW_ARM_SINK, {1, 0, 0}) * linalg.inverse(held_in_arm(kind))
}

VIEW_ARM_SINK :: 0.85 // radians

// held_transform appends mesh to out, moved by m.
held_transform :: proc(out: ^[dynamic]render.Held_Vertex, m: ^Held_Mesh, xf: Mat4) {
	for v in m.vertices {
		p := xf * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
		w := v
		w.pos = {p.x, p.y, p.z}
		append(out, w)
	}
}

// view_model_projection: the view model's own: a fixed field of view, the
// window's aspect, nothing else (not the FOV setting, the sprint's widening or
// the zoom).
view_model_projection :: proc(aspect: f32) -> Mat4 {
	return render.perspective_reverse_z(VIEW_MODEL_FOV, aspect, VIEW_MODEL_NEAR)
}

// view_model_shown: whether the view model is drawn at all.
view_model_shown :: proc(mode: Camera_Mode, hud_hidden: bool, pose: Vm_Pose) -> bool {
	return mode == .First && !hud_hidden && !pose.hidden
}

// view_model_add: the arm and the item in view space for this frame.
view_model_add :: proc(
	d: ^render.Held_Draw,
	kind: Held_Kind,
	item: ^Held_Mesh,
	arm: ^Held_Mesh,
	pose: Vm_Pose,
) {
	xf := view_pose_matrix(kind, pose)
	held_transform(&d.view, arm, view_arm_matrix(kind, xf))
	if kind != .None {held_transform(&d.view, item, xf)}
}

// --- Third person.

// avatar_hand_matrix: an avatar's held item in its own space (the avatar's feet
// at the origin, turned by yaw): the shoulder, the arm's raise and the item's
// grip in the hand.
avatar_hand_matrix :: proc(kind: Held_Kind, shoulder: [3]f32, yaw, arm_pitch: f32) -> Mat4 {
	return(
		mat_rot(yaw, {0, 1, 0}) *
		mat_translate(shoulder) *
		mat_rot(arm_pitch, {1, 0, 0}) *
		held_in_arm(kind) \
	)
}

// --- The sniper's scope.

SCOPE_ALPHA :: 235

// scope_draw: a scope's view on the UI layer while a zoomed weapon is held
// and zoomed in: black outside a circle, thin cross lines inside, faded in
// with the zoom.
scope_draw :: proc(ctx: ^ui.Context, zoom: f32) {
	if zoom <= 0.02 {return}
	fade := clamp(zoom, 0, 1)
	r := ctx.screen
	cx, cy := r.x + r.w / 2, r.y + r.h / 2
	radius := min(r.w, r.h) * 0.46
	black := [4]u8{0, 0, 0, u8(f32(SCOPE_ALPHA) * fade)}
	STEP :: f32(4)
	for y := r.y; y < r.y + r.h; y += STEP {
		dy := y + STEP / 2 - cy
		if abs(dy) >= radius {
			ui.fill_rect(ctx, {r.x, y, r.w, STEP}, black)
			continue
		}
		half := math.sqrt(radius * radius - dy * dy)
		ui.fill_rect(ctx, {r.x, y, cx - half - r.x, STEP}, black)
		ui.fill_rect(ctx, {cx + half, y, r.x + r.w - cx - half, STEP}, black)
	}
	line := [4]u8{0, 0, 0, u8(200 * fade)}
	ui.fill_rect(ctx, {cx - radius, cy - 0.75, radius * 2, 1.5}, line)
	ui.fill_rect(ctx, {cx - 0.75, cy - radius, 1.5, radius * 2}, line)
}
