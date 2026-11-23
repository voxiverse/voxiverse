package dedicated

import "core:testing"

import "common:game"
import "common:netcode"
import "server:core"

// Both scenarios' players get in, as they do over UDP (here on the stepped
// harness's network): a scenario that cannot join measures nothing. The
// sandbox's own pack is offered to every joiner; bots that ignored the offer
// waited in the pack phase until the benchmark gave up on them.
@(test)
test_bench_players_join :: proc(t: ^testing.T) {
	for party in ([]bool{false, true}) {
		h := new(core.Harness)
		defer free(h)
		config := bench_config(party)
		config.save_dir = "" // (a test keeps nothing)
		if !testing.expect(t, core.harness_start(h, config)) {return}
		bots := bots_make(core.harness_address(h).port, h.srv.registry, party, h.net.now, &h.net)
		core.harness_add(h, proc(data: rawptr) {
				bots := (^[BENCH_BOTS]Bot)(data)
				pump(bots[:], netcode.link_now(&bots[0].link))
			}, bots)
		_, joined := core.harness_step_until(
			h,
			proc(data: rawptr) -> bool {return all_flying((^[BENCH_BOTS]Bot)(data)[:])},
			bots,
			BENCH_JOIN_TIMEOUT * game.TICK_RATE,
		)
		testing.expectf(t, joined, "party=%v: the players joined", party)
		testing.expect(t, core.harness_stop(h))
		bots_destroy(bots)
	}
}
