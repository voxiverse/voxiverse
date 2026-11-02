package core

import "common:base"
import "common:game"

// The interpreter of statement rules: runs a game.Rule_Program (compiled at load,
// common/game/sim_rules.odin) on one cell. A frame of at most five bound cells (self and the
// picks) on the stack, an explicit stack of the lists and `repeat`s being run, no recursion,
// no loops but `repeat`, and nothing allocated here. Writes go through set_block and
// set_channel like every change, so the journal, the wakes and the clients' updates are the
// engine's.

Rule_Result :: struct {
	changed_self: bool,
	reads:        i32, // cell reads, counted as the compiler's static cost counts them
	writes:       i32, // changes made
	draws:        i32, // draws from the tick stream
}

@(private = "file")
Value :: struct {
	v:  i32,
	ok: bool, // false: it read something that is not loaded (a comparison with it is false)
}

@(private = "file")
Frame :: struct {
	cur:    i32, // the next statement of this list, -1 at its end
	head:   i32, // repeat: the body's first statement
	left:   i32, // repeat: rounds left, this one included
	repeat: bool,
}

@(private = "file")
Run :: struct {
	w:     ^World,
	p:     game.Block_Pos,
	prog:  ^game.Rule_Program,
	cells: [game.RULE_MAX_PICKS + 1]game.Block_Pos,
	res:   Rule_Result,
}

@(private = "file")
cell_pos :: #force_inline proc(r: ^Run, c: game.Rule_Cell) -> game.Block_Pos {
	return r.cells[c.slot] + {i32(c.off.x), i32(c.off.y), i32(c.off.z)}
}

@(private = "file")
compare :: #force_inline proc(op: game.Rule_Cmp, a, b: i32) -> bool {
	switch op {
	case .Eq:
		return a == b
	case .Ne:
		return a != b
	case .Lt:
		return a < b
	case .Le:
		return a <= b
	case .Gt:
		return a > b
	case .Ge:
		return a >= b
	}
	return false
}

@(private = "file")
prop_of :: proc(r: ^Run, b: game.Block, name: string) -> (int, bool) {
	t := &r.w.server.registry.blocks
	return game.prop_index(t, t.type_of[b], name)
}

// eval: the value of a chunk of postfix code (an expression or a condition).
@(private = "file")
eval :: proc(r: ^Run, from, count: i32) -> Value {
	reg := r.w.server.registry
	stack: [32]Value
	sp := 0
	code := r.prog.code[from:from + count]
	i := 0
	for i < len(code) {
		op := code[i]
		i += 1
		switch op.kind {
		case .Lit:
			stack[sp] = {op.value, true}
			sp += 1
		case .Chan:
			v, loaded := chunks_channel(r.w, cell_pos(r, op.cell), int(op.value))
			r.res.reads += game.computed_cost(reg.channels[op.value].computed)
			stack[sp] = {i32(v), loaded}
			sp += 1
		case .Prop:
			b, loaded := chunks_block(&r.w.chunks, cell_pos(r, op.cell))
			r.res.reads += 1
			v := Value{0, false}
			if loaded {
				if pi, found := prop_of(r, b, r.prog.names[op.ref]); found {
					v = {i32(game.state_value(&reg.blocks, b, pi)), true}
				}
			}
			stack[sp] = v
			sp += 1
		case .Index:
			b, loaded := chunks_block(&r.w.chunks, cell_pos(r, op.cell))
			r.res.reads += 1
			at := i32(-1)
			if loaded {
				for x, n in reg.sim.lists[op.ref].blocks {
					if x == b {at = i32(n); break}
				}
			}
			stack[sp] = {at, true}
			sp += 1
		case .Add:
			sp -= 1
			stack[sp - 1] = {stack[sp - 1].v + stack[sp].v, stack[sp - 1].ok && stack[sp].ok}
		case .Sub:
			sp -= 1
			stack[sp - 1] = {stack[sp - 1].v - stack[sp].v, stack[sp - 1].ok && stack[sp].ok}
		case .Cmp:
			sp -= 1
			a, b := stack[sp - 1], stack[sp]
			stack[sp - 1] = {1 if a.ok && b.ok && compare(op.cmp, a.v, b.v) else 0, true}
		case .Is, .Not:
			b, loaded := chunks_block(&r.w.chunks, cell_pos(r, op.cell))
			r.res.reads += 1
			has := loaded && game.rule_matcher_has(&r.prog.matchers[op.ref], b)
			yes := has if op.kind == .Is else loaded && !has
			stack[sp] = {1 if yes else 0, true}
			sp += 1
		case .Loaded:
			_, loaded := chunks_block(&r.w.chunks, cell_pos(r, op.cell))
			r.res.reads += 1
			stack[sp] = {1 if loaded else 0, true}
			sp += 1
		case .Any, .Count:
			m := &r.prog.matchers[op.ref]
			origin := r.p
			n := i32(0)
			for y in i32(op.lo.y) ..= i32(op.hi.y) {
				for z in i32(op.lo.z) ..= i32(op.hi.z) {
					for x in i32(op.lo.x) ..= i32(op.hi.x) {
						b, loaded := chunks_block(&r.w.chunks, origin + {x, y, z})
						if loaded && game.rule_matcher_has(m, b) {n += 1}
					}
				}
			}
			r.res.reads +=
				i32(op.hi.x - op.lo.x + 1) *
				i32(op.hi.y - op.lo.y + 1) *
				i32(op.hi.z - op.lo.z + 1)
			yes := n > 0 if op.kind == .Any else compare(op.cmp, n, op.value)
			stack[sp] = {1 if yes else 0, true}
			sp += 1
		case .And_Jump:
			if stack[sp - 1].v == 0 {i += int(op.value)} else {sp -= 1}
		case .Or_Jump:
			if stack[sp - 1].v != 0 {i += int(op.value)} else {sp -= 1}
		}
	}
	return stack[sp - 1]
}

@(private = "file")
put_block :: proc(r: ^Run, pos: game.Block_Pos, b: game.Block, act: Act) {
	cur, loaded := chunks_block(&r.w.chunks, pos)
	if !loaded || cur == b {return}
	if set_block(r.w, pos, b, act) {
		r.res.writes += 1
		if pos == r.p {r.res.changed_self = true}
	}
}

// rule_run runs the rule's program on the cell p (whose block the rule matched).
rule_run :: proc(w: ^World, p: game.Block_Pos, rule: ^game.Rule, act: Act) -> Rule_Result {
	r := Run {
		w    = w,
		p    = p,
		prog = &rule.program,
	}
	r.cells[0] = p
	reg := w.server.registry
	stmts := rule.program.stmts
	stack: [game.RULE_MAX_STATEMENTS + 8]Frame
	sp := 1
	stack[0] = {
		cur = rule.program.first,
	}
	running := true
	// fail ends the round of the nearest repeat, or the rule.
	fail :: proc(stack: []Frame, sp: ^int) {
		for sp^ > 0 && !stack[sp^ - 1].repeat {sp^ -= 1}
		if sp^ > 0 {stack[sp^ - 1].cur = -1}
	}
	for running && sp > 0 {
		top := &stack[sp - 1]
		if top.cur < 0 {
			if top.repeat && top.left > 1 {
				top.left -= 1
				top.cur = top.head
			} else {
				sp -= 1
			}
			continue
		}
		s := &stmts[top.cur]
		top.cur = s.next
		switch s.kind {
		case .Require:
			if eval(&r, s.code_from, s.code_len).v == 0 {fail(stack[:], &sp)}
		case .Chance:
			r.res.draws += 1
			if base.rng_int_max(&w.tick_rng, int(s.value)) != 0 {fail(stack[:], &sp)}
		case .Pick:
			d: [3]i32
			for k in 0 ..< 3 {
				lo, hi := i32(s.lo[k]), i32(s.hi[k])
				if hi > lo {
					d[k] = i32(base.rng_int_max(&w.tick_rng, int(hi - lo + 1))) + lo
					r.res.draws += 1
				} else {
					d[k] = lo
				}
			}
			r.cells[s.slot] = p + d
		case .Set_Block:
			put_block(&r, cell_pos(&r, s.cell), game.Block(s.value), act)
		case .Set_List:
			idx := eval(&r, s.code_from, s.code_len).v
			blocks := reg.sim.lists[s.ref].blocks
			idx = clamp(idx, 0, i32(len(blocks)) - 1)
			put_block(&r, cell_pos(&r, s.cell), blocks[idx], act)
		case .Set_Prop:
			pos := cell_pos(&r, s.cell)
			cur, loaded := chunks_block(&w.chunks, pos)
			v := eval(&r, s.code_from, s.code_len)
			if loaded {
				if pi, found := prop_of(&r, cur, r.prog.names[s.ref]); found {
					def := &reg.blocks.types[reg.blocks.type_of[cur]]
					n := clamp(v.v, 0, i32(len(def.props[pi].values)) - 1)
					put_block(&r, pos, game.state_with(&reg.blocks, cur, pi, int(n)), act)
				}
			}
		case .Set_Channel:
			pos := cell_pos(&r, s.cell)
			v := eval(&r, s.code_from, s.code_len)
			if _, loaded := chunks_block(&w.chunks, pos); loaded {
				n := clamp(v.v, 0, i32(game.channel_max(reg.channels[s.value])))
				if before, _ := chunks_channel(w, pos, int(s.value)); before != u16(n) {
					if set_channel(w, pos, int(s.value), u16(n), act) {r.res.writes += 1}
				}
			}
		case .Schedule:
			pos := cell_pos(&r, s.cell)
			if _, loaded := chunks_block(&w.chunks, pos); loaded {
				schedule(w, pos, u64(s.value), act.action)
			}
		case .Stop:
			running = false
		case .If:
			head := s.child if eval(&r, s.code_from, s.code_len).v != 0 else s.other
			if head >= 0 {
				stack[sp] = {
					cur = head,
				}
				sp += 1
			}
		case .Repeat:
			if s.child >= 0 {
				stack[sp] = {
					cur    = s.child,
					head   = s.child,
					left   = s.value,
					repeat = true,
				}
				sp += 1
			}
		}
	}
	when ODIN_DEBUG {
		assert(
			r.res.reads <= rule.program.cost,
			"a rule read more cells than its static cost: the cost bound is wrong",
		)
	}
	return r.res
}
