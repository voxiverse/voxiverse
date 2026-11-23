package sandbox_server

import "core:log"
import "core:math"
import "core:slice"

import "common:base"
import "common:game"
import "common:worldgen"
import "server:core"

// How each kind of the remains is drawn (remains.odin places them): into a Draft, a template
// over the site's footprint whose cells are void (what stands there stays: the land, the
// trees growing through) until drawn, which knows the land's top at each of its columns; most
// of what is drawn stands on that, sunk a block into it, so a site follows the land as if it
// had settled there. Then it is pasted in one bulk edit, its chests are stocked, and the
// machine it keeps (remain_post) is set down at its post (remains_machines.odin).

// The court: its floor reaches COURT_SIDE blocks beyond the gate's box on either side,
// COURT_BACK behind it (north) and COURT_FRONT in front (south, toward the spawn, which is 8
// or more blocks from the frame: worldgen.home_gate_place); COURT_STEPS rings of steps go
// round it, and its standing stones stand within COURT_REACH of the gate's middle.
COURT_REACH :: 21
COURT_SIDE :: 5
COURT_BACK :: 6
COURT_FRONT :: 2
COURT_STEPS :: 3
COURT_CLEAR :: 12 // blocks cleared over its floor and its cut steps

// Draft: a site's blocks laid out before the paste that builds it (temporary memory).
Draft :: struct {
	t:      game.Template,
	origin: game.Block_Pos,
	ground: []i32, // the land's top at each column (land_at), [x + z * size.x] from the origin
	dry:    []bool, // ... and whether it is dry ground
	chests: [dynamic]game.Block_Pos, // the chests drawn, to stock
}

// draft_make: a draft over the columns `at`, from layer bottom to top, every cell void.
draft_make :: proc(l: ^Land, at: Footprint, bottom, top: i32) -> Draft {
	size := [3]i32{at.hi.x - at.lo.x + 1, top - bottom + 1, at.hi.y - at.lo.y + 1}
	d := Draft {
		t      = game.template_make(size, context.temp_allocator),
		origin = {at.lo.x, bottom, at.lo.y},
		ground = make([]i32, size.x * size.z, context.temp_allocator),
		dry    = make([]bool, size.x * size.z, context.temp_allocator),
		chests = make([dynamic]game.Block_Pos, context.temp_allocator),
	}
	slice.fill(d.t.cells, game.VOID)
	for z in i32(0) ..< size.z {
		for x in i32(0) ..< size.x {
			d.ground[x + z * size.x], d.dry[x + z * size.x] = land_at(l, at.lo.x + x, at.lo.y + z)
		}
	}
	return d
}

// draft_index: column (x, z)'s index in the draft's ground (the nearest column of it, for one
// outside it).
@(private = "file")
draft_index :: proc(d: ^Draft, x, z: i32) -> i32 {
	lx := clamp(x - d.origin.x, 0, d.t.size.x - 1)
	lz := clamp(z - d.origin.z, 0, d.t.size.z - 1)
	return lx + lz * d.t.size.x
}

// draft_ground: the land's top at column (x, z), and whether it is dry ground.
draft_ground :: proc(d: ^Draft, x, z: i32) -> (top: i32, dry: bool) {
	i := draft_index(d, x, z)
	return d.ground[i], d.dry[i]
}

// draft_put: block at p (in the world), if p is within the draft.
draft_put :: proc(d: ^Draft, p: game.Block_Pos, block: game.Block) {
	l := p - d.origin
	if l.x < 0 ||
	   l.y < 0 ||
	   l.z < 0 ||
	   l.x >= d.t.size.x ||
	   l.y >= d.t.size.y ||
	   l.z >= d.t.size.z {
		return
	}
	d.t.cells[game.template_index(&d.t, l)] = u16(block)
}

// draft_column: block from `from` to `to` blocks over the land's top at column (x, z) (0 is
// the top block itself, -1 the one under it).
draft_column :: proc(d: ^Draft, x, z, from, to: i32, block: game.Block) {
	g, _ := draft_ground(d, x, z)
	for y in g + from ..= g + to {draft_put(d, {x, y, z}, block)}
}

// roll: a number in [0, 1) of the site's seed and a cell (and a salt, for another of the same
// cell): what varies block by block.
@(private = "file")
roll :: proc(seed: u64, x, z: i32, salt: u64 = 0) -> f32 {
	return base.unit_f32(base.hash(seed, u64(x), u64(z), salt))
}

// cell: the column whose middle is nearest p.
@(private = "file")
cell :: proc(p: [2]f64) -> [2]i32 {return {i32(math.floor(p.x)), i32(math.floor(p.y))}}

// centre: the middle of column c.
@(private = "file")
centre :: proc(c: [2]i32) -> [2]f64 {return {f64(c.x) + 0.5, f64(c.y) + 0.5}}

// remains_build: one site of the remains, drawn and pasted, its chests stocked and its
// machine kept.
remains_build :: proc(s: ^core.Server, w: ^core.World, site: Remain) {
	k := &state(s).remains_kit
	land := land_of(w)
	act := core.game_act(s, w, .Structure)
	area := remain_area(site)
	d := draft_make(&land, site.at, area.lo.y, area.hi.y)
	rng := base.rng_make(site.seed)
	stacks: [2]int
	switch site.kind {
	case .Court:
		court_level(w, site, area, act)
		court_draw(&d, site, k, &rng)
	case .Road:
		road_draw(&d, site, k)
	case .Pylon:
		pylon_draw(&d, site, k, &rng)
	case .Wall:
		wall_draw(&d, site, k, &rng)
	case .Tower:
		tower_draw(&d, site, k, &rng)
		stacks = {1, 2}
	case .Vault:
		vault_draw(&d, site, k, &rng)
		stacks = {2, 4}
	case .Stones:
		stones_draw(&d, site, k, &rng)
	}
	box := core.Box{d.origin, d.origin + d.t.size - 1}
	core.bulk_edit(w, {shape = box, op = .Paste, template = &d.t, partial = true}, act)
	for p in d.chests {remains_stock(s, w, p, base.rng_roll(&rng, stacks[0], stacks[1]), &rng)}
	if which, at, keeps := remain_post(&d, site); keeps {remains_keep(s, w, which, at)}
	log.infof("remains built kind=%v middle=%v chests=%d", site.kind, site.middle, len(d.chests))
}

// remain_post: the machine a site keeps and its post (its feet), drawn: a sentry folded in
// the cut before a vault's door, and in the middle of a tower that holds a chest; a mender
// beside the plinth of a ring of stones, by a fallen pylon's stump, and on the court's floor
// at the middle of its back row, between the broken pylons' pieces, the court's one machine
// (it never flies into the gate: play's fliers keep out of a gate's surface); none at a wall
// or on the road. The bulwark is the ruin's alone.
remain_post :: proc(d: ^Draft, site: Remain) -> (which: Wild, at: game.Block_Pos, keeps: bool) {
	switch site.kind {
	case .Road, .Wall:
		return
	case .Court:
		return .Tender, court_tender(site), true
	case .Vault:
		p := site.middle + {i32(site.along.x), i32(site.along.y)} * 4
		return .Sentry, {p.x, site.floor + 1, p.y}, true
	case .Tower:
		g, _ := draft_ground(d, site.middle.x, site.middle.y)
		return .Sentry, {site.middle.x, g + 1, site.middle.y}, len(d.chests) > 0
	case .Stones:
		g, _ := draft_ground(d, site.middle.x + 1, site.middle.y)
		return .Tender, {site.middle.x + 1, g + 1, site.middle.y}, true
	case .Pylon:
		foot := centre(site.middle) - site.along * f64(site.size) / 2
		p := cell(foot - site.along * 3)
		g, _ := draft_ground(d, p.x, p.y)
		return .Tender, {p.x, g + 1, p.y}, true
	}
	return
}

// ---- the court ----

// court_of: the court round the home gate (turned as home_gate_place stands it: its plane
// along x), its floor a layer over the gate's platform, so the gate stands a step down in it.
court_of :: proc(l: ^Land, gate: worldgen.Structure) -> Remain {
	site := Remain {
		kind   = .Court,
		middle = {gate.lo.x + worldgen.GATE_SIZE.x / 2, gate.lo.z + 1},
		floor  = gate.lo.y + 1,
	}
	site.at = {site.middle - COURT_REACH, site.middle + COURT_REACH}
	_, site.lo, site.hi, _ = site_ground(l, site.middle.x, site.middle.y, COURT_REACH)
	return site
}

// court_gate: the columns of the gate's box.
court_gate :: proc(site: Remain) -> Footprint {
	lo := site.middle - {worldgen.GATE_SIZE.x / 2, 1}
	return {lo, lo + {worldgen.GATE_SIZE.x, worldgen.GATE_DEPTH} - 1}
}

// court_floor: the columns of the court's floor (the gate's box among them).
court_floor :: proc(site: Remain) -> Footprint {
	g := court_gate(site)
	return {g.lo - {COURT_SIDE, COURT_BACK}, g.hi + {COURT_SIDE, COURT_FRONT}}
}

// court_tender: the post of the court's mender (remain_post), on its floor.
court_tender :: proc(site: Remain) -> game.Block_Pos {
	return {site.middle.x, site.floor + 1, court_floor(site).lo.y + 1}
}

// court_level: the court's floor levelled round the gate's box (which is left as it is).
@(private = "file")
court_level :: proc(w: ^core.World, site: Remain, area: core.Box, act: core.Act) {
	g, c := court_gate(site), court_floor(site)
	strips := [4]Footprint {
		{c.lo, {c.hi.x, g.lo.y - 1}}, // behind
		{{c.lo.x, g.hi.y + 1}, c.hi}, // in front
		{{c.lo.x, g.lo.y}, {g.lo.x - 1, g.hi.y}},
		{{g.hi.x + 1, g.lo.y}, {c.hi.x, g.hi.y}},
	}
	for st in strips {
		box := core.Box {
			{st.lo.x, area.lo.y, st.lo.y},
			{st.hi.x, site.floor + COURT_CLEAR, st.hi.y},
		}
		site_level(w, box, site.floor, act)
	}
}

// court_draw: the court's floor (worn slate tiles, gravel, moss and grass through them), its
// broken parapet open in front of the gate and toward the road, the steps round it to the
// land, its four pylons on plinths with the conduits that ran from them to the gate, and the
// standing stones round it (none to the south, where the spawn looks at the gate).
@(private = "file")
court_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	F := site.floor
	g, c := court_gate(site), court_floor(site)
	seed := site.seed
	mid := centre(site.middle)
	for z in site.at.lo.y ..= site.at.hi.y {
		for x in site.at.lo.x ..= site.at.hi.x {
			if x >= g.lo.x && x <= g.hi.x && z >= g.lo.y && z <= g.hi.y {continue}
			ring := max(c.lo.x - x, x - c.hi.x, c.lo.y - z, z - c.hi.y, 0)
			h := roll(seed, x, z)
			switch {
			case ring == 0 && (x == c.lo.x || x == c.hi.x || z == c.lo.y || z == c.hi.y):
				draft_put(d, {x, F, z}, k.basalt_bricks)
				q := centre({x, z}) - mid
				toward :=
					(q.x * site.along.x + q.y * site.along.y) / math.sqrt(q.x * q.x + q.y * q.y)
				if (z == c.hi.y && abs(x - site.middle.x) <= 3) || toward > 0.97 || h >= 0.6 {
					continue // (a way in, or a break)
				}
				draft_put(
					d,
					{x, F + 1, z},
					k.mossy_bricks if roll(seed, x, z, 1) < 0.3 else k.basalt_bricks,
				)
				if top := roll(seed, x, z, 2); top < 0.15 {
					draft_put(d, {x, F + 2, z}, k.basalt_bricks)
				} else if top < 0.25 {
					draft_put(d, {x, F + 2, z}, k.leaves)
				}
			case ring == 0:
				b := k.slate_tiles
				switch {
				case h < 0.08:
					b = .Gravel
				case h < 0.18:
					b = k.moss
				case h < 0.27:
					b = .Grass
					if plant := roll(seed, x, z, 1); plant < 0.6 {
						draft_put(d, {x, F + 1, z}, .Tall_Grass)
					} else if plant < 0.7 {
						draft_put(d, {x, F + 1, z}, .Poppy)
					}
				case h < 0.31:
					b = k.basalt_cobble
				case h < 0.4:
					b = k.polished_slate
				}
				draft_put(d, {x, F, z}, b)
			case ring <= COURT_STEPS:
				court_step(d, site, x, z, ring, k)
			}
		}
	}
	// The conduits: copper in the floor behind the gate, from the north pylons to its back.
	back := g.lo.y - 2
	for x in c.lo.x + 3 ..= c.hi.x - 3 {draft_put(d, {x, F, back}, k.copper)}
	draft_put(d, {site.middle.x, F, back + 1}, k.copper)
	// The pylons: two flanking the gate, two at the corners behind it; one or two stand whole.
	Pylon_Spot :: struct {
		at:   [2]i32, // the lower corner of its 2 x 2 shaft
		fall: [2]i32, // the way its broken top fell
	}
	pylons := [4]Pylon_Spot {
		{{g.lo.x - 3, g.lo.y}, {0, 1}},
		{{g.hi.x + 2, g.lo.y}, {0, 1}},
		{{c.lo.x + 2, c.lo.y + 1}, {1, 0}},
		{{c.hi.x - 3, c.lo.y + 1}, {-1, 0}},
	}
	whole := [4]bool{}
	for _ in 0 ..< base.rng_roll(rng, 1, 2) {whole[base.rng_int_max(rng, 4)] = true}
	for p, i in pylons {court_pylon(d, F, p.at, p.fall, c, whole[i], k, rng)}
	// The standing stones, on the land round the court.
	radius := f64(base.rng_roll(rng, 18, 20))
	first := base.rng_f64(rng) * math.TAU
	STONES :: 11
	for i in 0 ..< STONES {
		a := first + f64(i) * math.TAU / STONES + base.rng_f64_range(rng, -0.15, 0.15)
		dir := [2]f64{base.cos(a), base.sin(a)}
		fate := base.rng_f32(rng)
		height := base.rng_roll(rng, i32(2), 4)
		if dir.y > 0.7 || fate < 0.3 {continue} 	// (the spawn's side; one gone)
		at := mid + dir * radius
		if fate < 0.5 { 	// fallen, lying inward
			for j in 0 ..< 3 {
				p := cell(at - dir * f64(j))
				if _, dry := draft_ground(d, p.x, p.y);
				   dry {draft_column(d, p.x, p.y, 1, 1, k.slate)}
			}
			continue
		}
		for p in ([2][2]i32{cell(at), cell(at + {-dir.y, dir.x})}) {
			draft_column(d, p.x, p.y, -1, height, k.slate)
			if roll(seed, p.x, p.y, 3) <
			   0.25 {draft_column(d, p.x, p.y, height + 1, height + 1, k.moss)}
		}
	}
}

// court_step: a column of the ring `ring` round the court's floor: where the land is lower, a
// step that far under the floor on the land made up to it; where it is higher, cut to a step
// that far over the floor; where it meets the step, as it is.
@(private = "file")
court_step :: proc(d: ^Draft, site: Remain, x, z, ring: i32, k: ^Remains_Kit) {
	F := site.floor
	land, _ := draft_ground(d, x, z)
	step := k.polished_basalt if ring == 1 else k.basalt_bricks
	switch h := roll(site.seed, x, z, 4); {
	case h < 0.1:
		step = k.moss
	case h < 0.16:
		step = k.basalt_cobble
	}
	switch {
	case land <= F - ring:
		for y in land + 1 ..< F - ring {draft_put(d, {x, y, z}, k.basalt_cobble)}
		draft_put(d, {x, F - ring, z}, step)
		if ring == COURT_STEPS && roll(site.seed, x, z, 5) < 0.05 {
			draft_put(d, {x, F - ring + 1, z}, k.leaves)
		}
	case land >= F + ring:
		draft_put(d, {x, F + ring, z}, step)
		for y in F + ring + 1 ..= F + COURT_CLEAR {draft_put(d, {x, y, z}, .Air)}
	}
}

// court_pylon: a pylon of the court on its plinth: whole, with its grating and its copper cap;
// or broken low, its top lying in pieces on the floor the way it fell (within the floor).
@(private = "file")
court_pylon :: proc(
	d: ^Draft,
	F: i32,
	at, fall: [2]i32,
	floor: Footprint,
	whole: bool,
	k: ^Remains_Kit,
	rng: ^base.Rng,
) {
	for dz in i32(-1) ..= 2 {
		for dx in i32(-1) ..= 2 {draft_put(d, {at.x + dx, F + 1, at.y + dz}, k.polished_basalt)}
	}
	height := base.rng_roll(rng, i32(8), 10) if whole else base.rng_roll(rng, i32(2), 4)
	jag := base.rng_int_max(rng, 4)
	for i in 0 ..< 4 {
		col := at + {i32(i & 1), i32(i >> 1)}
		top := F + 1 + height - (1 if !whole && i == jag else 0)
		for y in F + 2 ..= top {
			b := k.steel
			if (y - F) % 4 == 0 {b = k.rust}
			if whole && y == F + 1 + height / 2 {b = k.grating}
			draft_put(d, {col.x, y, col.y}, b)
		}
		if whole {
			draft_put(d, {col.x, top + 1, col.y}, k.copper)
		} else if i == (jag + 1) % 4 && base.rng_f32(rng) < 0.6 {
			draft_put(d, {col.x, top + 1, col.y}, k.leaves)
		}
	}
	if whole {return}
	// The pieces: two wide, from beyond the plinth along fall, a break among them.
	from := at + fall * (3 if fall.x + fall.y > 0 else 2)
	across := [2]i32{abs(fall.y), abs(fall.x)}
	length := base.rng_roll(rng, 3, 5)
	gap := base.rng_roll(rng, 1, 2)
	for i in 0 ..< length {
		if i == gap {continue}
		for j in i32(0) ..= 1 {
			p := from + fall * i32(i) + across * j
			if p.x <= floor.lo.x || p.x >= floor.hi.x || p.y <= floor.lo.y || p.y >= floor.hi.y {
				continue
			}
			draft_put(d, {p.x, F + 1, p.y}, k.rust if i % 3 == 2 else k.steel)
		}
	}
}

// ---- the scattered remains ----

// road_draw: a stretch of the old road: paving three wide in place of the land's top, with
// tiles gone and gravel and moss in their place, kerbs either side (some a block proud), its
// ends broken off unevenly, a post now and then on alternate sides; nothing on wet ground.
@(private = "file")
road_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit) {
	seed := site.seed
	u := site.along
	v := [2]f64{-u.y, u.x}
	length := f64(site.size)
	a := centre(site.middle) - u * length / 2
	start := f64(roll(seed, 0, 0, 7)) * 2
	end := length - f64(roll(seed, 0, 0, 8)) * 2
	for z in site.at.lo.y ..= site.at.hi.y {
		for x in site.at.lo.x ..= site.at.hi.x {
			q := centre({x, z}) - a
			along, across := q.x * u.x + q.y * u.y, abs(q.x * v.x + q.y * v.y)
			if along < start || along > end || across > 2.5 {continue}
			if _, dry := draft_ground(d, x, z); !dry {continue}
			h := roll(seed, x, z)
			if across <= 1.5 {
				b := k.slate_tiles
				switch {
				case h < 0.12:
					continue // (gone: the grass shows)
				case h < 0.22:
					b = .Gravel
				case h < 0.28:
					b = k.moss
				case h < 0.45:
					b = k.polished_slate
				}
				draft_column(d, x, z, 0, 0, b)
			} else if h >= 0.15 {
				draft_column(d, x, z, 0, 0, k.basalt_bricks)
				if roll(seed, x, z, 1) < 0.4 {draft_column(d, x, z, 1, 1, k.basalt_bricks)}
			}
		}
	}
	side := 1.0 if roll(seed, 0, 0, 9) < 0.5 else -1.0
	for t := 4.0; t < end; t += 12 {
		p := cell(a + u * t + v * side * 3)
		side = -side
		if _, dry := draft_ground(d, p.x, p.y); !dry {continue}
		draft_column(d, p.x, p.y, 0, 2, k.rust)
		if roll(seed, p.x, p.y, 2) < 0.5 {draft_column(d, p.x, p.y, 3, 3, k.copper)}
	}
}

// pylon_draw: a pylon fallen along its way: its stump on a footing, broken off jagged, and
// its shaft lying beyond, two wide and two high, sunk a block into the land and broken in one
// or two places, its copper head at the far end; leaves grown on it here and there.
@(private = "file")
pylon_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	u := site.along
	v := [2]f64{-u.y, u.x}
	length := f64(site.size)
	foot := centre(site.middle) - u * length / 2
	stump := cell(foot - {0.5, 0.5})
	for dz in i32(-1) ..= 2 {
		for dx in i32(-1) ..= 2 {draft_column(d, stump.x + dx, stump.y + dz, 0, 0, k.polished_basalt)}
	}
	height := base.rng_roll(rng, i32(2), 5)
	jag := base.rng_int_max(rng, 4)
	for i in 0 ..< 4 {
		col := stump + {i32(i & 1), i32(i >> 1)}
		top := height - (2 if i == jag else 0)
		for y in i32(1) ..= top {draft_column(d, col.x, col.y, y, y, k.rust if y % 3 == 0 else k.steel)}
	}
	breaks := [2]f64 {
		base.rng_f64_range(rng, 4, length - 3),
		base.rng_f64_range(rng, 4, length - 3),
	}
	two := base.rng_f32(rng) < 0.5
	for t := 3.0; t <= length; t += 0.5 {
		if abs(t - breaks[0]) < 1 || (two && abs(t - breaks[1]) < 1) {continue}
		head := t > length - 2
		width := 1.0 if head else 0.5
		for o := -width; o <= width; o += 0.5 {
			p := cell(foot + u * t + v * o)
			if head {
				draft_column(d, p.x, p.y, 0, 2, k.copper)
				if o == 0 {draft_column(d, p.x, p.y, 1, 1, k.grating)}
				continue
			}
			draft_column(d, p.x, p.y, 0, 1, k.rust if int(t) % 4 == 0 else k.steel)
			if roll(site.seed, p.x, p.y) < 0.12 {draft_column(d, p.x, p.y, 2, 2, k.leaves)}
		}
	}
}

// wall_draw: a wall two thick along its way, its foot a block under the land, standing to a
// height that rises and falls along it (down to a strip of bricks in the grass), a doorway in
// it (a lintel over it where the wall beside stands high enough), pilasters on one face, moss
// and leaves on top; one in two turns a corner at its end into a shorter arm.
@(private = "file")
wall_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	a := [2]i32{i32(site.along.x), i32(site.along.y)}
	across := [2]i32{a.y, a.x}
	phase := base.rng_f64(rng) * math.TAU
	wave := base.rng_f64_range(rng, 0.25, 0.6)
	door := base.rng_roll(rng, i32(2), site.size - 4)
	arm := base.rng_roll(rng, site.size / 3, site.size / 2) if base.rng_f32(rng) < 0.5 else 0
	height :: proc(seed: u64, phase, wave: f64, s: i32) -> i32 {
		h := 1.5 + 2 * base.sin(phase + f64(s) * wave) + f64(roll(seed, s, 0, 6)) * 2 - 1
		return clamp(i32(math.round(h)), 0, 4)
	}
	brick :: proc(seed: u64, k: ^Remains_Kit, x, z, y: i32) -> game.Block {
		switch h := roll(seed, x, z, u64(y + 64)); {
		case h < 0.25:
			return k.mossy_bricks
		case h < 0.4:
			return k.slate_bricks
		}
		return k.basalt_bricks
	}
	start := site.middle - a * (site.size / 2)
	// One run of wall: n blocks from `from` along `way`, two thick toward `thick`.
	run :: proc(
		d: ^Draft,
		site: Remain,
		k: ^Remains_Kit,
		from, way, thick: [2]i32,
		n, door, offset: i32,
		phase, wave: f64,
	) {
		for s in i32(0) ..< n {
			h := height(site.seed, phase, wave, s + offset)
			opening := s >= door && s <= door + 1
			if opening {h = 0}
			for t in i32(0) ..= 1 {
				p := from + way * s + thick * t
				for y in i32(-1) ..= h {draft_column(d, p.x, p.y, y, y, brick(site.seed, k, p.x, p.y, y))}
				if opening {
					draft_column(d, p.x, p.y, 1, 2, .Air)
					lintel :=
						height(site.seed, phase, wave, door - 1 + offset) >= 3 &&
						height(site.seed, phase, wave, door + 2 + offset) >= 3
					if lintel {draft_column(d, p.x, p.y, 3, 3, k.polished_basalt)}
					continue
				}
				switch top := roll(site.seed, p.x, p.y, 1); {
				case h >= 1 && top < 0.2:
					draft_column(d, p.x, p.y, h + 1, h + 1, k.moss)
				case h >= 1 && top < 0.28:
					draft_column(d, p.x, p.y, h + 1, h + 1, k.leaves)
				}
			}
			if s % 5 == 0 && h >= 1 && !opening {
				p := from + way * s - thick
				for y in i32(-1) ..= h + 1 {draft_column(d, p.x, p.y, y, y, k.basalt_bricks)}
			}
		}
	}
	run(d, site, k, start, a, across, site.size, door, 0, phase, wave)
	if arm > 0 {
		corner := start + a * (site.size - 2)
		run(d, site, k, corner + across * 2, across, a, arm, -10, site.size, phase, wave)
	}
}

// tower_draw: a round tower fallen in on its way: its ring of wall standing high on the far
// side and down to its footing on that one, a band of polished stone every fourth course,
// slits and a doorway, a floor of polished slate inside, its rubble spilled on the land
// beyond the fallen side; a chest inside against the far wall in one tower of two.
@(private = "file")
tower_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	R := f64(site.size)
	tall := base.rng_roll(rng, i32(8), 12)
	u := site.along
	v := [2]f64{-u.y, u.x}
	mid := centre(site.middle)
	seed := site.seed
	for z in site.at.lo.y ..= site.at.hi.y {
		for x in site.at.lo.x ..= site.at.hi.x {
			q := centre({x, z}) - mid
			r := math.sqrt(q.x * q.x + q.y * q.y)
			dir := q / max(r, 0.001)
			fell := dir.x * u.x + dir.y * u.y
			h := roll(seed, x, z)
			switch {
			case r < R - 0.5:
				b := k.polished_slate
				if h < 0.15 {b = .Gravel} else if h < 0.3 {b = k.moss}
				draft_column(d, x, z, 0, 0, b)
			case r <= R + 0.5:
				jitter := f64(roll(seed, x, z, 1)) * 3 - 1.5
				top := clamp(i32(f64(tall) * (1 - max(fell, 0) * 1.1) + jitter), 0, tall)
				door := dir.x * v.x + dir.y * v.y > 0.92
				for y in i32(-1) ..= top {
					b := k.basalt_bricks
					switch {
					case door && (y == 1 || y == 2), y == 5 && roll(seed, x, z, 2) < 0.25:
						b = .Air
					case y > 0 && y % 4 == 0:
						b = k.polished_basalt
					case y <= 1 && roll(seed, x, z, u64(y + 8)) < 0.35:
						b = k.mossy_bricks
					}
					draft_column(d, x, z, y, y, b)
				}
				if top >= 2 &&
				   roll(seed, x, z, 3) < 0.25 {draft_column(d, x, z, top + 1, top + 1, k.leaves)}
			case fell > 0.45 && r < R + 8:
				chance := 0.65 * (1 - (f32(r) - f32(R)) / 8)
				if _, dry := draft_ground(d, x, z); !dry || h >= chance {continue}
				rubble := [3]game.Block{k.basalt_cobble, .Gravel, k.basalt_bricks}
				draft_column(d, x, z, 1, 1, rubble[int(roll(seed, x, z, 4) * 3)])
				if r < R + 3 &&
				   roll(seed, x, z, 5) < chance / 2 {draft_column(d, x, z, 2, 2, k.basalt_cobble)}
			}
		}
	}
	if base.rng_f32(rng) < 0.5 {
		p := cell(mid - u * (R - 1.5))
		g, _ := draft_ground(d, p.x, p.y)
		draft_put(d, {p.x, g + 1, p.y}, .Chest)
		append(&d.chests, game.Block_Pos{p.x, g + 1, p.y})
	}
}

// vault_draw: a mound of earth grassed over, standing on the land's middle height, over a
// chamber of riveted iron whose door (dark steel, sealed: one digs in) shows in a cut on the
// mound's way, framed in polished basalt with copper over it; a chest inside.
@(private = "file")
vault_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	M := f64(site.size)
	HIGH :: 6 // the mound over its floor at its middle
	b := site.floor
	u := [2]i32{i32(site.along.x), i32(site.along.y)}
	side := [2]i32{abs(u.y), abs(u.x)}
	mid := centre(site.middle)
	uf := [2]f64{f64(u.x), f64(u.y)}
	sf := [2]f64{f64(side.x), f64(side.y)}
	for z in site.at.lo.y ..= site.at.hi.y {
		for x in site.at.lo.x ..= site.at.hi.x {
			q := centre({x, z}) - mid
			r := math.sqrt(q.x * q.x + q.y * q.y)
			along, across := q.x * uf.x + q.y * uf.y, abs(q.x * sf.x + q.y * sf.y)
			g, _ := draft_ground(d, x, z)
			if along > 2.5 && across <= 2.5 && along <= M + 0.5 { 	// the cut before the door
				for y in g + 1 ..< b {draft_put(d, {x, y, z}, .Stone)}
				draft_put(
					d,
					{x, b, z},
					.Gravel if roll(site.seed, x, z) < 0.3 else k.polished_basalt,
				)
				for y in b + 1 ..= max(g, b + HIGH) {draft_put(d, {x, y, z}, .Air)}
				continue
			}
			if r > M {continue}
			top := b + i32(math.round(HIGH * (1 - (r / M) * (r / M))))
			if top <= g {continue}
			for y in g + 1 ..< top {draft_put(d, {x, y, z}, .Dirt)}
			draft_put(d, {x, top, z}, .Grass)
			if roll(site.seed, x, z, 1) < 0.3 {draft_put(d, {x, top + 1, z}, .Tall_Grass)}
		}
	}
	// The chamber: a shell five wide from the floor up five, three wide and high inside.
	for i in i32(-2) ..= 2 {
		for j in i32(-2) ..= 2 {
			p := site.middle + u * i + side * j
			g, _ := draft_ground(d, p.x, p.y)
			for y in g + 1 ..< b {draft_put(d, {p.x, y, p.y}, .Stone)}
			for y in b ..= b + 4 {
				inside := abs(i) <= 1 && abs(j) <= 1 && y > b && y < b + 4
				block := k.riveted
				switch {
				case inside:
					block = .Air
				case y == b:
					block = k.polished_basalt
				case i == 2 && abs(j) <= 1 && y < b + 4:
					block = k.steel // (the door)
				case i == 2 && y == b + 4 && j == 0:
					block = k.copper
				case i == 2:
					block = k.polished_basalt
				}
				draft_put(d, {p.x, y, p.y}, block)
			}
		}
	}
	p := site.middle - u
	draft_put(d, {p.x, b + 1, p.y}, .Chest)
	append(&d.chests, game.Block_Pos{p.x, b + 1, p.y})
}

// stones_draw: a ring of standing stones (slate or limestone, the seed's), each two wide, a
// block in the land and two to four over it, some gone and some fallen outward; in the middle
// a polished floor and on it a dead plinth of dark steel capped with copper.
@(private = "file")
stones_draw :: proc(d: ^Draft, site: Remain, k: ^Remains_Kit, rng: ^base.Rng) {
	R := f64(site.size)
	limestone := base.rng_f32(rng) < 0.5
	stone := k.limestone if limestone else k.slate
	polished := k.polished_limestone if limestone else k.polished_slate
	mid := centre(site.middle)
	n := base.rng_roll(rng, 7, 11)
	first := base.rng_f64(rng) * math.TAU
	for i in 0 ..< n {
		a := first + f64(i) * math.TAU / f64(n) + base.rng_f64_range(rng, -0.12, 0.12)
		dir := [2]f64{base.cos(a), base.sin(a)}
		fate := base.rng_f32(rng)
		height := base.rng_roll(rng, i32(2), 4)
		at := mid + dir * R
		switch {
		case fate < 0.25: // gone
		case fate < 0.45:
			for j in 0 ..< 3 {
				p := cell(at + dir * f64(j))
				draft_column(d, p.x, p.y, 0, 1 if j == 0 else 0, stone)
			}
		case:
			for p in ([2][2]i32{cell(at), cell(at + {-dir.y, dir.x})}) {
				draft_column(d, p.x, p.y, -1, height, stone)
				if roll(site.seed, p.x, p.y) <
				   0.25 {draft_column(d, p.x, p.y, height + 1, height + 1, k.moss)}
			}
		}
	}
	for dz in i32(-1) ..= 1 {
		for dx in i32(-1) ..= 1 {draft_column(d, site.middle.x + dx, site.middle.y + dz, 0, 0, polished)}
	}
	draft_column(d, site.middle.x, site.middle.y, 1, 1, k.steel)
	draft_column(d, site.middle.x, site.middle.y, 2, 2, k.copper)
}
