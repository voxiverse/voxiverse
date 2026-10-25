package game

import "core:math"

// Movement authority, both halves:
//
// Client (Prediction): every tick, the input is numbered, sent and applied
// at once to the predicted state, and kept until the server acknowledges
// it. A Player_Update gives the server's state after input `acked`; the
// client starts from it and re-applies the inputs still in flight. When the
// two worlds agree that lands exactly where the client already was; when
// they don't (a block the client didn't know about), the difference becomes
// a visual offset that fades over a few frames instead of a jump.
//
// Server (Input_Queue): inputs are applied one per tick against a budget
// that refills by one per tick (up to INPUT_BUDGET_MAX, to absorb network
// jitter): a client sending inputs faster than the tick rate does not move
// faster (speed hacks), and one that falls silent does not move at all.

PREDICTION_PENDING :: 128 // inputs in flight (4 seconds at 30 Hz)
INPUT_QUEUE_MAX :: 32
INPUT_BUDGET_MAX :: 4
TICK_SECONDS :: f32(1) / TICK_RATE

Prediction :: struct {
	pending:       [PREDICTION_PENDING]Input, // ring, oldest first from head
	head, count:   int,
	next_sequence: u32,
	state:         Player_State, // predicted, after the last input
	previous:      Player_State, // one tick earlier: render interpolates between them
	error:         [3]f64, // visual offset left by corrections; decays
	corrections:   int, // reconciliations that moved the player (statistics)
}

prediction_init :: proc(p: ^Prediction, state: Player_State) {
	p^ = {
		state         = state,
		previous      = state,
		next_sequence = 1,
	}
}

// prediction_tick applies one tick of input locally and returns the
// message to send.
prediction_tick :: proc(
	p: ^Prediction,
	input: Player_Input,
	rules: ^Rules,
	q: Block_Query,
	mods := MODS_NONE,
) -> Input {
	msg := Input{p.next_sequence, quantize_input(input)}
	p.next_sequence += 1
	if p.count == PREDICTION_PENDING { 	// the server is very far behind: forget the oldest
		p.head = (p.head + 1) % PREDICTION_PENDING
		p.count -= 1
	}
	p.pending[(p.head + p.count) % PREDICTION_PENDING] = msg
	p.count += 1
	p.previous = p.state
	player_step(&p.state, msg.input, rules, q, TICK_SECONDS, mods)
	return msg
}

// prediction_reconcile applies the server's word on the player.
prediction_reconcile :: proc(
	p: ^Prediction,
	u: Player_Update,
	rules: ^Rules,
	q: Block_Query,
	mods := MODS_NONE,
) {
	for p.count > 0 && sequence_before_or_at(p.pending[p.head].sequence, u.acked) {
		p.head = (p.head + 1) % PREDICTION_PENDING
		p.count -= 1
	}
	s := u.state
	for i in 0 ..< p.count {
		player_step(
			&s,
			p.pending[(p.head + i) % PREDICTION_PENDING].input,
			rules,
			q,
			TICK_SECONDS,
			mods,
		)
	}
	moved := p.state.position - s.position
	if u.teleported || abs(moved.x) + abs(moved.y) + abs(moved.z) > 4 {
		p.error = {} // a jump this big is not a correction to smooth
		p.previous = s
	} else if moved != {} {
		p.error += moved
		p.corrections += 1
	}
	p.state = s
}

// prediction_view is where to draw the player alpha (0..1) of the way
// through the current tick, including the fading correction.
prediction_view :: proc(p: ^Prediction, alpha: f32) -> [3]f64 {
	a := f64(clamp(alpha, 0, 1))
	return p.previous.position + (p.state.position - p.previous.position) * a + p.error
}

// prediction_decay fades the correction offset (call once per frame).
prediction_decay :: proc(p: ^Prediction, dt: f32) {
	CORRECTION_RATE :: 15 // 1/s: mostly gone in about 0.2 s
	p.error *= f64(math.exp(-CORRECTION_RATE * dt))
	if abs(p.error.x) + abs(p.error.y) + abs(p.error.z) < 1e-4 {p.error = {}}
}

// sequence_before_or_at compares sequence numbers, allowing wraparound.
sequence_before_or_at :: proc(a, b: u32) -> bool {
	return i32(a - b) <= 0
}

// sequence_before: a comes strictly before b (allowing wraparound).
sequence_before :: proc(a, b: u32) -> bool {
	return i32(a - b) < 0
}

Input_Queue :: struct {
	inputs:  [INPUT_QUEUE_MAX]Input,
	head:    int,
	count:   int,
	budget:  int,
	last:    u32, // the last sequence applied (acknowledged in Player_Update)
	dropped: int, // inputs refused: queue full, or out of order
}

// input_queue_push accepts the next input; false if it was refused (full,
// or not newer than what came before).
input_queue_push :: proc(q: ^Input_Queue, msg: Input) -> bool {
	newest := q.last
	if q.count > 0 {newest = q.inputs[(q.head + q.count - 1) % INPUT_QUEUE_MAX].sequence}
	if q.count == INPUT_QUEUE_MAX || (newest != 0 && sequence_before_or_at(msg.sequence, newest)) {
		q.dropped += 1
		return false
	}
	q.inputs[(q.head + q.count) % INPUT_QUEUE_MAX] = msg
	q.count += 1
	return true
}

// input_queue_tick refills the budget and returns the inputs to apply this
// tick (at most the budget).
input_queue_tick :: proc(q: ^Input_Queue, out: ^[INPUT_BUDGET_MAX]Input) -> []Input {
	q.budget = min(q.budget + 1, INPUT_BUDGET_MAX)
	n := 0
	for q.count > 0 && q.budget > 0 && n < len(out) {
		out[n] = q.inputs[q.head]
		q.head = (q.head + 1) % INPUT_QUEUE_MAX
		q.count -= 1
		q.budget -= 1
		q.last = out[n].sequence
		n += 1
	}
	return out[:n]
}
