package steam_common

import "core:dynlib"
import "core:path/filepath"
import "core:strings"

// What the client's and the server's Steam packages share (docs/platforms.md, "Steam"): the
// SteamID, the run-time loading of the Steamworks library from beside the executable, and
// the fake's ticket scheme (one source of truth for both fakes). Nothing here links against
// Steamworks and no SDK file is committed: the library is opened by name at run time.

Steam_ID :: distinct u64

// INVALID_ID: what an unavailable Steam reports.
INVALID_ID :: Steam_ID(0)

// FAKE_ACCOUNT_BASE: an individual account in the public universe: the SteamID64 of
// account number 0. The fake's IDs are this plus the account number.
FAKE_ACCOUNT_BASE :: u64(76561197960265728)

// MAX_TICKET: the most bytes an auth ticket holds (Steamworks' own limit is 1024).
MAX_TICKET :: 1024

// ERROR_LEN: Steamworks writes its init error text into a buffer this long (SteamErrMsg).
ERROR_LEN :: 1024

// library_name: the file Steamworks ships as on this operating system.
library_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "steam_api64.dll"
	} else when ODIN_OS == .Darwin {
		return "libsteam_api.dylib"
	} else {
		return "libsteam_api.so"
	}
}

// library_open loads the library from `dir` (the executable's folder); never from the
// system's search path, so a stray copy elsewhere is not picked up. Not ok when it is not
// there or does not load.
library_open :: proc(dir: string) -> (lib: dynlib.Library, ok: bool) {
	path, err := filepath.join({dir, library_name()}, context.temp_allocator)
	if err != nil {return}
	return dynlib.load_library(path)
}

// symbol: the address of the first of `names` the library exports (the flat API's versioned
// accessors change names between SDK versions; callers list those they accept).
symbol :: proc(lib: dynlib.Library, names: ..string) -> rawptr {
	for name in names {
		if p, found := dynlib.symbol_address(lib, name); found {return p}
	}
	return nil
}

// error_text: the text Steamworks left in an error buffer, up to its first zero.
error_text :: proc(buf: ^[ERROR_LEN]u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 {n += 1}
	return strings.string_from_ptr(&buf[0], n)
}

// The fake's tickets: "FAKE", the SteamID, a nonce and a check over both. A real server
// refuses them (it has never issued one) and the fake server refuses a real ticket (no
// "FAKE"): a ticket validates only against the fake it came from.
FAKE_TICKET_LEN :: 4 + 8 + 4 + 8

@(private)
FAKE_MAGIC :: [4]u8{'F', 'A', 'K', 'E'}

@(private)
fake_check :: proc(id: Steam_ID, nonce: u32) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 0x100000001b3}
	h = mix(h, u64(id))
	h = mix(h, u64(nonce))
	return mix(h, 0x5eed_f00d)
}

// fake_id: the fake's SteamID for account number n.
fake_id :: proc(n: u32) -> Steam_ID {return Steam_ID(FAKE_ACCOUNT_BASE + u64(n))}

// fake_ticket_make writes a ticket for id into buf (at least FAKE_TICKET_LEN long) and
// returns its length; 0 when buf is too short.
fake_ticket_make :: proc(buf: []u8, id: Steam_ID, nonce: u32) -> int {
	if len(buf) < FAKE_TICKET_LEN {return 0}
	m := FAKE_MAGIC
	copy(buf[0:4], m[:])
	put :: proc(dst: []u8, v: u64, n: int) {
		for i in 0 ..< n {dst[i] = u8(v >> (8 * u64(i)))}
	}
	put(buf[4:12], u64(id), 8)
	put(buf[12:16], u64(nonce), 4)
	put(buf[16:24], fake_check(id, nonce), 8)
	return FAKE_TICKET_LEN
}

// fake_ticket_check: the SteamID a fake ticket was made for; not ok when it is not a fake
// ticket or its check fails.
fake_ticket_check :: proc(ticket: []u8) -> (id: Steam_ID, ok: bool) {
	if len(ticket) != FAKE_TICKET_LEN {return}
	m := FAKE_MAGIC
	for i in 0 ..< 4 {if ticket[i] != m[i] {return}}
	get :: proc(src: []u8) -> (v: u64) {
		for b, i in src {v |= u64(b) << (8 * u64(i))}
		return
	}
	id = Steam_ID(get(ticket[4:12]))
	nonce := u32(get(ticket[12:16]))
	if get(ticket[16:24]) != fake_check(id, nonce) {return {}, false}
	return id, true
}
