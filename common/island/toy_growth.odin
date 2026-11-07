package island

import "common:base"

// Toy_Growth is the toy system that proves the lazy contract: one value per chunk growing
// logistically, dv/dt = RATE v (1 - v / CAPACITY), with a closed form for `lazy_evaluate`.
// An influence adds its amount to the value on the day it arrives.
TOY_RATE :: 0.1 // per day
TOY_CAPACITY :: 100.0
TOY_START :: 1.0 // the value at day 0
TOY_SPEED :: 100.0 // blocks per day

Toy_Growth :: struct {
	values: map[Chunk]f64, // detailed regions only
}

toy_destroy :: proc(t: ^Toy_Growth) {
	delete(t.values)
	t^ = {}
}

// toy_grow: the closed form, `v` after `days` of growth.
toy_grow :: proc(v, days: f64) -> f64 {
	if v <= 0 {return 0}
	e := base.exp(-TOY_RATE * days)
	return TOY_CAPACITY / (1 + (TOY_CAPACITY / v - 1) * e)
}

toy_lazy_evaluate :: proc(
	user: rawptr,
	region: Chunk,
	from: Summary,
	arrived: []Influence,
	day: f64,
) -> State {
	v, at := from.state[0], from.day
	if from.day == 0 && from.state == {} {v = TOY_START}
	for iv in arrived {
		v = min(toy_grow(v, iv.day - at) + iv.amount, TOY_CAPACITY)
		at = iv.day
	}
	return {toy_grow(v, day - at), 0, 0, 0}
}

toy_detail_enter :: proc(user: rawptr, region: Chunk, state: State, day: f64) {
	(^Toy_Growth)(user).values[region] = state[0]
}

// toy_detail_step: the full simulation (explicit steps; the closed form is what it approximates).
toy_detail_step :: proc(user: rawptr, region: Chunk, dt: f64) {
	t := (^Toy_Growth)(user)
	v := t.values[region]
	t.values[region] = v + dt * TOY_RATE * v * (1 - v / TOY_CAPACITY)
}

toy_detail_leave :: proc(user: rawptr, region: Chunk, day: f64) -> Summary {
	t := (^Toy_Growth)(user)
	v := t.values[region]
	delete_key(&t.values, region)
	return {day, {v, 0, 0, 0}}
}

toy_system :: proc(t: ^Toy_Growth) -> Lazy_System {
	return {
		user = t,
		speed_blocks_per_day = TOY_SPEED,
		lazy_evaluate = toy_lazy_evaluate,
		detail_enter = toy_detail_enter,
		detail_step = toy_detail_step,
		detail_leave = toy_detail_leave,
	}
}
