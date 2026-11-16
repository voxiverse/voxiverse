package towers_server

import "core:fmt"

import "common:game"
import "games:towers"
import "server:core"

// The players' pieces: what may be built landed and what it costs (the editing hook,
// before a block is placed or broken), the charge and the refund once it is
// (block_changed), and the towers shooting the creeps in range by themselves.

// Placed: a piece on the field, who built it (its kills are that builder's) and when its
// next shot is due.
Placed :: struct {
	at:    game.Block_Pos,
	piece: towers.Piece,
	owner: core.Player_Ref,
	due:   u64, // the tick it may fire again
}

// piece_of: which piece a block is (false: none).
piece_of :: proc(d: ^Defence, b: game.Block) -> (towers.Piece, bool) {
	for block, p in d.blocks {if block == b {return p, true}}
	return {}, false
}

// editing: a player may place a piece on the build ground (a wall or a tower) if it has
// the coins and the piece leaves every creep a way to the core, and break a piece (it
// pays half back); nothing else is changed by a player.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	d := state(s)
	if d.phase.now == .Results || !d.built {return "Towers: wait for the next run"}
	if new == .Air {
		if _, ok := piece_of(d, old); !ok {return "Towers: only walls and towers are broken"}
		return ""
	}
	p, ok := piece_of(d, new)
	if !ok {return "Towers: only walls and towers are built here"}
	if !towers.buildable(
		at,
	) {return "Towers: build on the field's floor, between the gate and the core"}
	if d.count >= MAX_PIECES {return "Towers: the field holds no more"}
	price := towers.PIECES[p].price
	if have := core.item_count(c, d.coin); have < price {
		return fmt.tprintf(
			"Towers: a %s costs %s; you have %d",
			towers.PIECES[p].name,
			towers.coins_text(price),
			have,
		)
	}
	if shuts(s, at, new) {return "Towers: that would shut the creeps' way to the core"}
	return ""
}

// shuts: a block placed at `at` would leave a creep of some kind with no way (from the
// gate, or from landed it walks).
shuts :: proc(s: ^core.Server, at: game.Block_Pos, block: game.Block) -> bool {
	d := state(s)
	for r in d.routes {if core.route_would_shut(s.home, r, at, block) {return true}}
	return false
}

// block_changed: a piece built is charged to its builder (who could no longer pay, or
// whose piece shut the way after all, has it taken down) and kept; a piece broken is
// paid back half to whoever broke it, and forgotten.
block_changed :: proc(s: ^core.Server, w: ^core.World, change: core.Block_Change) {
	d := state(s)
	if w != s.home || change.bulk {return}
	at := change.area.lo
	if p, was := piece_of(d, change.old); was && change.new == .Air {
		forget(d, at)
		if c := change.by; c != nil && here(s, c) {
			core.item_give(s, c, d.coin, towers.refund(p))
			purse(s, c).spent -= towers.refund(p)
		}
		return
	}
	p, is := piece_of(d, change.new)
	c := change.by
	if !is || c == nil {return}
	price := towers.PIECES[p].price
	act := core.game_act(s, w, .Structure)
	if core.item_count(c, d.coin) < price ||
	   d.count >= MAX_PIECES ||
	   !core.route_reaches(w, d.routes[.Brute], towers.GATE) {
		core.set_block(w, at, .Air, act)
		core.notice(s, c, "Towers: that piece could not stay")
		return
	}
	core.item_take(s, c, d.coin, price)
	purse(s, c).spent += price
	d.pieces[d.count] = {
		at    = at,
		piece = p,
		owner = core.player_ref(s, c),
		due   = s.tick,
	}
	d.count += 1
}

// forget: the piece at `at` is gone.
forget :: proc(d: ^Defence, at: game.Block_Pos) {
	for i in 0 ..< d.count {
		if d.pieces[i].at != at {continue}
		d.pieces[i] = d.pieces[d.count - 1]
		d.count -= 1
		return
	}
}

// towers_fire: every tower whose shot is due fires at the creep in range nearest the
// core (the least way left to walk): an arrow tower hurts it, a cannon's blast hurts
// every creep near landed it lands. The players see each shot (Shot).
towers_fire :: proc(s: ^core.Server) {
	d := state(s)
	w := s.home
	for &t in d.pieces[:d.count] {
		info := towers.PIECES[t.piece]
		if info.range == 0 || s.tick < t.due {continue}
		top := [3]f64{f64(t.at.x) + 0.5, f64(t.at.y) + 1.1, f64(t.at.z) + 0.5}
		target, found := aim(s, top, info.range)
		if !found {continue}
		t.due = s.tick + u64(info.every * f64(game.TICK_RATE))
		landed := core.entity_pos(w, target) + {0, 0.5, 0}
		harm := core.Entity_Harm {
			amount = info.damage,
			kind   = .Game,
			by     = core.player_of(s, t.owner),
		}
		if info.splash > 0 {
			for h in core.entities_of(w, 0, landed, info.splash) {
				if _, creep := creep_of(d, core.entity_kind(w, h));
				   creep {core.entity_harm(w, h, harm)}
			}
		} else {
			core.entity_harm(w, target, harm)
		}
		shot := towers.Shot {
			from  = {f32(top.x), f32(top.y), f32(top.z)},
			to    = {f32(landed.x), f32(landed.y), f32(landed.z)},
			piece = t.piece,
		}
		for &c in s.clients {if here(s, &c) {core.game_event(s, &c, &shot)}}
	}
}

// aim: of the creeps within range of `from`, the one with the least way left to the core.
aim :: proc(
	s: ^core.Server,
	from: [3]f64,
	range: f64,
) -> (
	target: game.Entity_Handle,
	found: bool,
) {
	d := state(s)
	w := s.home
	best := max(f32)
	for h in core.entities_of(w, 0, from, range) {
		k, creep := creep_of(d, core.entity_kind(w, h))
		if !creep {continue}
		p := core.entity_pos(w, h)
		left, has := core.route_cost(w, d.routes[k], {i32(p.x), 0, i32(p.z)})
		if !has {left = max(f32) / 2}
		if left < best {target, best, found = h, left, true}
	}
	return
}
