package sandbox_server

import "common:game"
import "server:core"
import "server:play"

// The ancient remains' machines (wild.odin's Sentry, Tender, Watcher and Bulwark): they
// are the remains' own. The ruined site posts its own when it is built (ruin_posts): a
// sentry folded at each corner of its apron, two menders and the guardian kneeling before
// its north gate, each a machine kept with the world, put back if it is not at its post
// the next time the ruin is built in a session. Watchers come by themselves (their spawn
// rule), but only within REMAINS_WATCHED blocks of remains the sandbox knows: the ruin's
// middle (once it is placed) and any marked (remains_mark). Nothing here touches a gate: no
// machine wakes, opens or walks into one, and their shots carve nothing.
//
// The remains round the home gate (remains.odin) take machines the same way: each site but
// the road's stretches is marked once it is built (remains_site), so watchers come near it,
// and keeps the one machine its drawing posts (remain_post: a sentry at a vault and at a
// tower with a chest, a tender at a ring of stones, a fallen pylon and behind the gate),
// set down once as its ground is built (remains_keep). No sentry keeps a post within
// remains_safe of the world's spawn, and a world whose creatures do not come by themselves
// (scenes, benchmarks, checks) gets none of them: a mender's flight would differ from one
// picture to the next.

MAX_MARKED :: MAX_REMAINS // remains marked in the home world: the sites round the gate at most (the
// ruin is known without)
REMAINS_WATCHED :: 96 // blocks from remains within which a watcher comes
REMAINS_AT_POST :: 3 // blocks from its post within which a machine is at it

// Remains_Post: a machine of the remains and its post, from the ruin's corner (local x, z
// on its floor).
Remains_Post :: struct {
	which: Wild,
	at:    [2]i32,
}

// RUIN_POSTS: the ruined site's machines: the sentries on the corners of its apron, the
// menders by two of its walls, the guardian before its north gate (the south gate is where
// the ruin puts players out).
RUIN_POSTS :: [?]Remains_Post {
	{.Sentry, {-2, -2}},
	{.Sentry, {RUIN_SIDE + 1, -2}},
	{.Sentry, {-2, RUIN_SIDE + 1}},
	{.Sentry, {RUIN_SIDE + 1, RUIN_SIDE + 1}},
	{.Tender, {RUIN_MID - 6, -2}},
	{.Tender, {RUIN_MID + 6, RUIN_SIDE + 1}},
	{.Bulwark, {RUIN_MID, -3}},
}

// remains_mark: remains of the home world whose middle is `at`: watchers come within
// REMAINS_WATCHED blocks of it. Marking the same place again does nothing; past
// MAX_MARKED, false.
remains_mark :: proc(s: ^core.Server, at: [3]f64) -> bool {
	g := state(s)
	for p in g.marked[:g.marked_count] {if p == at {return true}}
	if g.marked_count == MAX_MARKED {return false}
	g.marked[g.marked_count] = at
	g.marked_count += 1
	return true
}

// remains_near: p in w is within radius blocks (across) of remains the sandbox knows (the
// home world's alone).
remains_near :: proc(s: ^core.Server, w: ^core.World, p: [3]f64, radius: f64) -> bool {
	if w != s.home {return false}
	if r := ruin_of(s); r.placed && play.distance_to(p, ruin_middle(r.site)) <= radius {
		return true
	}
	g := state(s)
	for at in g.marked[:g.marked_count] {
		if play.distance_to(p, at) <= radius {return true}
	}
	return false
}

// remains_post: a machine of the remains at its post, block at (its feet), asleep there if
// it is one that sleeps, kept with the world; one of its kind already within
// REMAINS_AT_POST blocks of the post is left as it is (0: none was set down).
remains_post :: proc(
	s: ^core.Server,
	w: ^core.World,
	which: Wild,
	at: game.Block_Pos,
) -> game.Entity_Handle {
	kind := state(s).wild[which]
	post := play.place_point(at)
	if len(core.entities_of(w, kind, post, REMAINS_AT_POST)) > 0 {return 0}
	h := core.entity_spawn(w, kind, post, false)
	if h != 0 {wild_begin(s, w, which, h)}
	return h
}

// ruin_posts: the ruined site's machines at their posts (RUIN_POSTS: ruin_build).
ruin_posts :: proc(s: ^core.Server, w: ^core.World) {
	site := ruin_of(s).site
	posts := RUIN_POSTS
	for p in posts {
		remains_post(
			s,
			w,
			p.which,
			{site.origin.x + p.at.x, site.floor + 1, site.origin.z + p.at.y},
		)
	}
}

// remains_site: a site round the gate built (remains_build), or found built as the plan is
// made: marked, unless a stretch of the road, and humming if it holds what still hums
// (remains_hum).
remains_site :: proc(s: ^core.Server, site: Remain) {
	if site.kind == .Road {return}
	remains_mark(s, {f64(site.middle.x) + 0.5, f64(site.floor) + 1, f64(site.middle.y) + 0.5})
	if k := remains_hum(site); k > 0 {
		core.world_hum(s.home, {site.middle.x, site.floor + 1, site.middle.y}, k)
	}
}

// remains_keep: the machine a site round the gate keeps, set down at its post as the site is
// built: none in a world whose creatures do not come by themselves, and no sentry within
// remains_safe blocks (across) of the world's spawn (0: none was set down).
remains_keep :: proc(
	s: ^core.Server,
	w: ^core.World,
	which: Wild,
	at: game.Block_Pos,
) -> game.Entity_Handle {
	if s.config.no_natural_spawns {return 0}
	if which == .Sentry || which == .Bulwark {
		d := play.place_point(at) - w.spawn.position
		if d.x * d.x + d.z * d.z < remains_safe(s) * remains_safe(s) {return 0}
	}
	return remains_post(s, w, which, at)
}

// remains_safe: blocks from the world's spawn (across) kept free of the remains' hostile
// machines: the most that a predator's spawn rule keeps free of predators (its `safe`).
remains_safe :: proc(s: ^core.Server) -> f64 {
	g := state(s)
	groups := WILD_GROUPS
	widest := 0
	for group in groups {
		if group.name != "predators" {continue}
		for which in group.kinds {
			if rule, has := game.kind_info(s.registry, g.wild[which]).spawn.?; has {
				widest = max(widest, rule.safe)
			}
		}
	}
	return f64(widest)
}
