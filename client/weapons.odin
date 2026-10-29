package client

import "core:math"

import "../common/game"
import "render"
import "ui"

// Hitscan weapons on the client (server/weapons.odin decides everything). The
// client sends "I pulled the trigger" (Shoot) and predicts only effects: the
// tracer and muzzle flash, the shot's sound, the recoil kick and the magazine
// counter. A hit, a kill and the damage are the server's word (Hit_Confirm,
// the inventory's magazine), never guessed here.

RECOIL_KICK :: 0.012 // radians a shot lifts the view (cosmetic: nothing is sent)
RECOIL_DECAY :: 14.0 // a second: how fast it settles
ZOOM_RATE :: 14.0 // a second: how fast the field of view eases
MARKER_SECONDS :: 0.25 // the hit marker stays this long
ARC_SECONDS :: 0.8 // the damage direction on the screen edge
AMMO_HOLD_SECONDS :: 0.5 // a predicted magazine stands this long over the server's word
TRACER_SECONDS :: 0.12

// weapon_in_hand: the weapon in the selected slot, if it is one.
weapon_in_hand :: proc(s: ^Session) -> (stack: game.Stack, w: game.Weapon_Info, ok: bool) {
	stack = held(s)
	if game.stack_empty(stack) {return}
	info, _ := game.item_info(s.reg, stack.item)
	w, ok = info.weapon.?
	return
}

// weapon_ammo: the magazine to show: what we predicted a moment ago, until the
// server's word has had time to arrive.
weapon_ammo :: proc(s: ^Session, stack: game.Stack) -> int {
	if s.weapon_clock < s.ammo_until {return s.ammo_shown}
	return int(stack.ammo)
}

// weapon_reloading: the held weapon is being reloaded.
weapon_reloading :: proc(s: ^Session) -> bool {
	return s.weapon_clock < s.reload_end && s.reload_slot == s.inventory.selected
}

// weapon_tick: once a frame: the timers run down, the field of view eases to
// the held weapon's zoom (use button held) and back.
weapon_tick :: proc(s: ^Session, actions: ^Actions, look: bool, dt: f32) {
	s.weapon_clock += f64(dt)
	s.recoil *= math.exp(-RECOIL_DECAY * dt)
	s.marker = max(s.marker - dt, 0)
	s.hurt_age += dt
	_, w, ok := weapon_in_hand(s)
	want := look && ok && w.zoom > 0 && action_down(actions, .Use)
	if ok && w.zoom > 0 {s.zoom_to = w.zoom}
	s.zoom += clamp(((1.0 if want else 0.0) - s.zoom), -1, 1) * (1 - math.exp(-ZOOM_RATE * dt))
	if s.zoom < 0.001 {s.zoom = 0}
	if s.reload_end != 0 && !weapon_reloading(s) {s.reload_end = 0}
}

// zoom_factor: the field of view's factor now (1: none).
zoom_factor :: proc(s: ^Session) -> f32 {
	return 1 + (s.zoom_to - 1) * s.zoom if s.zoom_to > 0 else 1
}

// weapon_controls: the trigger, the reload key and the zoom's hold, for the
// weapon in hand. false: nothing in hand is a weapon.
weapon_controls :: proc(s: ^Session, a: ^Actions) -> bool {
	stack, w, ok := weapon_in_hand(s)
	if !ok {return false}
	if action_pressed(a, .Reload) {session_reload(s)}
	pressed := action_pressed(a, .Attack)
	if action_down(a, .Attack) && (w.automatic || pressed) {session_shoot(s, stack, w, pressed)}
	return true
}

// session_reload: ask for the held weapon's magazine to be refilled; it takes
// its reload time (the server counts it; moving does not stop it, changing the
// held slot does).
session_reload :: proc(s: ^Session) -> bool {
	stack, w, ok := weapon_in_hand(s)
	if !ok || s.dead || s.state != .Playing || weapon_reloading(s) {return false}
	if weapon_ammo(s, stack) >= w.magazine {return false}
	send_message(s, game.Reload{})
	s.reload_end = s.weapon_clock + f64(w.reload_time)
	s.reload_slot = s.inventory.selected
	vm_event(&s.vm, .Reload, w.reload_time)
	s.ammo_until = 0
	append(&s.sounds, Sound_Event{.Reload, .Air, s.camera.position, 1})
	return true
}

// session_shoot: pull the trigger of the weapon in hand (press: a new press of
// the button; a semi-automatic weapon needs one). The effects are at once; the
// server decides whether there was a shot.
session_shoot :: proc(s: ^Session, stack: game.Stack, w: game.Weapon_Info, press: bool) -> bool {
	if s.dead || s.state != .Playing || weapon_reloading(s) {return false}
	if s.weapon_clock < s.shot_next {return false}
	ammo := weapon_ammo(s, stack)
	if ammo <= 0 {
		if press {session_reload(s)}
		return false
	}
	shoot := game.Shoot {
		after = s.prediction.next_sequence - 1,
		slot  = u8(s.inventory.selected),
		press = press,
		yaw   = s.camera.yaw,
		pitch = s.camera.pitch,
	}
	send_message(s, shoot)
	s.shot_next = s.weapon_clock + f64(1 / w.fire_rate)
	s.ammo_shown, s.ammo_until =
		ammo - 1, s.weapon_clock + AMMO_HOLD_SECONDS + f64(s.net.rtt_ms) / 1000
	s.shots += 1

	// The effects: from the muzzle to what each ray meets (the rays are the
	// server's: the same procedure and seed).
	f := render.forward(s.camera.yaw, s.camera.pitch)
	dir := [3]f64{f64(f.x), f64(f.y), f64(f.z)}
	query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
	right := [3]f64{f64(math.cos(s.camera.yaw)), 0, -f64(math.sin(s.camera.yaw))}
	muzzle := s.camera.position + dir * 0.6 + right * 0.18 - {0, 0.16, 0}
	rays, count := game.pellet_dirs(
		game.shot_seed(s.welcome.player, shoot.after, shoot.slot),
		shoot.yaw,
		shoot.pitch,
		w,
	)
	for i in 0 ..< count {
		end := s.camera.position + rays[i] * f64(w.range)
		if hit, ok := game.raycast(query, s.camera.position, rays[i], f64(w.range)); ok {
			end = hit.point
		}
		tracer(s, muzzle, end)
	}
	muzzle_flash(s, muzzle)
	append(&s.sounds, Sound_Event{gun_cue(w.sound), .Air, s.camera.position, 1})
	s.recoil += RECOIL_KICK * (3 if w.zoom > 0 else 1)
	vm_event(&s.vm, .Shot)
	return true
}

// tracer: a streak of bright specks along the shot, gone in a blink.
tracer :: proc(s: ^Session, from, to: [3]f64) {
	d := to - from
	length := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	if length < 0.5 {return}
	n := clamp(int(length / 0.9), 2, 48)
	for i in 0 ..< n {
		t := (f64(i) + 0.5) / f64(n)
		puff_add(
			s,
			{
				position = from + d * t,
				life = TRACER_SECONDS,
				size = 0.03,
				color = {255, 238, 160, 255},
			},
		)
	}
}

// muzzle_flash: a few hot sparks where the shot leaves.
muzzle_flash :: proc(s: ^Session, at: [3]f64) {
	for i in 0 ..< 4 {
		a := f32(i) * math.TAU / 4
		puff_add(
			s,
			{
				position = at,
				velocity = {math.cos(a) * 1.5, math.sin(a) * 1.5, 0.5},
				life = 0.07,
				size = 0.07,
				drag = 6,
				color = {255, 196, 90, 255},
			},
		)
	}
}

// shot_seen: another player's shot: the tracer and the sound where it began.
shot_seen :: proc(s: ^Session, v: ^game.Shot) {
	tracer(s, v.origin - {0, 0.16, 0}, v.end)
	if s.shot_seen_time == s.weapon_clock &&
	   s.shot_seen_by == v.shooter &&
	   s.shot_seen_at == v.origin {
		return // (a shotgun's other rays: one flash and one sound for the shot)
	}
	s.shot_seen_by, s.shot_seen_at, s.shot_seen_time = v.shooter, v.origin, s.weapon_clock
	muzzle_flash(s, v.origin)
	info, _ := game.item_info(s.reg, v.weapon)
	w, _ := info.weapon.?
	append(&s.sounds, Sound_Event{gun_cue(w.sound), .Air, v.origin, 1})
}

// hit_confirmed: the server says our shot hit: the marker (red on a kill) and
// its sound (another for a headshot).
hit_confirmed :: proc(s: ^Session, v: ^game.Hit_Confirm) {
	s.marker, s.marker_kill, s.marker_head = MARKER_SECONDS, v.kill, v.headshot
	s.confirms += 1
	kind: Sound_Kind = .Hit_Head if v.headshot else .Hit
	append(&s.sounds, Sound_Event{kind, .Air, s.camera.position, 1})
}

// weapon_hud: the magazine beside the hotbar, the hit marker on the crosshair
// and the red arc toward whatever hurt us (all of what F1 hides).
weapon_hud :: proc(ctx: ^ui.Context, s: ^Session) {
	t := &ctx.theme
	c := ui.rect_center(ctx.screen, 0, 0)
	if s.marker > 0 && crosshair_shown(s) {
		color := t.text
		if s.marker_kill {color = {230, 50, 40, 255}}
		color.a = u8(255 * clamp(s.marker / MARKER_SECONDS * 2, 0, 1))
		for step in 0 ..< 3 {
			d := 5 + f32(step) * 4
			for sx in ([2]f32{-1, 1}) {
				for sy in ([2]f32{-1, 1}) {
					ui.fill_rect(ctx, {c.x + sx * d - 1.5, c.y + sy * d - 1.5, 3, 3}, color)
				}
			}
		}
	}
	if s.hurt.known && s.hurt_age < ARC_SECONDS {
		arc_draw(ctx, s)
	}
	stack, w, ok := weapon_in_hand(s)
	if !ok {return}
	if w.zoom > 0 && s.camera_mode == .First {
		scope_draw(ctx, clamp((s.zoom - VM_SCOPE_HIDE * 0.6) / 0.5, 0, 1))
	}
	r := ctx.screen
	row := ui.cut_bottom(&r, SLOT_SIZE.y + 24)
	row = ui.rect_center(row, game.HOTBAR_SLOTS * (SLOT_SIZE.x + t.spacing), SLOT_SIZE.y)
	box := ui.Rect{row.x + row.w + 12, row.y, 120, SLOT_SIZE.y}
	text := tr(.Hud_Reloading) if weapon_reloading(s) else tr(.Hud_Ammo, weapon_ammo(s, stack))
	ui.draw_text(ctx, box, text, t.font_size, t.text, .Left)
}

// arc_draw: a red arc on the screen's edge toward the source of the last hit,
// fading out.
@(private = "file")
arc_draw :: proc(ctx: ^ui.Context, s: ^Session) {
	rel := s.hurt.yaw - s.camera.yaw // (0: ahead; a yaw turns left)
	c := ui.rect_center(ctx.screen, 0, 0)
	rx, ry := ctx.screen.w * 0.5 - 24, ctx.screen.h * 0.5 - 24
	fade := clamp(1 - s.hurt_age / ARC_SECONDS, 0, 1)
	for k in -3 ..= 3 {
		a := rel + f32(k) * 0.09
		x := c.x - math.sin(a) * rx
		y := c.y - math.cos(a) * ry
		size := f32(14 - abs(k) * 2)
		ui.fill_rect(ctx, {x - size / 2, y - size / 2, size, size}, {220, 30, 30, u8(200 * fade)})
	}
}
