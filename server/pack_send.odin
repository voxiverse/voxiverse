package server

import "core:fmt"
import "core:log"
import "core:strings"

import "../common/game"

// Sending packs (the Packs phase of joining, M47b): after a remote client's
// Proof the server lists the universe's packs (not the base pack), the client
// asks for those it lacks, and the parts go out in order, at most
// PACK_SEND_PER_TICK bytes a tick to a client. A pack is never sent in the
// middle of a session. A client on the local pipe has the universe's packs
// already (it reads the same directory), so it skips the phase.

Pack_Blob :: struct {
	namespace: string,
	version:   string,
	data:      []u8, // the archive (game.pack_archive_make)
	sha256:    [32]u8,
}

// pack_blobs_make: the archives of every pack after the base pack in
// sources (kept for the run: the packs are fixed while the universe runs).
pack_blobs_make :: proc(s: ^Server, sources: []game.Pack_Source) {
	for src, i in sources {
		if i == 0 {continue}
		data := game.pack_archive_make(src)
		version := ""
		for p in s.registry.packs {
			if p.namespace == src.namespace {version = p.version}
		}
		append(
			&s.pack_blobs,
			Pack_Blob {
				strings.clone(src.namespace),
				strings.clone(version),
				data,
				game.pack_hash(data),
			},
		)
	}
}

pack_blobs_destroy :: proc(s: ^Server) {
	for b in s.pack_blobs {
		delete(b.namespace)
		delete(b.version)
		delete(b.data)
	}
	delete(s.pack_blobs)
}

// packs_begin: a proved remote client enters the phase when there is
// anything to send.
@(private)
packs_begin :: proc(s: ^Server, c: ^Client) -> bool {
	if _, local := c.link.(Local); local || len(s.pack_blobs) == 0 {return false}
	msg := game.Packs {
		content = s.registry.hash,
		count   = u8(len(s.pack_blobs)),
	}
	for b, i in s.pack_blobs {
		msg.entries[i] = {b.namespace, b.version, u32(len(b.data)), b.sha256}
	}
	c.state = .Packing
	c.pack_since = s.tick
	c.pack_asked = false
	send_message(s, c, msg)
	return true
}

// pack_want: the client's answer: queue what it asks for.
@(private)
pack_want :: proc(s: ^Server, c: ^Client, w: game.Pack_Want) {
	if c.state != .Packing || c.pack_asked {
		disconnect(s, c, "unexpected pack request")
		return
	}
	for i in 0 ..< int(w.count) {
		idx := w.indices[i]
		if int(idx) >= len(s.pack_blobs) || (i > 0 && idx <= w.indices[i - 1]) {
			disconnect(s, c, "that pack request is not in order or names a pack there is not")
			return
		}
		c.pack_queue[i] = idx
	}
	c.pack_asked = true
	c.pack_count = int(w.count)
	c.pack_next = 0
	c.pack_offset = 0
}

// pack_ready: the client built its registry: it must be ours.
@(private)
pack_ready :: proc(s: ^Server, c: ^Client, r: game.Packs_Ready) -> bool {
	if c.state != .Packing || !c.pack_asked || c.pack_next < c.pack_count {
		disconnect(s, c, "unexpected packs ready")
		return false
	}
	if r.content != s.registry.hash {
		disconnect(
			s,
			c,
			fmt.tprintf(
				"your game built different content from the same packs (content %016x vs %016x)",
				r.content,
				s.registry.hash,
			),
		)
		return false
	}
	return true
}

// packs_tick sends the next parts to every client in the phase, and drops one
// that has been in it too long.
@(private)
packs_tick :: proc(s: ^Server) {
	for &c in s.clients {
		if c.state != .Packing {continue}
		if s.tick - c.pack_since > game.PACK_JOIN_SECONDS * game.TICK_RATE {
			disconnect(s, &c, "joining took too long (the packs did not arrive)")
			continue
		}
		budget := game.PACK_SEND_PER_TICK
		for budget > 0 && c.pack_next < c.pack_count {
			blob := s.pack_blobs[c.pack_queue[c.pack_next]]
			n := min(game.MAX_PACK_PART, len(blob.data) - int(c.pack_offset), budget)
			send_message(
				s,
				&c,
				game.Pack_Part {
					c.pack_queue[c.pack_next],
					c.pack_offset,
					blob.data[c.pack_offset:][:n],
				},
				reliable = true,
			)
			budget -= n
			c.pack_offset += u32(n)
			if int(c.pack_offset) == len(blob.data) {
				c.pack_next += 1
				c.pack_offset = 0
				log.infof("server pack sent player=%d pack=%s", player_id(s, &c), blob.namespace)
			}
		}
	}
}
