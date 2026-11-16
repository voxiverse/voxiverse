package hamlet_server

import "core:fmt"

import "common:game"
import "games:hamlet"
import "server:core"

// The citizens: cheap walkers the game steers along its roads (core.entity_glide: the
// roads are known to be walkable, so no physics), one entity each. A citizen lives in a
// house, works at a workplace with a free job, and goes round: home, work (a shift),
// the storehouse with what it made, home (a rest). Every day each eats; the hungry and
// the unhappy leave. New ones arrive while there are homes with water and food.

Citizen_State :: enum u8 {
	Home, // resting at home (timer: steps left)
	To_Work,
	Working, // timer: steps left of the shift
	To_Store,
	To_Home,
	Visiting, // out of work: off to the market (or the storehouse) and back
}

Citizen :: struct {
	id:        u32, // its entity (0: the slot is free)
	home:      int, // its house's structure
	job:       int, // its workplace's (-1: none)
	state:     Citizen_State,
	timer:     int,
	at:        [2]i32, // the road tile it stands on (or last left)
	goal:      [2]i32, // the road tile it is going to
	carrying:  int, // goods of its job's kind
	hungry:    int, // days in a row without food
	happiness: int,
}

// citizen_point: where a citizen stands on road tile p (its feet).
citizen_point :: proc(t: ^Town, p: [2]i32) -> [3]f64 {
	return {f64(p.x) + 0.5, f64(hamlet.ground_top(&t.ground, p.x, p.y) + 1), f64(p.y) + 0.5}
}

// citizen_spawn: a citizen of house `home` standing at road tile p; its slot (-1: no
// room, or the world is full).
citizen_spawn :: proc(s: ^core.Server, home: int, p: [2]i32) -> int {
	t := state(s)
	for &c, i in t.citizens {
		if c.id != 0 {continue}
		h := core.entity_spawn(s.home, t.citizen_kind, citizen_point(t, p), false)
		if h == 0 {return -1}
		core.entity_set_speed(s.home, h, hamlet.WALK_SPEED)
		c = {
			id        = core.entity_id(s.home, h),
			home      = home,
			job       = -1,
			at        = p,
			state     = .Home,
			timer     = hamlet.REST_STEPS,
			happiness = 60,
		}
		t.structures[home].people += 1
		t.population += 1
		return i
	}
	return -1
}

// citizen_leave: a citizen leaves the village: its entity goes, its home and job are free.
citizen_leave :: proc(s: ^core.Server, i: int) {
	t := state(s)
	c := &t.citizens[i]
	if c.id == 0 {return}
	if h, ok := core.entity_find(s.home, c.id); ok {core.entity_gone(s.home, h)}
	if c.home >= 0 && t.structures[c.home].used {t.structures[c.home].people -= 1}
	if c.job >= 0 && t.structures[c.job].used {t.structures[c.job].workers -= 1}
	c^ = {}
	t.population -= 1
}

// go_to: the citizen sets out along the roads for road tile goal; false when there is
// no way (it stays where it is).
go_to :: proc(s: ^core.Server, i: int, goal: [2]i32) -> bool {
	t := state(s)
	c := &t.citizens[i]
	tiles, ok := way(t, c.at, goal)
	if !ok {return false}
	c.goal = goal
	return glide(s, i, tiles)
}

// glide: the entity along the tiles: the points where the way turns or climbs (at most
// a path's worth; the rest after it arrives).
glide :: proc(s: ^core.Server, i: int, tiles: [][2]i32) -> bool {
	t := state(s)
	c := &t.citizens[i]
	h, ok := core.entity_find(s.home, c.id)
	if !ok {return false}
	points := make([dynamic]game.Block_Pos, 0, 32, context.temp_allocator)
	height :: proc(t: ^Town, p: [2]i32) -> i32 {return hamlet.ground_top(&t.ground, p.x, p.y) + 1}
	for p, k in tiles {
		if k == 0 && len(tiles) > 1 {continue}
		last := k == len(tiles) - 1
		if !last {
			prev, next := tiles[k - 1] if k > 0 else c.at, tiles[k + 1]
			straight := next - p == p - prev
			if straight &&
			   height(t, prev) == height(t, p) &&
			   height(t, next) == height(t, p) {continue}
		}
		append(&points, game.Block_Pos{p.x, height(t, p), p.y})
		if len(points) == 32 {break}
	}
	return core.entity_glide(s.home, h, points[:])
}

// arrived: the citizen's entity has reached its goal (glided again for the next part of
// a long way when it stopped short).
arrived :: proc(s: ^core.Server, i: int) -> bool {
	t := state(s)
	c := &t.citizens[i]
	h, ok := core.entity_find(s.home, c.id)
	if !ok || !core.entity_arrived(s.home, h) {return false}
	p := core.entity_pos(s.home, h)
	c.at = {i32(p.x), i32(p.z)}
	if c.at == c.goal {return true}
	if !go_to(s, i, c.goal) {return true} 	// (the road went: it is where it is)
	return false
}

// nearest_store: a storehouse it can reach from road tile p (the nearest by its middle).
nearest_store :: proc(t: ^Town, p: [2]i32) -> (goal: [2]i32, ok: bool) {
	return nearest_of(t, p, .Storehouse)
}

// nearest_of: the way in of the structure of a kind nearest road tile p (by its middle).
nearest_of :: proc(t: ^Town, p: [2]i32, kind: hamlet.Kind) -> (goal: [2]i32, ok: bool) {
	best := max(i32)
	for &st, k in t.structures[:t.count] {
		if !st.used || st.kind != kind {continue}
		a := structure_access(t, k) or_continue
		c := center(&st)
		d := abs(c.x - p.x) + abs(c.y - p.y)
		if d < best {best, goal, ok = d, a, true}
	}
	return
}

// citizen_step: one step of a citizen's round.
citizen_step :: proc(s: ^core.Server, i: int) {
	t := state(s)
	c := &t.citizens[i]
	switch c.state {
	case .Home:
		c.timer -= 1
		if c.timer > 0 {return}
		c.timer = hamlet.REST_STEPS
		if c.job < 0 {job_find(s, i)}
		if c.job < 0 {
			// Out of work, it goes for a walk: to the market, or the storehouse.
			if goal, ok := nearest_of(t, c.at, .Market); ok && go_to(s, i, goal) {
				c.state = .Visiting
			} else if goal2, ok2 := nearest_of(t, c.at, .Storehouse); ok2 && go_to(s, i, goal2) {
				c.state = .Visiting
			}
			return
		}
		if goal, ok := structure_access(t, c.job); ok && go_to(s, i, goal) {
			c.state = .To_Work
		}
	case .To_Work:
		if arrived(s, i) {c.state, c.timer = .Working, hamlet.WORK_STEPS}
	case .Working:
		c.timer -= 1
		if c.timer > 0 {return}
		if c.job >= 0 {
			if makes := hamlet.KINDS_INFO[t.structures[c.job].kind].makes; makes != .None {
				c.carrying = hamlet.CARRY + (1 if makes == .Food else 0)
				if goal, ok := nearest_store(t, c.at); ok && go_to(s, i, goal) {
					c.state = .To_Store
					return
				}
				c.carrying = 0 // (no storehouse to take it to: it is wasted)
			}
		}
		go_home(s, i)
	case .To_Store:
		if !arrived(s, i) {return}
		if c.job >= 0 {
			makes := hamlet.KINDS_INFO[t.structures[c.job].kind].makes
			t.stock[makes] += c.carrying
			t.delivered[makes] += c.carrying
		}
		c.carrying = 0
		go_home(s, i)
	case .To_Home:
		if arrived(s, i) {c.state, c.timer = .Home, hamlet.REST_STEPS}
	case .Visiting:
		if arrived(s, i) {go_home(s, i)}
	}
}

go_home :: proc(s: ^core.Server, i: int) {
	t := state(s)
	c := &t.citizens[i]
	if goal, ok := structure_access(t, c.home); ok && go_to(s, i, goal) {
		c.state = .To_Home
		return
	}
	c.state, c.timer = .Home, hamlet.REST_STEPS
}

// job_find: a workplace with a free job that the citizen can reach from its home.
job_find :: proc(s: ^core.Server, i: int) {
	t := state(s)
	c := &t.citizens[i]
	for &st, k in t.structures[:t.count] {
		if !st.used || st.workers >= hamlet.KINDS_INFO[st.kind].jobs {continue}
		goal := structure_access(t, k) or_continue
		if _, ok := way(t, c.at, goal); !ok {continue}
		st.workers += 1
		c.job = k
		return
	}
}

// day_end: every citizen eats one food; one who finds none goes hungry. Each one's
// happiness is worked out; the hungry two days running, and the very unhappy, leave.
day_end :: proc(s: ^core.Server) {
	t := state(s)
	t.day += 1
	total, counted := 0, 0
	for &c, i in t.citizens {
		if c.id == 0 {continue}
		if t.stock[.Food] > 0 {
			t.stock[.Food] -= 1
			c.hungry = 0
		} else {
			c.hungry += 1
		}
		h := 40
		h += -35 if c.hungry > 0 else 25
		if c.job >= 0 {h += 10}
		if market_near(t, c.home) {h += 20}
		if !watered(t, c.home) {h -= 25}
		c.happiness = clamp(h, 0, 100)
		if c.hungry >= 2 || c.happiness < 20 {
			citizen_leave(s, i)
			continue
		}
		total += c.happiness
		counted += 1
	}
	t.happiness = total / counted if counted > 0 else 60
}

// arrive: a new citizen comes when a house with water has a free home, there is food,
// and the village is not unhappy.
arrive :: proc(s: ^core.Server) {
	t := state(s)
	if t.stock[.Food] <= 0 || (t.population > 0 && t.happiness < 40) {return}
	for &st, k in t.structures[:t.count] {
		if !st.used || st.kind != .House || st.people >= hamlet.KINDS_INFO[.House].homes {continue}
		if !watered(t, k) {continue}
		door := structure_access(t, k) or_continue
		if citizen_spawn(s, k, door) < 0 {return}
		for t.milestone < len(hamlet.MILESTONES) &&
		    t.population >= hamlet.MILESTONES[t.milestone] {
			reached := hamlet.Milestone{u16(hamlet.MILESTONES[t.milestone])}
			for &cl in s.clients {if cl.state == .Playing {core.game_event(s, &cl, &reached)}}
			core.announce(
				s,
				fmt.tprintf("&aHamlet has %d people!&r", hamlet.MILESTONES[t.milestone]),
			)
			t.milestone += 1
		}
		return
	}
}

// grow: a house grows on zoned land when homes are wanted (few free ones left), the
// stock has its materials, and a square of zoned tiles touches a road on even ground.
grow :: proc(s: ^core.Server) {
	t := state(s)
	free := 0
	for &st, k in t.structures[:t.count] {
		if st.used && st.kind == .House && watered(t, k) {
			free += hamlet.KINDS_INFO[.House].homes - st.people
		}
	}
	if free >= 3 || !hamlet.can_afford(t.stock, hamlet.KINDS_INFO[.House].cost) {return}
	size := hamlet.footprint(.House, 0)
	for z in i32(0) ..< hamlet.MAP - size.y + 1 {
		for x in i32(0) ..< hamlet.MAP - size.x + 1 {
			if t.tiles[z][x] != .Zone {continue}
			floor, refusal := fit(s, .House, {x, z}, 0, {.Zone})
			if refusal != "" {continue}
			if structure_add(s, .House, {x, z}, 0, floor) < 0 {return}
			for n, g in hamlet.KINDS_INFO[.House].cost {t.stock[g] -= n}
			return
		}
	}
}
