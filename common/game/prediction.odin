package game

import "core:math"

// Movement authority, both halves:
//
// Client (Prediction): every tick, the input is numbered, sent and applied
// at once to the predicted state, and kept until the server acknowledges
// it. An Own_Player record gives the server's state after input `acked`; the
// client starts from it and re-applies the inputs still in flight. When the
// two worlds agree that lands exactly where the client already was; when
// they don't (a block the client didn't know about), the difference becomes
// a visual offset that fades over a few frames instead of a jump.
//
// Server (Input_Queue): a jitter buffer feeds the simulation one input per
// tick, so whoever watches a player sees it move a tick's worth per tick.
//  - Depth: `target` inputs are kept waiting (0 to INPUT_TARGET_MAX), grown at
//    once and shrunk one per window from the spread of the client's arrival
//    delays; after the queue ran dry, play resumes once the queue is deeper
//    than the target. A steady client has target 0: input n is applied in the
//    tick it arrives, as the stepped server and the determinism tests expect.
//  - Catch-up: a backlog deeper than target + INPUT_CATCHUP_AT is worked off
//    one extra input per tick (two applied), and only from a budget that
//    refills by one per tick (up to INPUT_BUDGET_MAX) and is spent by every
//    input applied: it is ticks in which nothing was applied, so a client
//    sending faster than the tick rate never moves faster (speed hacks), and
//    one that falls silent does not move at all.
//  - Stall: a backlog past INPUT_STALL_BACKLOG (about 0.4 s behind) is a real
//    stall: the oldest inputs are discarded (not simulated, not merged) down to
//    target + INPUT_CATCHUP_AT, the acknowledgement jumps over them, and the
//    client's reconciliation replays what it still has pending (a correction).

PREDICTION_PENDING :: 128 // inputs in flight (4 seconds at 30 Hz)
INPUT_QUEUE_MAX :: 32
INPUT_BUDGET_MAX :: 4
INPUT_TARGET_MAX :: 3 // deepest jitter buffer: inputs kept waiting
INPUT_CATCHUP_AT :: 2 // backlog beyond the target that is worked off
INPUT_STALL_BACKLOG :: 12 // backlog (inputs) that counts as a real stall
INPUT_WINDOW :: 32 // ticks the arrival spread is measured over
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
	msg := Input {
		sequence = p.next_sequence,
		input    = quantize_input(input),
	}
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
	u: Own_Player,
	rules: ^Rules,
	q: Block_Query,
	mods := MODS_NONE,
	teleported := false, // the state did not come from inputs: no smoothing
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
	if teleported || abs(moved.x) + abs(moved.y) + abs(moved.z) > 4 {
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
	p.error *= f64(math.exp(-CORRECTION_RATE * dt)) // numbers: a visual offset, never state
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
	inputs:        [INPUT_QUEUE_MAX]Input,
	head:          int,
	count:         int,
	budget:        int,
	last:          u32, // the last sequence applied or discarded (acknowledged in Own_Player)
	dropped:       int, // inputs refused: queue full, or out of order
	// The jitter buffer.
	tick:          u32, // input_queue_tick calls (arrival times)
	primed:        bool, // playing; cleared when the queue runs dry
	target:        int, // inputs kept waiting before play resumes
	window_end:    u32,
	delay_min:     i32, // this window's arrival delays (tick - sequence)
	delay_max:     i32,
	seen:          bool, // a delay was taken in this window
	// What the last tick did, and totals (statistics, logged by the server).
	catching_up:   bool, // two inputs were applied
	discarded_now: int, // inputs discarded by a stall this tick
	catchups:      int,
	discarded:     int,
	stalls:        int,
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
	// How late it came against the client's own count: the spread of that
	// over a window is the jitter, and the buffer grows to cover it at once.
	delay := i32(q.tick - msg.sequence)
	if !q.seen {
		q.delay_min, q.delay_max, q.seen = delay, delay, true
	}
	q.delay_min, q.delay_max = min(q.delay_min, delay), max(q.delay_max, delay)
	q.target = max(q.target, min(int(q.delay_max - q.delay_min), INPUT_TARGET_MAX))
	return true
}

// input_queue_tick refills the budget and returns the inputs to apply this
// tick: none while the buffer fills, one, or (catching up) two.
input_queue_tick :: proc(q: ^Input_Queue, out: ^[INPUT_BUDGET_MAX]Input) -> []Input {
	q.tick += 1
	q.catching_up, q.discarded_now = false, 0
	if q.tick >= q.window_end { 	// the window ends: the buffer shrinks a step toward the spread
		if q.seen {q.target = max(min(int(q.delay_max - q.delay_min), INPUT_TARGET_MAX), q.target - 1)}
		q.window_end, q.seen = q.tick + INPUT_WINDOW, false
	}
	q.budget = min(q.budget + 1, INPUT_BUDGET_MAX)
	if q.count == 0 {q.primed = false}
	if !q.primed && q.count > q.target {q.primed = true}
	n := 0
	pop :: proc(q: ^Input_Queue, out: ^[INPUT_BUDGET_MAX]Input, n: ^int) {
		out[n^] = q.inputs[q.head]
		q.head = (q.head + 1) % INPUT_QUEUE_MAX
		q.count -= 1
		q.budget -= 1
		q.last = out[n^].sequence
		n^ += 1
	}
	if q.primed && q.count > 0 && q.budget > 0 {pop(q, out, &n)}
	if q.primed && q.count > q.target + INPUT_CATCHUP_AT && q.budget > 0 {
		pop(q, out, &n)
		q.catching_up = true
		q.catchups += 1
	}
	if q.count > INPUT_STALL_BACKLOG { 	// a real stall: the oldest are given up
		keep := q.target + INPUT_CATCHUP_AT
		q.discarded_now = q.count - keep
		for _ in 0 ..< q.discarded_now {
			q.last = q.inputs[q.head].sequence
			q.head = (q.head + 1) % INPUT_QUEUE_MAX
		}
		q.count = keep
		q.discarded += q.discarded_now
		q.stalls += 1
	}
	return out[:n]
}

// Player_Field names a field of Player_State a Prediction_Check hashes
// separately, so a desync names what differs.
Player_Field :: enum u8 {
	Position,
	Velocity,
	On_Ground,
	Flying,
	Crouched,
	Jump_Held,
	Air_Jumps,
}

@(rodata)
PLAYER_FIELD_NAMES := [Player_Field]string {
	.Position  = "position",
	.Velocity  = "velocity",
	.On_Ground = "on_ground",
	.Flying    = "flying",
	.Crouched  = "crouched",
	.Jump_Held = "jump_held",
	.Air_Jumps = "air_jumps",
}

// player_fields hashes each field of s to 32 bits (hash_value's walk).
player_fields :: proc(s: Player_State) -> (fields: [Player_Field]u32) {
	fold :: proc(v: any) -> u32 {
		h := hasher_make()
		hash_value(&h, v)
		x := hasher_finish(h)
		return u32(x) ~ u32(x >> 32)
	}
	s := s
	fields[.Position] = fold(s.position)
	fields[.Velocity] = fold(s.velocity)
	fields[.On_Ground] = fold(s.on_ground)
	fields[.Flying] = fold(s.flying)
	fields[.Crouched] = fold(s.crouched)
	fields[.Jump_Held] = fold(s.jump_held)
	fields[.Air_Jumps] = fold(s.air_jumps)
	return
}
