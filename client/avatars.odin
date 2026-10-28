package client

import "core:hash"
import "core:math/linalg"

import "../common/game"
import "render"
import "ui"

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
@(private = "file")
SKIN :: [4]u8{224, 178, 140, 255}

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

// avatars_draw adds every visible other player to the entity pass.
avatars_draw :: proc(s: ^Session, d: ^render.Entity_Draw) {
	if s.camera_mode != .First {
		// Ourselves, standing (animations are next tier).
		avatar_draw(
			s.reg,
			d,
			s.feet,
			s.camera.yaw,
			s.camera.pitch,
			s.prediction.state.crouched,
			shirt_of(s.config.name),
			game.worn_of(&s.inventory),
		)
	}
	now, live := session_others_now(s)
	if !live {return}
	for _, &o in s.others {
		v, ok := other_view(&o, now)
		if !ok {continue}
		avatar_draw(s.reg, d, v.position, v.yaw, v.pitch, v.crouched, shirt_of(o.name), o.worn)
	}
}

// avatar_draw adds one avatar standing at p (feet): legs, a body that turns
// with it, a head that also looks up and down, and what it wears.
avatar_draw :: proc(
	reg: ^game.Registry,
	d: ^render.Entity_Draw,
	p: [3]f64,
	yaw, pitch: f32,
	crouched: bool,
	shirt: [4]u8,
	worn: [game.WORN_SLOTS]game.Item,
) {
	// Sneaking: shorter legs and body, the head lower (1.5 tall).
	hip, neck_y: f32 = 0.75, 1.4
	if crouched {hip, neck_y = 0.6, 1.1}
	render.entity_box(d, p, yaw, 0, {-0.25, 0, -0.125}, {0.25, hip, 0.125}, LEGS, .Legs)
	render.entity_box(d, p, yaw, 0, {-0.3, hip, -0.15}, {0.3, neck_y, 0.15}, shirt, .Body)
	neck := p + {0, f64(neck_y), 0}
	render.entity_box(d, neck, yaw, pitch, {-0.24, 0, -0.24}, {0.24, 0.48, 0.24}, SKIN, .Head)
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
			render.entity_box(
				d,
				p,
				yaw,
				0,
				{-0.25 - G, 0.2, -0.125 - G},
				{0.25 + G, hip + 0.08, 0.125 + G},
				c,
				.Legs,
			)
		case .Boots:
			render.entity_box(
				d,
				p,
				yaw,
				0,
				{-0.25 - G, 0, -0.125 - G},
				{0.25 + G, 0.22, 0.125 + G},
				c,
				.Legs,
			)
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
