package client

import "core:testing"

import "common:netcode"

// A lost Ping (or Pong) does not stop the pinging: after PING_GIVE_UP seconds
// without an answer the next ping goes, under a new id.
@(test)
test_ping_after_a_lost_pong :: proc(t: ^testing.T) {
	sim: netcode.Simnet
	s := new(Session)
	defer free(s)
	defer delete(s.writer.buf)
	s.remote, s.state = true, .Playing
	s.link.socket.sim = &sim // (not connected: every ping is lost)
	net_update(s, 1)
	testing.expect(t, s.net.ping_pending)
	testing.expect_value(t, s.net.ping_id, 1)
	for _ in 1 ..< PING_GIVE_UP {net_update(s, 1)}
	testing.expect_value(t, s.net.ping_id, 1)
	net_update(s, 1)
	testing.expect_value(t, s.net.ping_id, 2)
	testing.expect(t, s.net.ping_pending)
}
