package client

import "core:hash"
import "core:math"
import "core:math/linalg"

import "client:render"
import "client:ui"
import "common:game"

// The other players' avatars: boxes in the entity pass (legs, a body that
// turns with them, a head that also looks up and down), a shirt colour
// from their name, and their name above their head.

@(private = "file", rodata)
SHIRTS := [8][4]u8 {
	{196, 64, 52, 255},
	{58, 120, 196, 255},
	{70, 160, 80, 255},
	{214, 168, 52, 255},
	{150, 82, 186, 255},
	{40, 160, 168, 255},
	{214, 110, 46, 255},
	{220, 220, 226, 255},
}
@(private = "file")
LEGS :: [4]u8{52, 58, 92, 255}
AVATAR_SKIN :: [4]u8{224, 178, 140, 255}

NAME_TAG_DISTANCE :: 48 // blocks: names further away are not shown

// shirt_of: a player's colour, the same everywhere for the same name.
shirt_of :: proc(name: string) -> [4]u8 {
	return SHIRTS[hash.fnv32a(transmute([]u8)name) % len(SHIRTS)]
}

// ARMOR_COLORS: what each piece of armor looks like on an avatar (and in
// its icon).
ARMOR_COLORS := [game.Armor][4]u8 {
	.Cap      = {176, 52, 44, 255},
	.Tunic    = {70, 110, 170, 255},
	.Trousers = {96, 74, 54, 255},
	.Boots    = {58, 42, 34, 255},
}

// Avatar_Pose: how the limbs and the body stand (radians about the shoulder
// and hip; the body's heights). Derived from the speed and the sneak flag the
// server replicated, never from what the client guesses.
Avatar_Pose :: struct {
	legs:   [2]f32, // left, right: the swing about the hip
	arms:   [2]f32, // left, right: opposite the legs; the right one raised with an item
	hip:    f32, // the legs' length (sneaking: shorter)
	neck_y: f32, // the shoulders' height
}

AVATAR_MOVING :: 0.3 // blocks/s: below this it stands (replicated positions are not still to the last digit)
AVATAR_FULL_STEP :: 0.8 // blocks/s: the swing is whole from here
AVATAR_WALK_SWING :: 0.55 // radians
AVATAR_RUN_SWING :: 1.0
AVATAR_SNEAK_SWING :: 0.25 // a shortened stride
AVATAR_RAISED :: 1.1 // the arm that holds something: raised forward (positive: the hand swings to the front, -z)
AVATAR_AIMED :: 1.5 // holding a weapon: the arm level, pointing the way it looks

// Hold: what the right hand holds, for the arm's raise.
Hold :: enum u8 {
	None,
	Item, // anything
	Gun, // a weapon: aimed
}

// hold_of: how an item is held (a weapon or a launcher aimed, anything else raised).
hold_of :: proc(reg: ^game.Registry, item: game.Item) -> Hold {
	if item == game.NO_ITEM {return .None}
	info, known := game.item_info(reg, item)
	if !known {return .None}
	if _, is_weapon := info.weapon.?; is_weapon {return .Gun}
	if tool, is_tool := info.tool.?; is_tool && tool == .Launcher {return .Gun}
	return .Item
}

// avatar_pose_advance: the limbs' phase after moving `distance` blocks. The
// phase follows the ground covered, so it is continuous when the speed changes
// and a slow avatar swings slowly; sneaking takes shorter strides.
avatar_pose_advance :: proc(phase, distance: f32, crouched: bool) -> f32 {
	per_block: f32 = 7.0 if crouched else 4.5 // radians of the cycle per block
	return math.mod(phase + distance * per_block, math.TAU)
}

// avatar_pose: the pose at `phase` while going `speed` blocks/s. walk_speed
// and sprint_speed are the world's rules: the swing grows from the walk's to
// the run's between them. At rest every limb is still.
avatar_pose :: proc(
	speed: f32,
	crouched: bool,
	phase: f32,
	hold: Hold,
	walk_speed, sprint_speed: f32,
) -> (
	pose: Avatar_Pose,
) {
	pose.hip, pose.neck_y = 0.75, 1.4
	if crouched {pose.hip, pose.neck_y = 0.6, 1.1}
	raised: f32 = AVATAR_AIMED if hold == .Gun else AVATAR_RAISED
	if speed < AVATAR_MOVING {
		if hold != .None {pose.arms[1] = raised}
		return
	}
	amp: f32 = AVATAR_SNEAK_SWING
	if !crouched {
		run := clamp((speed - walk_speed) / max(sprint_speed - walk_speed, 0.01), 0, 1)
		amp = AVATAR_WALK_SWING + (AVATAR_RUN_SWING - AVATAR_WALK_SWING) * run
	}
	amp *= clamp((speed - AVATAR_MOVING) / (AVATAR_FULL_STEP - AVATAR_MOVING), 0.4, 1)
	swing := math.sin(phase) * amp
	pose.legs = {swing, -swing}
	pose.arms = {-swing, swing}
	if hold != .None {pose.arms[1] = raised + swing * 0.15}
	return
}

// avatar_rest: standing still.
avatar_rest :: proc(crouched: bool) -> Avatar_Pose {
	return avatar_pose(0, crouched, 0, .None, 1, 2)
}

// avatar_hold_pose: standing still, holding `item`.
avatar_hold_pose :: proc(reg: ^game.Registry, crouched: bool, item: game.Item) -> Avatar_Pose {
	return avatar_pose(0, crouched, 0, hold_of(reg, item), 1, 2)
}

// Avatar_Hand: where the item in an avatar's right hand is drawn (nil draw: it is
// not) and what it looks like.
Avatar_Hand :: struct {
	draw:  ^render.Held_Draw,
	entry: ^Held_Entry,
}

// avatars_draw adds every visible other player to the entity pass (their limbs
// move on with the ground they cover each frame).
avatars_draw :: proc(
	s: ^Session,
	d: ^render.Entity_Draw,
	hand_draw: ^render.Held_Draw,
	cache: ^Held_Cache,
) {
	if s.camera_mode != .First {
		// Ourselves, standing.
		avatar_draw(
			s.reg,
			d,
			s.feet,
			s.camera.yaw,
			s.camera.pitch,
			avatar_hold_pose(s.reg, s.prediction.state.crouched, held(s).item),
			shirt_of(s.config.name),
			game.worn_of(&s.inventory),
			{hand_draw, held_entry(cache, s.reg, held(s).item)},
		)
	}
	now, live := session_others_now(s)
	if !live {return}
	for _, &o in s.others {
		v, ok := other_view(&o, now)
		if !ok {continue}
		moved := v.position - o.last_seen
		if o.last_seen != {} {
			o.stride = avatar_pose_advance(
				o.stride,
				f32(math.sqrt(moved.x * moved.x + moved.z * moved.z)),
				v.crouched,
			)
		}
		o.last_seen = v.position
		pose := avatar_pose(
			v.speed,
			v.crouched,
			o.stride,
			hold_of(s.reg, o.held),
			s.rules.walk_speed,
			s.rules.sprint_speed,
		)
		avatar_draw(
			s.reg,
			d,
			v.position,
			v.yaw,
			v.pitch,
			pose,
			shirt_of(o.name),
			o.worn,
			{hand_draw, held_entry(cache, s.reg, o.held)},
		)
	}
}

// avatar_draw adds one avatar standing at p (feet): legs and arms swung as
// the pose says, a body that turns with it, a head that also looks up and
// down, and what it wears.
avatar_draw :: proc(
	reg: ^game.Registry,
	d: ^render.Entity_Draw,
	p: [3]f64,
	yaw, pitch: f32,
	pose: Avatar_Pose,
	shirt: [4]u8,
	worn: [game.WORN_SLOTS]game.Item,
	hand := Avatar_Hand{},
) {
	hip, neck_y := pose.hip, pose.neck_y
	if hand.draw != nil && hand.entry != nil && hand.entry.kind != .None {
		// The item in the right hand: its grip at the hand, the arm's raise as the pose says.
		xf := avatar_hand_matrix(hand.entry.kind, {0.375, neck_y - 0.1, 0}, yaw, pose.arms[1])
		render.held_world_begin(hand.draw, p)
		for v in hand.entry.mesh.vertices {
			at := xf * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
			w := v
			w.pos = {at.x, at.y, at.z}
			render.held_world_add(hand.draw, w)
		}
	}
	leg :: proc(
		d: ^render.Entity_Draw,
		p: [3]f64,
		yaw, swing, hip: f32,
		side, lo, hi, grow: f32,
		color: [4]u8,
	) {
		pivot := p + turn_yaw({side * 0.125, hip, 0}, yaw)
		render.entity_box(
			d,
			pivot,
			yaw,
			swing,
			{-0.125 - grow, lo - hip, -0.125 - grow},
			{0.125 + grow, hi - hip, 0.125 + grow},
			color,
			.Legs,
		)
	}
	for side, i in ([2]f32{-1, 1}) {
		leg(d, p, yaw, pose.legs[i], hip, side, 0, hip, 0, LEGS)
		// An arm hangs from the shoulder: a sleeve, then a hand.
		shoulder := p + turn_yaw({side * 0.375, neck_y - 0.1, 0}, yaw)
		render.entity_box(
			d,
			shoulder,
			yaw,
			pose.arms[i],
			{-0.075, -0.4, -0.075},
			{0.075, 0.1, 0.075},
			shirt,
			.Body,
		)
		render.entity_box(
			d,
			shoulder,
			yaw,
			pose.arms[i],
			{-0.075, -0.65, -0.075},
			{0.075, -0.4, 0.075},
			AVATAR_SKIN,
			.Body,
		)
	}
	render.entity_box(d, p, yaw, 0, {-0.3, hip, -0.15}, {0.3, neck_y, 0.15}, shirt, .Body)
	neck := p + {0, f64(neck_y), 0}
	render.entity_box(
		d,
		neck,
		yaw,
		pitch,
		{-0.24, 0, -0.24},
		{0.24, 0.48, 0.24},
		AVATAR_SKIN,
		.Head,
	)
	// Armor: slightly larger boxes over the parts.
	G :: f32(0.03)
	for item in worn {
		info, known := game.item_info(reg, item)
		armor, is_armor := info.armor.?
		if !known || !is_armor {continue}
		c := ARMOR_COLORS[armor]
		switch armor {
		case .Cap:
			render.entity_box(
				d,
				neck,
				yaw,
				pitch,
				{-0.24 - G, 0.3, -0.24 - G},
				{0.24 + G, 0.48 + G, 0.24 + G},
				c,
				.Body,
			)
		case .Tunic:
			render.entity_box(
				d,
				p,
				yaw,
				0,
				{-0.3 - G, hip + 0.05, -0.15 - G},
				{0.3 + G, neck_y + 0.0, 0.15 + G},
				c,
				.Body,
			)
		case .Trousers:
			for side, i in ([2]f32{-1, 1}) {
				leg(d, p, yaw, pose.legs[i], hip, side, 0.2, hip + 0.08, G, c)
			}
		case .Boots:
			for side, i in ([2]f32{-1, 1}) {
				leg(d, p, yaw, pose.legs[i], hip, side, 0, 0.22, G, c)
			}
		}
	}
}

// name_tags draws the other players' names over their heads.
name_tags :: proc(app: ^App, ctx: ^ui.Context) {
	s := app.session
	w := &app.window
	camera := camera_render(&s.view, w.width, w.height, camera_fov(s, app.settings))
	origin := chunk_origin_f64(camera.chunk)
	t := &ctx.theme
	now, live := session_others_now(s)
	if !live {return}
	for _, &o in s.others {
		v, ok := other_view(&o, now)
		if !ok {continue}
		d := v.position - s.camera.position
		if linalg.length(d) > NAME_TAG_DISTANCE {continue}
		above := v.position + {0, 1.85 if v.crouched else 2.15, 0} - origin
		clip := camera.view_proj * [4]f32{f32(above.x), f32(above.y), f32(above.z), 1}
		if clip.w <= 0.05 {continue} 	// behind the camera
		x := (clip.x / clip.w * 0.5 + 0.5) * f32(w.width) / ctx.scale
		y := (clip.y / clip.w * 0.5 + 0.5) * f32(w.height) / ctx.scale
		width := ui.measure_text(ctx, o.name, t.font_size) + 2 * t.padding
		r := ui.Rect{x - width / 2, y - t.row_height / 2, width, t.row_height}
		ui.fill_rect(ctx, r, {0, 0, 0, 150})
		ui.label(ctx, o.name, r, .Center)
	}
}

@(private = "file")
chunk_origin_f64 :: proc(c: [3]i32) -> [3]f64 {
	return {f64(c.x), f64(c.y), f64(c.z)} * render.CHUNK_EXTENT
}
