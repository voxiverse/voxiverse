package steam_server

import "core:dynlib"
import "core:log"

import sc "common:steam"

// The real game server Steam: SteamGameServer_InitEx and the ISteamGameServer calls
// (flat C API), by name from the library beside the executable.

@(private)
Init_Ex :: #type proc "c" (
	ip: u32,
	game_port: u16,
	query_port: u16,
	mode: i32,
	version: cstring,
	err: ^[sc.ERROR_LEN]u8,
) -> i32
@(private)
Void_Proc :: #type proc "c" ()
@(private)
Accessor :: #type proc "c" () -> rawptr
@(private)
Begin_Auth :: #type proc "c" (self: rawptr, ticket: rawptr, size: i32, id: u64) -> i32
@(private)
End_Auth :: #type proc "c" (self: rawptr, id: u64)

Real :: struct {
	lib:           dynlib.Library,
	shutdown:      Void_Proc,
	run_callbacks: Void_Proc,
	server:        rawptr, // ISteamGameServer*
	begin_auth:    Begin_Auth,
	end_auth:      End_Auth,
}

// eServerModeAuthentication: players are authenticated, no master-server listing.
@(private)
MODE_AUTHENTICATION :: 2

@(private)
real_open :: proc(
	r: ^Real,
	dir: string,
	ip: u32,
	game_port, query_port: u16,
	version: cstring,
) -> bool {
	lib, loaded := sc.library_open(dir)
	if !loaded {
		log_off("the Steamworks library is not beside the executable")
		return false
	}
	r.lib = lib
	init := cast(Init_Ex)sc.symbol(lib, "SteamGameServer_InitEx")
	r.shutdown = cast(Void_Proc)sc.symbol(lib, "SteamGameServer_Shutdown")
	r.run_callbacks = cast(Void_Proc)sc.symbol(lib, "SteamGameServer_RunCallbacks")
	accessor := cast(Accessor)sc.symbol(
		lib,
		"SteamAPI_SteamGameServer_v015",
		"SteamAPI_SteamGameServer_v014",
	)
	r.begin_auth = cast(Begin_Auth)sc.symbol(lib, "SteamAPI_ISteamGameServer_BeginAuthSession")
	r.end_auth = cast(End_Auth)sc.symbol(lib, "SteamAPI_ISteamGameServer_EndAuthSession")
	if init == nil ||
	   r.shutdown == nil ||
	   r.run_callbacks == nil ||
	   accessor == nil ||
	   r.begin_auth == nil ||
	   r.end_auth == nil {
		log_off("the Steamworks library lacks a function the server needs")
		unload(lib)
		r^ = {}
		return false
	}
	err: [sc.ERROR_LEN]u8
	if result := init(ip, game_port, query_port, MODE_AUTHENTICATION, version, &err); result != 0 {
		log.infof("steam server off: init failed result=%d %s", result, sc.error_text(&err))
		unload(lib)
		r^ = {}
		return false
	}
	r.server = accessor()
	if r.server == nil {
		log_off("Steam gave no game server interface")
		r.shutdown()
		unload(lib)
		r^ = {}
		return false
	}
	log.info("steam server on")
	return true
}

@(private)
real_shutdown :: proc(r: ^Real) {
	r.shutdown()
	unload(r.lib)
}
