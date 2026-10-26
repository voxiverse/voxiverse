package server

// The stepped server (docs/determinism.md): Config.stepped starts no thread and
// no worker, and the caller runs the ticks. Inputs sent on the local pipe
// before a step are handled in that step. A chunk a tick asks for is generated
// inside the request and collected at the start of the next tick, in request
// order. This is the reproducible form of the server: tests, the cross-OS job
// and, later, replay use it.

// step runs one tick on the caller's thread, frees the temp allocator, and
// returns the tick's hash.
step :: proc(s: ^Server) -> State_Hash {
	assert(s.config.stepped, "step needs a stepped server (Config.stepped)")
	tick(s)
	perturb(s) // (into what the tick left: a one-ulp change in a velocity is otherwise absorbed by the next tick's arithmetic)
	hash := state_hash(s)
	free_all(context.temp_allocator)
	return hash
}

// perturb applies Config.perturb to the state its tick leaves: one ulp more.
@(private = "file")
perturb :: proc(s: ^Server) {
	p := s.config.perturb
	if p.what == .None || p.tick != s.tick {return}
	ulp :: proc(x: f32) -> f32 {return transmute(f32)(transmute(u32)x + 1)}
	switch p.what {
	case .None:
	case .Entity_Yaw:
		for w in s.worlds {
			if len(w.entities.list) > 0 {
				e := &w.entities.list[0]
				e.yaw = ulp(e.yaw)
				return
			}
		}
	case .Player_Velocity:
		for &c in s.clients {
			if c.state == .Playing {
				c.player.velocity.x = ulp(c.player.velocity.x)
				return
			}
		}
	}
}
