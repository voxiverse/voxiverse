package netcode

import "core:log"
import "core:mem"
import "core:net"
import "core:slice"
import "core:time"

// An in-memory datagram network on a clock its owner moves (docs/determinism.md,
// "The harness"): no socket, no thread, no wall clock. A Socket opened with
// `sim` is one port on it. Hosts and links run over it unchanged; only
// delivery and the clock differ. A Simnet has no lock: its owner runs every
// party on one thread.

Simnet :: struct {
	now:        time.Tick, // the network's clock: advanced by its owner, never read from the OS
	conditions: Conditions, // what every packet sent on it meets (seed: never 0)
	ports:      [dynamic]Sim_Port, // bound, in the order bound
	next_port:  int, // the next port given to a socket that asks for any
	sent:       int, // datagrams handed to the network
	delivered:  int, // ... put in an inbox
	unbound:    int, // ... sent to a port nobody holds (dropped, as UDP does)
	overflowed: int, // ... dropped because the inbox held SIM_INBOX_MAX
	allocator:  mem.Allocator,
}

Sim_Port :: struct {
	port:  int,
	inbox: [dynamic]Sim_Packet, // arrived, oldest first
}

Sim_Packet :: struct {
	from: net.Endpoint,
	data: []u8, // owned by the network until received
}

SIM_FIRST_PORT :: 50000
SIM_INBOX_MAX :: 4096
SIM_EPOCH_NS :: 1_000 * i64(time.Second) // tick 0's time
SIMNET_DEFAULT_SEED :: 0x5eed_0002

simnet_init :: proc(
	n: ^Simnet,
	conditions := Conditions{},
	allocator := context.allocator,
	loc := #caller_location,
) {
	n^ = {
		now        = time.Tick{SIM_EPOCH_NS},
		conditions = conditions,
		next_port  = SIM_FIRST_PORT,
		allocator  = allocator,
	}
	if n.conditions.seed == 0 {n.conditions.seed = SIMNET_DEFAULT_SEED}
	n.ports = make([dynamic]Sim_Port, allocator, loc)
}

// simnet_destroy frees what nobody received.
simnet_destroy :: proc(n: ^Simnet) {
	for &p in n.ports {
		for pk in p.inbox {delete(pk.data, n.allocator)}
		delete(p.inbox)
	}
	delete(n.ports)
	n^ = {}
}

// simnet_set_conditions applies from the next send on.
simnet_set_conditions :: proc(n: ^Simnet, c: Conditions) {
	n.conditions = c
	if n.conditions.seed == 0 {n.conditions.seed = SIMNET_DEFAULT_SEED}
}

// simnet_tick_time is the time of tick `tick` at `rate` ticks a second, in
// integers: `rate` ticks are exactly one second.
simnet_tick_time :: proc(tick: u64, rate: int) -> time.Tick {
	return time.Tick{SIM_EPOCH_NS + i64(tick) * i64(time.Second) / i64(rate)}
}

@(private)
sim_bind :: proc(n: ^Simnet, port: int) -> (bound: int, err: net.Network_Error) {
	p := port
	if p == 0 {
		p = n.next_port
		n.next_port += 1
	}
	for q in n.ports {
		if q.port == p {return 0, net.Bind_Error.Address_In_Use}
	}
	append(&n.ports, Sim_Port{port = p})
	return p, nil
}

@(private)
sim_unbind :: proc(n: ^Simnet, port: int) {
	for &q, i in n.ports {
		if q.port != port {continue}
		for pk in q.inbox {delete(pk.data, n.allocator)}
		delete(q.inbox)
		ordered_remove(&n.ports, i)
		return
	}
}

@(private)
sim_deliver :: proc(n: ^Simnet, from: net.Endpoint, to: net.Endpoint, data: []u8) {
	n.sent += 1
	for &q in n.ports {
		if q.port != to.port {continue}
		if len(q.inbox) >= SIM_INBOX_MAX {
			if n.overflowed ==
			   0 {log.warnf("simnet: the inbox of port %d is full; dropping", to.port)}
			n.overflowed += 1
			return
		}
		append(&q.inbox, Sim_Packet{from, slice.clone(data, n.allocator)})
		n.delivered += 1
		return
	}
	n.unbound += 1
}

@(private)
sim_take :: proc(n: ^Simnet, port: int) -> (pk: Sim_Packet, ok: bool) {
	for &q in n.ports {
		if q.port != port {continue}
		if len(q.inbox) == 0 {return}
		return pop_front(&q.inbox), true
	}
	return
}
