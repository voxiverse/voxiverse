package steam

import "core:dynlib"
import "core:log"

import sc "common:steam"

// The real Steam: the Steamworks flat C API (steam_api_flat.h), bound by hand. Only what the
// game uses is here. The library is opened from beside the executable (common/steam), never
// linked. The interface accessors carry the SDK's interface version in their names
// (SteamAPI_SteamUser_v023): each lists the versions accepted; a library none of them match
// is Steam off, with the missing name in the log.

@(private)
Init_Flat :: #type proc "c" (err: ^[sc.ERROR_LEN]u8) -> i32
@(private)
Void_Proc :: #type proc "c" ()
@(private)
Accessor :: #type proc "c" () -> rawptr
@(private)
Get_Steam_ID :: #type proc "c" (self: rawptr) -> u64
@(private)
Get_Persona_Name :: #type proc "c" (self: rawptr) -> cstring
@(private)
Get_Auth_Ticket :: #type proc "c" (
	self: rawptr,
	ticket: rawptr,
	max: i32,
	size: ^u32,
	identity: rawptr,
) -> u32
@(private)
Cancel_Ticket :: #type proc "c" (self: rawptr, handle: u32)
@(private)
Ugc_Create :: #type proc "c" (
	self: rawptr,
	query_type: i32,
	matching: i32,
	creator: u32,
	consumer: u32,
	page: u32,
) -> u64
@(private)
Ugc_Send :: #type proc "c" (self: rawptr, query: u64) -> u64
@(private)
Ugc_Release :: #type proc "c" (self: rawptr, query: u64) -> bool

Real :: struct {
	lib:              dynlib.Library,
	shutdown:         Void_Proc,
	run_callbacks:    Void_Proc,
	user:             rawptr, // ISteamUser*
	friends:          rawptr, // ISteamFriends*
	ugc:              rawptr, // ISteamUGC* (nil: no Workshop)
	get_steam_id:     Get_Steam_ID,
	get_persona_name: Get_Persona_Name,
	get_auth_ticket:  Get_Auth_Ticket,
	cancel_ticket:    Cancel_Ticket,
	ugc_create:       Ugc_Create,
	ugc_send:         Ugc_Send,
	ugc_release:      Ugc_Release,
}

@(private)
real_open :: proc(r: ^Real, dir: string) -> bool {
	lib, loaded := sc.library_open(dir)
	if !loaded {
		log_off("the Steamworks library is not beside the executable")
		return false
	}
	r.lib = lib
	init := cast(Init_Flat)sc.symbol(lib, "SteamAPI_InitFlat")
	r.shutdown = cast(Void_Proc)sc.symbol(lib, "SteamAPI_Shutdown")
	r.run_callbacks = cast(Void_Proc)sc.symbol(lib, "SteamAPI_RunCallbacks")
	user := cast(Accessor)sc.symbol(lib, "SteamAPI_SteamUser_v023", "SteamAPI_SteamUser_v022")
	friends := cast(Accessor)sc.symbol(
		lib,
		"SteamAPI_SteamFriends_v018",
		"SteamAPI_SteamFriends_v017",
	)
	ugc := cast(Accessor)sc.symbol(lib, "SteamAPI_SteamUGC_v021", "SteamAPI_SteamUGC_v020")
	r.get_steam_id = cast(Get_Steam_ID)sc.symbol(lib, "SteamAPI_ISteamUser_GetSteamID")
	r.get_persona_name = cast(Get_Persona_Name)sc.symbol(
		lib,
		"SteamAPI_ISteamFriends_GetPersonaName",
	)
	r.get_auth_ticket = cast(Get_Auth_Ticket)sc.symbol(
		lib,
		"SteamAPI_ISteamUser_GetAuthSessionTicket",
	)
	r.cancel_ticket = cast(Cancel_Ticket)sc.symbol(lib, "SteamAPI_ISteamUser_CancelAuthTicket")
	r.ugc_create = cast(Ugc_Create)sc.symbol(
		lib,
		"SteamAPI_ISteamUGC_CreateQueryAllUGCRequestPage",
	)
	r.ugc_send = cast(Ugc_Send)sc.symbol(lib, "SteamAPI_ISteamUGC_SendQueryUGCRequest")
	r.ugc_release = cast(Ugc_Release)sc.symbol(lib, "SteamAPI_ISteamUGC_ReleaseQueryUGCRequest")

	if init == nil ||
	   r.shutdown == nil ||
	   r.run_callbacks == nil ||
	   user == nil ||
	   friends == nil ||
	   r.get_steam_id == nil ||
	   r.get_persona_name == nil ||
	   r.get_auth_ticket == nil ||
	   r.cancel_ticket == nil {
		log_off("the Steamworks library lacks a function the game needs")
		unload(lib)
		r^ = {}
		return false
	}
	err: [sc.ERROR_LEN]u8
	if result := init(&err); result != 0 {
		log.infof("steam off: init failed result=%d %s", result, sc.error_text(&err))
		unload(lib)
		r^ = {}
		return false
	}
	r.user, r.friends = user(), friends()
	if r.user == nil || r.friends == nil {
		log_off("Steam gave no user interface (is the Steam client running?)")
		r.shutdown()
		unload(lib)
		r^ = {}
		return false
	}
	if ugc != nil && r.ugc_create != nil && r.ugc_send != nil && r.ugc_release != nil {
		r.ugc = ugc()
	}
	log.infof("steam on id=%d", r.get_steam_id(r.user))
	return true
}

@(private)
real_shutdown :: proc(r: ^Real) {
	r.shutdown()
	unload(r.lib)
}
