package tests

import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

import "../common/netcode"

// The real thing under the netcode: UDP on the loopback, the OS's clock.
// netcode's own tests run the same host and link over a Simnet; these two
// check only that the OS sockets carry it.

@(private = "file")
loopback :: proc(port: int) -> net.Endpoint {
	return {net.IP4_Loopback, port}
}

// A link connects to a host over real UDP, a message goes each way, and a
// goodbye is heard at once.
@(test)
test_a_link_and_a_host_talk_over_udp :: proc(t: ^testing.T) {
	h: netcode.Host
	if !testing.expect(t, netcode.host_open(&h, 0, 4) == nil) {return}
	defer netcode.host_close(&h, "bye")
	l: netcode.Link
	testing.expect(
		t,
		netcode.link_connect(&l, loopback(h.socket.port), "", time.tick_now()) == nil,
	)
	peer: netcode.Peer_Id
	connected, left: bool
	at_host, at_link: [dynamic][]u8
	defer {
		for m in at_host {delete(m)}
		for m in at_link {delete(m)}
		delete(at_host)
		delete(at_link)
	}
	sent := false
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		now := time.tick_now()
		netcode.link_update(&l, now)
		netcode.host_update(&h, now)
		for e in h.events {
			switch v in e {
			case netcode.Peer_Connected:
				peer, connected = v.peer, true
			case netcode.Peer_Message:
				append(&at_host, slice.clone(v.data))
			case netcode.Peer_Disconnected:
				left = true
			}
		}
		if l.state == .Connected {netcode.link_receive(&l, &at_link)}
		if connected && l.state == .Connected && !sent {
			netcode.link_send(&l, transmute([]u8)string("hello server"), true)
			netcode.host_send(&h, peer, transmute([]u8)string("hello client"), true)
			sent = true
		}
		if len(at_host) == 1 && len(at_link) == 1 && !left {
			netcode.link_close(&l, "leaving")
		}
		if left {break}
		netcode.host_flush(&h, now)
		netcode.link_flush(&l, now)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, left, "the goodbye never reached the host")
	if testing.expect_value(t, len(at_host), 1) {
		testing.expect_value(t, string(at_host[0]), "hello server")
	}
	if testing.expect_value(t, len(at_link), 1) {
		testing.expect_value(t, string(at_link[0]), "hello client")
	}
}

// A host is found on the LAN by a broadcast.
@(test)
test_lan_discovery_over_udp :: proc(t: ^testing.T) {
	h: netcode.Host
	port := netcode.DEFAULT_PORT + netcode.DISCOVERY_PORTS - 1 // the last one looked at: unlikely to be in use
	if err := netcode.host_open(&h, port, 4); err != nil {
		testing.expectf(t, false, "port %d busy: %v", port, err)
		return
	}
	defer netcode.host_close(&h, "bye")
	netcode.host_set_info(&h, transmute([]u8)string("Test World"))
	d: netcode.Discovery
	if !testing.expect(t, netcode.discovery_open(&d) == nil) {return}
	defer netcode.discovery_close(&d)
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for len(d.found) == 0 && time.tick_diff(time.tick_now(), deadline) > 0 {
		now := time.tick_now()
		netcode.discovery_update(&d, now)
		netcode.host_update(&h, now)
		time.sleep(5 * time.Millisecond)
	}
	if testing.expect(t, len(d.found) == 1, "no server found on the LAN") {
		testing.expect_value(t, string(d.found[0].info), "Test World")
		testing.expect_value(t, d.found[0].address.port, port)
	}
}
