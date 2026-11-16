package protocol

import "core:math"

import "common:access"
import "common:base"
import "common:game"
import "common:starmap"
import sc "common:steam"

// Messages between client and server. Every message travels as bytes, also
// in-process, so singleplayer exercises the same encoding and validation as
// a remote connection. A message is one u8 kind followed by its fields;
// decoders accept only fully valid messages with nothing left over, so
// handlers get validated values only.
//
// Authority: the client sends inputs, never positions; the server moves the
// player and sends back its state, and decides interest: it sends the
// chunks around the player (nearest first) and tells the client which to
// drop.

PROTOCOL_VERSION :: 47
MAX_MESSAGE_SIZE :: 64 * 1024

// Client -> server.

// Hello: the account joining (common/game/account.odin), and as which character
// ("": send the list to choose from). The server answers with a
// Challenge, the client with a Proof; then the character joins (or
// Characters, and a Choose).
Hello :: struct {
	protocol:  u32,
	account:   access.Account,
	character: string, // view into the message; name_valid, or ""
	schema:    u64, // the hash of the engine's state kinds (Schema.engine_hash: the game's are in Welcome's)
	steam_id:  u64, // the player's SteamID (0: not joining with Steam; then no ticket)
	ticket:    []u8, // their Steam auth ticket (view into the message; at most MAX_STEAM_TICKET)
}

// MAX_STEAM_TICKET: the most bytes of Steam auth ticket a Hello holds.
MAX_STEAM_TICKET :: sc.MAX_TICKET

// Proof: the Challenge's nonce signed with the account's key.
Proof :: struct {
	signature: access.Signature,
}

// Pack_Want: after Packs, the packs (by their index in it) the client has
// neither as the universe's own nor in its cache. Empty: it has them all.
Pack_Want :: struct {
	count:   u8,
	indices: [game.MAX_PACKS]u8,
}

// Packs_Ready: the client has built its registry from the packs; content is
// its hash (the server compares it with its own).
Packs_Ready :: struct {
	content: u64,
}

// Dial: dial the gate a block of which is at gate, to address (its galaxy
// the gate's own, for now).
Dial :: struct {
	gate:    game.Block_Pos,
	address: starmap.Address,
}

// Choose: the character to play (an existing one of the account's, or a
// new name), after Characters.
Choose :: struct {
	character: string, // view into the message; name_valid
}

// Input is one tick of the player's controls, numbered so the server can
// say which it has applied. The client never sends where it is: the server
// moves the player with these (and the client predicts the same).
Input :: struct {
	sequence: u32,
	input:    game.Player_Input,
	snapshot: u32, // the newest complete snapshot the client holds (0: none): the next is a delta against it
}

// Ping asks the server to answer with a Pong carrying the same id (round
// trip time, including the wait for the server's next tick).
Ping :: struct {
	id: u32,
}

// Teleport and Set_Rule need permission (teleport.tp; world.rules,
// world.gen): the server refuses them otherwise (Grants says what a player
// may do).
Teleport :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
}

Set_Rule :: struct {
	name:  string, // a rules.* variable
	value: string,
}

// Command runs a server command (server/core/admin.odin), each needing its own
// permission.
Command :: struct {
	command: string,
}

// Inventory_Request: something done in the inventory (common/game/inventory.odin),
// numbered so the client can replay what the server has not answered
// (Inventory says how far it got).
Inventory_Request :: struct {
	sequence: u32,
	action:   game.Inventory_Action,
}

// Chat: a line the player says (formatting codes kept only where they may:
// the server decides).
Chat :: struct {
	text: string,
}

MAX_CHAT_TEXT :: 256

// Respawn: the dead player presses the button (refused while alive).
Respawn :: struct {}

// Stats_Request asks for the player's counters (those whose names contain
// filter), a page of them; the answer is a Stats_Page.
Stats_Request :: struct {
	filter: string, // view into the message
	page:   u16,
	of:     string, // whose (a player's name; "": the asker's)
}

// Telemetry_Batch: to a collector (collector/): lines of a server's event log
// (kind Events: `day` the log's date, `offset` where in that day's file the
// text begins), or a report (kind Report: text a player sent on purpose, or a
// crash). After a Hello and a Proof, as joining.
Telemetry_Batch :: struct {
	kind:   Batch_Kind,
	day:    string, // YYYY-MM-DD (events); "" (a report)
	offset: u64, // events: bytes of that day's file before text
	text:   string, // view into the message
}

Batch_Kind :: enum u8 {
	Events,
	Report,
}

MAX_BATCH_TEXT :: 32 * 1024

// Health: the player's health points and the most they can have (worn items
// change it), sent when either changes.
Health :: struct {
	health: f32,
	max:    f32,
	dead:   bool, // waiting at the death screen for the Respawn button
}

// Telemetry_Ack: a batch was taken: its day and the offset after it (a report:
// "" and its text's length).
Telemetry_Ack :: struct {
	day: string,
	end: u64,
}

// Dev_Message: to a collector (collector/): a note from an admin account to the
// developers (docs/telemetry.md, "Developer chat"). `id` is chosen by the client
// and kept when it sends the message again, so a resend is stored once. The
// context strings are "" when absent.
Dev_Message :: struct {
	id:       u32,
	text:     string, // view into the message; at most MAX_DEV_TEXT bytes
	version:  string, // the game's version
	universe: string,
	world:    string,
	has_pos:  bool,
	pos:      [3]i32,
	has_tick: bool,
	tick:     u64,
}

// Dev_Fetch asks for the replies after the one named `after_id` ("": all).
Dev_Fetch :: struct {
	after_id: string, // view into the message
}

// Dev_Ack answers a Dev_Message: taken (also when it was taken before), or
// refused with a reason.
Dev_Ack :: struct {
	id:     u32,
	ok:     bool,
	reason: string,
}

// Dev_Reply: one reply of the developers.
Dev_Reply :: struct {
	id:   string,
	time: i64, // unix ms
	text: string,
	link: string, // "": none
}

// Dev_Replies answers a Dev_Fetch: up to MAX_DEV_REPLIES replies in id order; fewer
// than that means there are no more after them.
Dev_Replies :: struct {
	count:   int,
	entries: [MAX_DEV_REPLIES]Dev_Reply,
}

MAX_DEV_TEXT :: 4000
MAX_DEV_FIELD :: 64
MAX_DEV_LINK :: 256
MAX_DEV_REPLIES :: 8

MAX_STATS_FILTER :: 32
STATS_PAGE_LINES :: 120

// Telemetry_Report: what the client saw that the server cannot (telemetry.Kind
// with `client` set: info at joining, overlays opened, frame times): at most
// MAX_TELEMETRY_ENTRIES, validated by the server and rate-capped.
Telemetry_Entry :: struct {
	kind: u8, // telemetry.Kind
	text: string, // view into the message
	n:    [3]u32,
}

Telemetry_Report :: struct {
	count:   int,
	entries: [MAX_TELEMETRY_ENTRIES]Telemetry_Entry,
}

MAX_TELEMETRY_ENTRIES :: 8
MAX_TELEMETRY_TEXT :: 31

// Edit asks to put block at pos (Air: break). The client has already
// applied it (predicted); Edit_Result says what became of it. The server
// applies it right after input `after`, where the client was when it made
// the edit, so reach is judged the same however late it arrives.
//
// A placement carries what it followed (placement.odin): the cell aimed at,
// the face (0..5) and where on it (sixteenths); the server runs the rule on
// them and accepts only the same cell and state. Breaking has face
// EDIT_FACE_BREAK; EDIT_FACE_PLAIN: no context (a hoe's tilling, a block of
// the default rule in its default state).
Edit :: struct {
	id:     u32,
	after:  u32,
	pos:    game.Block_Pos,
	block:  game.Block,
	target: game.Block_Pos,
	face:   u8,
	hit:    [3]u8,
}

// edit_plain: an edit without placement context.
edit_plain :: proc(id, after: u32, pos: game.Block_Pos, block: game.Block) -> Edit {
	return {id = id, after = after, pos = pos, block = block, face = game.EDIT_FACE_PLAIN}
}

// Attack hits an entity (left click on it); with a melee weapon in hand, a swing at
// whatever is in its arc (the entity named or none: 0). Like an Edit it follows input
// `after`, so reach is judged from where the player was.
Attack :: struct {
	entity: u32,
	after:  u32,
}

// Use_Entity uses an entity (right click on it: its game's entity_use says what it does). Like an
// Attack it follows input `after`.
Use_Entity :: struct {
	entity: u32,
	after:  u32,
}

// Use_Block uses the block at pos (right click on a chest: open it). Like an
// Edit it follows input `after`, so reach is judged from where the player was.
Use_Block :: struct {
	pos:   game.Block_Pos,
	after: u32,
}

// Fire: the creative rocket launcher, aimed yaw/pitch, after input `after`.
Fire :: struct {
	after:      u32,
	yaw, pitch: f32,
}

// Shoot: the held hitscan weapon (slot: the hotbar slot the client thinks it
// holds), aimed yaw/pitch, after input `after`. press: a new press of the
// button (a semi-automatic weapon needs one). The server fires from where it
// has the player's eye; nothing the client says about hits is believed.
Shoot :: struct {
	after:      u32,
	slot:       u8,
	press:      bool,
	yaw, pitch: f32,
}

// Reload: the held weapon's magazine is refilled after its reload time.
Reload :: struct {}

// Prediction_Check: a hash, by field, of the state the client predicted after
// input `sequence`, sent every DESYNC_CHECK_INPUTS inputs. The server hashes
// its own state after the same input and, if the player has been quiet, names
// any field that differs (docs/determinism.md). A check never changes state.
Prediction_Check :: struct {
	sequence: u32,
	fields:   [Player_Field]u32,
}

DESYNC_CHECK_INPUTS :: 30 // inputs between checks (one a second)
DESYNC_QUIET_TICKS :: 60 // ticks without a disturbance before a check is judged

// MAX_GAME_ACTIONS: the actions a game's client part may bind keys to (engine.Game.actions).
MAX_GAME_ACTIONS :: 3

// Game_Action: the player pressed one of its game's own actions (a key bound to "use
// ability", "drink potion"): index into the game's list. Like an Attack it follows
// input `after`.
Game_Action :: struct {
	index: u8,
	after: u32,
}

Client_Message :: union {
	Hello,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
	Command,
	Attack,
	Fire,
	Chat,
	Inventory_Request,
	Proof,
	Choose,
	Dial,
	Use_Entity,
	Stats_Request,
	Telemetry_Report,
	Telemetry_Batch,
	Dev_Message,
	Dev_Fetch,
	Use_Block,
	Prediction_Check,
	Pack_Want,
	Packs_Ready,
	Respawn,
	Shoot,
	Reload,
	Game_Action,
	Game_Request,
}

// Server -> client.

// Pack_Entry: one pack of the universe, as the Packs message lists it.
Pack_Entry :: struct {
	namespace: string, // view into the message
	version:   string, // view into the message
	size:      u32, // of its archive (pack_archive.odin)
	sha256:    [32]u8, // of its archive: the pack's hash
}

MAX_PACK_PART :: 1100 // bytes of a pack in one Pack_Part

// Packs: after the Proof, the packs of the universe besides the base pack, in
// load order (the client asks for those it lacks with a Pack_Want), and the
// content hash the registry they make has.
Packs :: struct {
	content: u64,
	count:   u8,
	entries: [game.MAX_PACKS]Pack_Entry,
}

// Packs_Changed: the server reloaded its packs (a development build; hot
// reload): content is the new registry's hash. A client on the same machine
// builds the same registry from the same files and checks it; no pack file is
// sent.
Packs_Changed :: struct {
	content: u64,
}

// Pack_Part: bytes of one pack's archive, in order.
Pack_Part :: struct {
	index:  u8,
	offset: u32,
	data:   []u8, // view into the message
}

// Challenge: sign this (a Proof) to show the account is yours.
Challenge :: struct {
	nonce: access.Nonce,
}

// Characters: the account's characters here, to choose from (names, space
// apart; maybe none).
Characters :: struct {
	names: string, // view into the message
}

Welcome :: struct {
	protocol:    u32,
	tick_rate:   u32,
	player:      u16, // this client's player id
	spawn:       [3]f64,
	view_radius: u32, // the interest area, in chunks (see interest.odin)
	view_height: u32,
	rules:       game.Rules,
	address:     starmap.Address, // the world the player is in
	content:     u64, // the server's registry hash (registry.hash): its blocks, items, recipes...
	packs:       string, // the universe's packs, "namespace@version" comma separated, in load order
	game:        string, // the game the server runs, by id (every session plays one); game_id_valid
	schema:      u64, // the hash of every state kind, the game's too (Hello's has the engine's alone)
}

// MAX_PACKS_TEXT: the longest Welcome.packs.
MAX_PACKS_TEXT :: 2048

// World_Changed: the player travelled to another world (its address and
// rules): drop everything of the last one. Its chunks, entities and the
// player's arrival (a teleport) follow.
World_Changed :: struct {
	address: starmap.Address,
	rules:   game.Rules,
}

// Selection: the player's world-editing selection (server commands /pos1,
// /pos2, /sel), for the client to draw its box; a corner not set is none.
Selection :: struct {
	corners: [2]Maybe(game.Block_Pos),
}

// Reject ends the connection.
Reject :: struct {
	reason: string,
}

// Chunk_Message carries a chunk's blocks: is_uniform with uniform, or the
// array the decoder was given.
Chunk_Message :: struct {
	pos:        game.Chunk_Pos,
	uniform:    game.Block,
	is_uniform: bool,
	channels:   []game.Wire_Channel, // the replicated channels not uniform at their default; the rest are at their defaults
}

Unload_Chunk :: struct {
	pos: game.Chunk_Pos,
}

Pong :: struct {
	id: u32,
}

// Stats_Page: a page of counters: "name value" lines, newline apart.
Stats_Page :: struct {
	page:  u16,
	pages: u16,
	text:  string, // view into the message
}

MAX_STATS_TEXT :: 16 * 1024

// Notice: something the server wants the player to read (chat and the
// console), formatted (common/game/format.odin).
Notice :: struct {
	text: string `net:"max=1024"`,
}

MAX_NOTICE_TEXT :: 1024

// Chat_Line: a line of chat, as everyone sees it (the sender's tag, name
// and words, formatted), numbered so a moderator can take it back.
Chat_Line :: struct {
	id:     u32,
	sender: u16, // the player who said it; NO_PLAYER: the server
	text:   string `net:"max=1024"`,
}

NO_PLAYER :: 0xffff

// Chat_Delete: a moderator took line id back.
Chat_Delete :: struct {
	id: u32,
}

// Entity_Hurt: it was hit (flash, sound).
Entity_Hurt :: struct {
	entity: u32,
}

// Bulk_Begin: the next `count` Chunk messages are one bulk edit's (show
// them together, so no face goes missing for a frame in between).
Bulk_Begin :: struct {
	count: u16,
}

// Explosion: something blew up here (flash, debris, sound); the blocks it
// took come as a bulk edit after.
Explosion :: struct {
	position: [3]f64,
	radius:   f32,
}

// Grants: what this player may do (common/game/permissions.odin), as
// grants_text's lines, and the server commands they may use (names, space
// apart: for Tab): when they join and whenever it changes.
Grants :: struct {
	text:     string `net:"max=16384"`,
	commands: string `net:"max=16384"`,
}

MAX_BLOCKS_CHANGED :: 64 // single changes in a chunk in one tick (a chunk with more is sent whole)

// Variables: some of the server's variables (worldgen.*), as `name = value`
// lines: sent when a player joins and when they change. As text, so this
// package needs no knowledge of what they are.
Variables :: struct {
	text: string `net:"max=4096"`,
}

// Column: the y of the highest solid block in each block column of a chunk
// column (x fastest). Sky light needs it: the client cannot see above what
// it has loaded. Sent before a column's first chunk, and again when an edit
// changes it.
Column :: struct {
	pos:     [2]i32, // chunk x, z
	heights: [game.CHUNK_SIZE * game.CHUNK_SIZE]i32,
}

// Edit_Result answers an Edit: accepted or not, and the block now at pos
// either way (the client sets it, undoing a rejected prediction).
//
// An edit of a two-cell block (a door) answers for the other cell too:
// `companion`, where it is and what the server has there, so a refusal puts
// both back.
Edit_Result :: struct {
	id:        u32,
	accepted:  bool,
	pos:       game.Block_Pos,
	block:     game.Block,
	companion: Maybe(Companion_Record),
}

Companion_Record :: struct {
	pos:   game.Block_Pos,
	block: game.Block,
}

// State_Message and Snapshot_Message carry the bytes of a State or Snapshot
// message (replica.odin: a Receiver decodes them against what the client
// holds); decode_server checks the kind only.
State_Message :: struct {
	data: []u8,
}

Snapshot_Message :: struct {
	data: []u8,
}

Server_Message :: union {
	Welcome,
	Reject,
	Chunk_Message,
	Unload_Chunk,
	Pong,
	Edit_Result,
	Column,
	Bulk_Begin,
	Challenge,
	Characters,
	World_Changed,
	Stats_Page,
	Telemetry_Ack,
	Dev_Ack,
	Dev_Replies,
	State_Message,
	Snapshot_Message,
	Packs,
	Pack_Part,
	Packs_Changed,
}

MAX_VIEW_RADIUS :: 32
MAX_REASON_LENGTH :: 256
MAX_RULE_TEXT :: 64
MAX_ADMIN_TEXT :: 256
MAX_SPEED :: 1000 // blocks/s: anything faster in a message is invalid

@(private = "file")
Client_Kind :: enum u8 {
	Hello = 1,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
	Command,
	Attack,
	Fire,
	Chat,
	Inventory_Request,
	Proof,
	Choose,
	Dial,
	Use_Entity,
	Stats_Request,
	Telemetry_Report,
	Telemetry_Batch,
	Use_Block,
	Prediction_Check,
	Pack_Want,
	Packs_Ready,
	Respawn,
	Shoot,
	Reload,
	Dev_Message,
	Dev_Fetch,
	// 28: retired (Market_Trade)
	Game_Action = 29,
	Game_Request,
}

@(private = "file")
Server_Kind :: enum u8 {
	Welcome       = 1,
	Reject        = 2,
	Chunk         = 3,
	Unload_Chunk  = 4,
	Pong          = 5,
	// 6, 7: retired (Player_Update, Rules_Changed)
	Edit_Result   = 8,
	// 9: retired (Block_Changed)
	Column        = 10,
	// 11-19: retired (Time, Player_Joined, Player_Left, Players, Notice,
	// Entity_Spawn, Entity_Despawn, Entities, Entity_Hurt)
	Bulk_Begin    = 20,
	// 21-27: retired (Explosion, Variables, Blocks_Changed, Grants, Chat_Line,
	// Chat_Delete, Inventory_Update)
	Challenge     = 28,
	Characters    = 29,
	World_Changed = 30,
	// 31, 32: retired (Selection, Player_Worn)
	Stats_Page    = 33,
	Telemetry_Ack = 34,
	// 35: retired (Health)
	State         = 36,
	Snapshot      = 37,
	Packs         = 38,
	Pack_Part     = 39,
	Packs_Changed = 40,
	Dev_Ack       = 41,
	Dev_Replies   = 42,
	// 43: retired (Market_View)
}

// message_reliable: whether messages of a kind (from sender) must arrive,
// in order; the rest are states sent every tick or so, where only the
// newest matters (a remote connection may drop them).
message_reliable :: proc(sender: Side, kind: u8) -> bool {
	if sender == .Client {
		return kind != u8(Client_Kind.Ping)
	}
	switch kind {
	case u8(Server_Kind.Snapshot), u8(Server_Kind.Pong):
		return false
	}
	return true
}

// message_kind_name names a message kind (its first byte) sent by sender,
// for tools and statistics; "" if there is no such kind.
message_kind_name :: proc(sender: Side, kind: u8) -> string {
	if sender == .Client {
		switch kind {
		case u8(Client_Kind.Hello):
			return "hello"
		case u8(Client_Kind.Input):
			return "input"
		case u8(Client_Kind.Ping):
			return "ping"
		case u8(Client_Kind.Teleport):
			return "teleport"
		case u8(Client_Kind.Set_Rule):
			return "set_rule"
		case u8(Client_Kind.Edit):
			return "edit"
		case u8(Client_Kind.Command):
			return "command"
		case u8(Client_Kind.Attack):
			return "attack"
		case u8(Client_Kind.Use_Entity):
			return "use_entity"
		case u8(Client_Kind.Use_Block):
			return "use_block"
		case u8(Client_Kind.Prediction_Check):
			return "prediction_check"
		case u8(Client_Kind.Stats_Request):
			return "stats_request"
		case u8(Client_Kind.Telemetry_Report):
			return "telemetry"
		case u8(Client_Kind.Telemetry_Batch):
			return "telemetry_batch"
		case u8(Client_Kind.Dev_Message):
			return "dev_message"
		case u8(Client_Kind.Dev_Fetch):
			return "dev_fetch"
		case u8(Client_Kind.Fire):
			return "fire"
		case u8(Client_Kind.Chat):
			return "chat"
		case u8(Client_Kind.Inventory_Request):
			return "inventory_request"
		case u8(Client_Kind.Proof):
			return "proof"
		case u8(Client_Kind.Pack_Want):
			return "pack_want"
		case u8(Client_Kind.Packs_Ready):
			return "packs_ready"
		case u8(Client_Kind.Respawn):
			return "respawn"
		case u8(Client_Kind.Shoot):
			return "shoot"
		case u8(Client_Kind.Reload):
			return "reload"
		case u8(Client_Kind.Game_Action):
			return "game_action"
		case u8(Client_Kind.Game_Request):
			return "game_request"
		case u8(Client_Kind.Choose):
			return "choose"
		case u8(Client_Kind.Dial):
			return "dial"
		}
	} else {
		switch kind {
		case u8(Server_Kind.Packs):
			return "packs"
		case u8(Server_Kind.Pack_Part):
			return "pack_part"
		case u8(Server_Kind.Packs_Changed):
			return "packs_changed"
		case u8(Server_Kind.Welcome):
			return "welcome"
		case u8(Server_Kind.Reject):
			return "reject"
		case u8(Server_Kind.Chunk):
			return "chunk"
		case u8(Server_Kind.Unload_Chunk):
			return "unload"
		case u8(Server_Kind.Pong):
			return "pong"
		case u8(Server_Kind.Edit_Result):
			return "edit_result"
		case u8(Server_Kind.Column):
			return "column"
		case u8(Server_Kind.Bulk_Begin):
			return "bulk"
		case u8(Server_Kind.Challenge):
			return "challenge"
		case u8(Server_Kind.Characters):
			return "characters"
		case u8(Server_Kind.World_Changed):
			return "world_changed"
		case u8(Server_Kind.Stats_Page):
			return "stats_page"
		case u8(Server_Kind.Telemetry_Ack):
			return "telemetry_ack"
		case u8(Server_Kind.Dev_Ack):
			return "dev_ack"
		case u8(Server_Kind.Dev_Replies):
			return "dev_replies"
		case u8(Server_Kind.State):
			return "state"
		case u8(Server_Kind.Snapshot):
			return "snapshot"
		}
	}
	return ""
}

@(private = "file")
write_bool :: proc(w: ^game.Writer, b: bool) {game.write_u8(w, 1 if b else 0)}

// read_bool: 0 or 1; anything else fails the reader.
@(private = "file")
read_bool :: proc(r: ^game.Reader) -> bool {
	v := game.read_u8(r)
	if v > 1 {game.reader_fail(r)}
	return v == 1
}

// encode_client appends m to w.buf.
encode_client :: proc(w: ^game.Writer, m: Client_Message) {
	switch v in m {
	case Hello:
		game.write_u8(w, u8(Client_Kind.Hello))
		game.write_u32(w, v.protocol)
		a := v.account
		for b in a {game.write_u8(w, b)}
		game.write_string(w, v.character)
		game.write_u32(w, u32(v.schema >> 32))
		game.write_u32(w, u32(v.schema))
		// Steam, optional: a ticket's length (0: none), then the SteamID and the ticket.
		game.write_varint(w, u32(len(v.ticket)))
		if len(v.ticket) > 0 {
			game.write_u32(w, u32(v.steam_id >> 32))
			game.write_u32(w, u32(v.steam_id))
			append(&w.buf, ..v.ticket)
		}
	case Proof:
		game.write_u8(w, u8(Client_Kind.Proof))
		sig := v.signature
		for b in sig {game.write_u8(w, b)}
	case Choose:
		game.write_u8(w, u8(Client_Kind.Choose))
		game.write_string(w, v.character)
	case Dial:
		game.write_u8(w, u8(Client_Kind.Dial))
		write_block_pos(w, v.gate)
		write_address(w, v.address)
	case Input:
		game.write_u8(w, u8(Client_Kind.Input))
		game.write_u32(w, v.sequence)
		write_player_input(w, v.input)
		game.write_varint(w, v.snapshot)
	case Respawn:
		game.write_u8(w, u8(Client_Kind.Respawn))
	case Reload:
		game.write_u8(w, u8(Client_Kind.Reload))
	case Game_Action:
		game.write_u8(w, u8(Client_Kind.Game_Action))
		game.write_u8(w, v.index)
		game.write_u32(w, v.after)
	case Game_Request:
		assert(len(v.data) <= MAX_GAME_REQUEST, "a game's request too big")
		game.write_u8(w, u8(Client_Kind.Game_Request))
		game.write_u16(w, v.kind)
		game.write_u32(w, v.after)
		game.write_varint(w, u32(len(v.data)))
		append(&w.buf, ..v.data)
	case Shoot:
		game.write_u8(w, u8(Client_Kind.Shoot))
		game.write_u32(w, v.after)
		game.write_u8(w, v.slot)
		game.write_u8(w, 1 if v.press else 0)
		game.write_f32(w, v.yaw)
		game.write_f32(w, v.pitch)
	case Ping:
		game.write_u8(w, u8(Client_Kind.Ping))
		game.write_u32(w, v.id)
	case Teleport:
		game.write_u8(w, u8(Client_Kind.Teleport))
		write_position(w, v.position)
		game.write_f32(w, v.yaw)
		game.write_f32(w, v.pitch)
	case Set_Rule:
		game.write_u8(w, u8(Client_Kind.Set_Rule))
		game.write_string(w, v.name)
		game.write_string(w, v.value)
	case Edit:
		game.write_u8(w, u8(Client_Kind.Edit))
		game.write_u32(w, v.id)
		game.write_u32(w, v.after)
		write_block_pos(w, v.pos)
		game.write_u16(w, u16(v.block))
		write_block_pos(w, v.target)
		game.write_u8(w, v.face)
		for h in v.hit {game.write_u8(w, h)}
	case Command:
		game.write_u8(w, u8(Client_Kind.Command))
		game.write_string(w, v.command)
	case Chat:
		game.write_u8(w, u8(Client_Kind.Chat))
		game.write_string(w, v.text)
	case Inventory_Request:
		game.write_u8(w, u8(Client_Kind.Inventory_Request))
		game.write_u32(w, v.sequence)
		game.write_u8(w, u8(v.action.kind))
		game.write_u8(w, u8(i8(v.action.slot)))
		game.write_u16(w, u16(v.action.arg))
	case Attack:
		game.write_u8(w, u8(Client_Kind.Attack))
		game.write_u32(w, v.entity)
		game.write_u32(w, v.after)
	case Use_Entity:
		game.write_u8(w, u8(Client_Kind.Use_Entity))
		game.write_u32(w, v.entity)
		game.write_u32(w, v.after)
	case Use_Block:
		game.write_u8(w, u8(Client_Kind.Use_Block))
		write_block_pos(w, v.pos)
		game.write_u32(w, v.after)
	case Pack_Want:
		game.write_u8(w, u8(Client_Kind.Pack_Want))
		game.write_u8(w, v.count)
		for i in 0 ..< int(v.count) {game.write_u8(w, v.indices[i])}
	case Packs_Ready:
		game.write_u8(w, u8(Client_Kind.Packs_Ready))
		game.write_fixed64(w, v.content)
	case Prediction_Check:
		game.write_u8(w, u8(Client_Kind.Prediction_Check))
		game.write_u32(w, v.sequence)
		for f in v.fields {game.write_u32(w, f)}
	case Stats_Request:
		game.write_u8(w, u8(Client_Kind.Stats_Request))
		game.write_string(w, v.filter)
		game.write_u16(w, v.page)
		game.write_string(w, v.of)
	case Telemetry_Batch:
		game.write_u8(w, u8(Client_Kind.Telemetry_Batch))
		game.write_u8(w, u8(v.kind))
		game.write_string(w, v.day)
		game.write_u32(w, u32(v.offset >> 32))
		game.write_u32(w, u32(v.offset))
		game.write_string(w, v.text)
	case Dev_Message:
		game.write_u8(w, u8(Client_Kind.Dev_Message))
		game.write_u32(w, v.id)
		game.write_string(w, v.text)
		game.write_string(w, v.version)
		game.write_string(w, v.universe)
		game.write_string(w, v.world)
		write_bool(w, v.has_pos)
		for c in v.pos {game.write_i32(w, c)}
		write_bool(w, v.has_tick)
		game.write_fixed64(w, v.tick)
	case Dev_Fetch:
		game.write_u8(w, u8(Client_Kind.Dev_Fetch))
		game.write_string(w, v.after_id)
	case Telemetry_Report:
		game.write_u8(w, u8(Client_Kind.Telemetry_Report))
		game.write_u8(w, u8(v.count))
		for i in 0 ..< min(v.count, MAX_TELEMETRY_ENTRIES) {
			e := v.entries[i]
			game.write_u8(w, e.kind)
			game.write_string(w, e.text)
			for n in e.n {game.write_u32(w, n)}
		}
	case Fire:
		game.write_u8(w, u8(Client_Kind.Fire))
		game.write_u32(w, v.after)
		game.write_f32(w, v.yaw)
		game.write_f32(w, v.pitch)
	}
	assert(len(w.buf) <= MAX_MESSAGE_SIZE)
}

// encode_server appends m to w.buf; blocks are a Chunk_Message's blocks.
encode_server :: proc(w: ^game.Writer, m: Server_Message, blocks: ^game.Chunk_Blocks = nil) {
	switch v in m {
	case Welcome:
		game.write_u8(w, u8(Server_Kind.Welcome))
		game.write_u32(w, v.protocol)
		game.write_u32(w, v.tick_rate)
		game.write_u16(w, v.player)
		write_position(w, v.spawn)
		game.write_u32(w, v.view_radius)
		game.write_u32(w, v.view_height)
		rules := v.rules
		write_vars(w, game.rules_table(), &rules)
		write_address(w, v.address)
		game.write_fixed64(w, v.content)
		game.write_string(w, v.packs)
		game.write_string(w, v.game)
		game.write_fixed64(w, v.schema)
	case World_Changed:
		game.write_u8(w, u8(Server_Kind.World_Changed))
		write_address(w, v.address)
		rules := v.rules
		write_vars(w, game.rules_table(), &rules)
	case Telemetry_Ack:
		game.write_u8(w, u8(Server_Kind.Telemetry_Ack))
		game.write_string(w, v.day)
		game.write_u32(w, u32(v.end >> 32))
		game.write_u32(w, u32(v.end))
	case Dev_Ack:
		game.write_u8(w, u8(Server_Kind.Dev_Ack))
		game.write_u32(w, v.id)
		write_bool(w, v.ok)
		game.write_string(w, v.reason)
	case Dev_Replies:
		game.write_u8(w, u8(Server_Kind.Dev_Replies))
		game.write_u8(w, u8(v.count))
		for i in 0 ..< min(v.count, MAX_DEV_REPLIES) {
			e := v.entries[i]
			game.write_string(w, e.id)
			game.write_fixed64(w, u64(e.time))
			game.write_string(w, e.text)
			game.write_string(w, e.link)
		}
	case Stats_Page:
		game.write_u8(w, u8(Server_Kind.Stats_Page))
		game.write_u16(w, v.page)
		game.write_u16(w, v.pages)
		game.write_string(w, v.text)
	case Reject:
		game.write_u8(w, u8(Server_Kind.Reject))
		game.write_string(w, v.reason)
	case Chunk_Message:
		game.write_u8(w, u8(Server_Kind.Chunk))
		write_chunk_pos(w, v.pos)
		game.write_chunk(w, blocks, v.channels)
	case Unload_Chunk:
		game.write_u8(w, u8(Server_Kind.Unload_Chunk))
		write_chunk_pos(w, v.pos)
	case Pong:
		game.write_u8(w, u8(Server_Kind.Pong))
		game.write_u32(w, v.id)
	case Edit_Result:
		game.write_u8(w, u8(Server_Kind.Edit_Result))
		game.write_u32(w, v.id)
		game.write_u8(w, 1 if v.accepted else 0)
		write_block_pos(w, v.pos)
		game.write_u16(w, u16(v.block))
		if c, has := v.companion.?; has {
			game.write_u8(w, 1)
			write_block_pos(w, c.pos)
			game.write_u16(w, u16(c.block))
		} else {
			game.write_u8(w, 0)
		}
	case Column:
		game.write_u8(w, u8(Server_Kind.Column))
		game.write_i32(w, v.pos.x)
		game.write_i32(w, v.pos.y)
		previous: i32
		for h in v.heights {
			game.write_svarint(w, h - previous)
			previous = h
		}
	case Bulk_Begin:
		game.write_u8(w, u8(Server_Kind.Bulk_Begin))
		game.write_u16(w, v.count)
	case Challenge:
		game.write_u8(w, u8(Server_Kind.Challenge))
		n := v.nonce
		for b in n {game.write_u8(w, b)}
	case Packs:
		game.write_u8(w, u8(Server_Kind.Packs))
		game.write_fixed64(w, v.content)
		game.write_u8(w, v.count)
		for i in 0 ..< int(v.count) {
			e := v.entries[i]
			game.write_string(w, e.namespace)
			game.write_string(w, e.version)
			game.write_u32(w, e.size)
			for b in e.sha256 {game.write_u8(w, b)}
		}
	case Packs_Changed:
		game.write_u8(w, u8(Server_Kind.Packs_Changed))
		game.write_fixed64(w, v.content)
	case Pack_Part:
		game.write_u8(w, u8(Server_Kind.Pack_Part))
		game.write_u8(w, v.index)
		game.write_u32(w, v.offset)
		append(&w.buf, ..v.data)
	case Characters:
		game.write_u8(w, u8(Server_Kind.Characters))
		game.write_string(w, v.names)
	case State_Message:
		append(&w.buf, ..v.data)
	case Snapshot_Message:
		append(&w.buf, ..v.data)
	}
	assert(len(w.buf) <= MAX_MESSAGE_SIZE)
}

// decode_client returns the message in data, or ok = false if it is not a
// valid one. Strings in the result point into data.
decode_client :: proc(data: []u8, reg: ^game.Registry = nil) -> (m: Client_Message, ok: bool) {
	if len(data) > MAX_MESSAGE_SIZE {return}
	r := game.reader_make(data, reg)
	switch game.read_u8(&r) {
	case u8(Client_Kind.Hello):
		h := Hello {
			protocol = game.read_u32(&r),
		}
		for &b in h.account {b = game.read_u8(&r)}
		h.character = game.read_string(&r, game.MAX_NAME_LENGTH)
		hi, lo := game.read_u32(&r), game.read_u32(&r)
		h.schema = u64(hi) << 32 | u64(lo)
		if n := game.read_varint(&r); n > 0 {
			if n > MAX_STEAM_TICKET {
				game.reader_fail(&r)
			} else {
				id_hi, id_lo := game.read_u32(&r), game.read_u32(&r)
				h.steam_id = u64(id_hi) << 32 | u64(id_lo)
				h.ticket = game.read_bytes(&r, int(n))
				if h.steam_id == 0 {game.reader_fail(&r)}
			}
		}
		m = h
	case u8(Client_Kind.Proof):
		p: Proof
		for &b in p.signature {b = game.read_u8(&r)}
		m = p
	case u8(Client_Kind.Choose):
		m = Choose {
			character = game.read_string(&r, game.MAX_NAME_LENGTH),
		}
	case u8(Client_Kind.Dial):
		d := Dial {
			gate = read_block_pos(&r),
		}
		d.address = read_address(&r)
		m = d
	case u8(Client_Kind.Input):
		m = Input {
			sequence = game.read_u32(&r),
			input    = read_player_input(&r),
			snapshot = game.read_varint(&r),
		}
	case u8(Client_Kind.Respawn):
		m = Respawn{}
	case u8(Client_Kind.Reload):
		m = Reload{}
	case u8(Client_Kind.Game_Action):
		a := Game_Action {
			index = game.read_u8(&r),
			after = game.read_u32(&r),
		}
		if int(a.index) >= MAX_GAME_ACTIONS {game.reader_fail(&r)}
		m = a
	case u8(Client_Kind.Game_Request):
		q := Game_Request {
			kind  = game.read_u16(&r),
			after = game.read_u32(&r),
		}
		n := int(game.read_varint(&r))
		if n > MAX_GAME_REQUEST {game.reader_fail(&r)} else {q.data = game.read_bytes(&r, n)}
		m = q
	case u8(Client_Kind.Shoot):
		f := Shoot {
			after = game.read_u32(&r),
			slot  = game.read_u8(&r),
		}
		press := game.read_u8(&r)
		f.yaw, f.pitch = game.read_f32(&r), game.read_f32(&r)
		f.press = press == 1
		if press > 1 ||
		   int(f.slot) >= game.HOTBAR_SLOTS ||
		   !(abs(f.yaw) <= 1e6) ||
		   !(abs(f.pitch) <= game.PITCH_LIMIT) {game.reader_fail(&r)}
		m = f
	case u8(Client_Kind.Ping):
		m = Ping {
			id = game.read_u32(&r),
		}
	case u8(Client_Kind.Teleport):
		t := Teleport {
			position = read_position(&r),
			yaw      = game.read_f32(&r),
			pitch    = game.read_f32(&r),
		}
		if abs(t.pitch) > game.PITCH_LIMIT {game.reader_fail(&r)}
		m = t
	case u8(Client_Kind.Set_Rule):
		m = Set_Rule {
			name  = game.read_string(&r, MAX_RULE_TEXT),
			value = game.read_string(&r, MAX_RULE_TEXT),
		}
	case u8(Client_Kind.Edit):
		m = Edit {
			id    = game.read_u32(&r),
			after = game.read_u32(&r),
			pos   = read_block_pos(&r),
			block = read_block(&r),
		}
		e := m.(Edit)
		e.target = read_block_pos(&r)
		e.face = game.read_u8(&r)
		for &h in e.hit {h = game.read_u8(&r)}
		if e.face > game.EDIT_FACE_PLAIN {game.reader_fail(&r)}
		for h in e.hit {if h > 16 {game.reader_fail(&r)}}
		m = e
	case u8(Client_Kind.Command):
		m = Command {
			command = game.read_string(&r, MAX_ADMIN_TEXT),
		}
	case u8(Client_Kind.Chat):
		m = Chat {
			text = game.read_string(&r, MAX_CHAT_TEXT),
		}
	case u8(Client_Kind.Inventory_Request):
		q := Inventory_Request {
			sequence = game.read_u32(&r),
		}
		kind := game.read_u8(&r)
		if int(kind) >= len(game.Inventory_Action_Kind) {game.reader_fail(&r)}
		q.action.kind =
			game.Inventory_Action_Kind(kind) if int(kind) < len(game.Inventory_Action_Kind) else {}
		q.action.slot = int(i8(game.read_u8(&r)))
		q.action.arg = int(game.read_u16(&r))
		if q.action.slot < game.CURSOR_SLOT ||
		   q.action.slot >= game.ALL_SLOTS {game.reader_fail(&r)}
		m = q
	case u8(Client_Kind.Attack):
		m = Attack {
			entity = game.read_u32(&r),
			after  = game.read_u32(&r),
		}
	case u8(Client_Kind.Use_Entity):
		m = Use_Entity {
			entity = game.read_u32(&r),
			after  = game.read_u32(&r),
		}
	case u8(Client_Kind.Use_Block):
		m = Use_Block {
			pos   = read_block_pos(&r),
			after = game.read_u32(&r),
		}
	case u8(Client_Kind.Pack_Want):
		want: Pack_Want
		want.count = game.read_u8(&r)
		if int(want.count) > game.MAX_PACKS {game.reader_fail(&r)}
		for i in 0 ..< min(int(want.count), game.MAX_PACKS) {want.indices[i] = game.read_u8(&r)}
		m = want
	case u8(Client_Kind.Packs_Ready):
		m = Packs_Ready {
			content = game.read_fixed64(&r),
		}
	case u8(Client_Kind.Prediction_Check):
		c := Prediction_Check {
			sequence = game.read_u32(&r),
		}
		for &f in c.fields {f = game.read_u32(&r)}
		m = c
	case u8(Client_Kind.Stats_Request):
		m = Stats_Request {
			filter = game.read_string(&r, MAX_STATS_FILTER),
			page   = game.read_u16(&r),
			of     = game.read_string(&r, game.MAX_NAME_LENGTH),
		}
	case u8(Client_Kind.Telemetry_Batch):
		b: Telemetry_Batch
		kind := game.read_u8(&r)
		if kind > u8(Batch_Kind.Report) {game.reader_fail(&r)}
		b.kind = Batch_Kind(kind)
		b.day = game.read_string(&r, 10)
		hi, lo := game.read_u32(&r), game.read_u32(&r)
		b.offset = u64(hi) << 32 | u64(lo)
		b.text = game.read_string(&r, MAX_BATCH_TEXT)
		m = b
	case u8(Client_Kind.Dev_Message):
		d: Dev_Message
		d.id = game.read_u32(&r)
		d.text = game.read_string(&r, MAX_DEV_TEXT)
		d.version = game.read_string(&r, MAX_DEV_FIELD)
		d.universe = game.read_string(&r, MAX_DEV_FIELD)
		d.world = game.read_string(&r, MAX_DEV_FIELD)
		d.has_pos = read_bool(&r)
		for &c in d.pos {c = game.read_i32(&r)}
		d.has_tick = read_bool(&r)
		d.tick = game.read_fixed64(&r)
		m = d
	case u8(Client_Kind.Dev_Fetch):
		m = Dev_Fetch{game.read_string(&r, MAX_DEV_FIELD)}
	case u8(Client_Kind.Telemetry_Report):
		rep: Telemetry_Report
		rep.count = int(game.read_u8(&r))
		if rep.count > MAX_TELEMETRY_ENTRIES {game.reader_fail(&r)}
		for &e in rep.entries[:min(rep.count, MAX_TELEMETRY_ENTRIES)] {
			e.kind = game.read_u8(&r)
			e.text = game.read_string(&r, MAX_TELEMETRY_TEXT)
			for &n in e.n {n = game.read_u32(&r)}
		}
		m = rep
	case u8(Client_Kind.Fire):
		f := Fire {
			after = game.read_u32(&r),
			yaw   = game.read_f32(&r),
			pitch = game.read_f32(&r),
		}
		if !(abs(f.yaw) <= 1e6) || !(abs(f.pitch) <= game.PITCH_LIMIT) {game.reader_fail(&r)}
		m = f
	case:
		return
	}
	return m, game.reader_finish(&r)
}

// decode_server is decode_client's counterpart; a chunk's blocks go into
// blocks (left unchanged for a uniform chunk).
decode_server :: proc(
	data: []u8,
	blocks: ^game.Block_Array,
	reg: ^game.Registry = nil,
) -> (
	m: Server_Message,
	ok: bool,
) {
	if len(data) > MAX_MESSAGE_SIZE {return}
	r := game.reader_make(data, reg)
	switch game.read_u8(&r) {
	case u8(Server_Kind.Welcome):
		w := Welcome {
			protocol  = game.read_u32(&r),
			tick_rate = game.read_u32(&r),
			player    = game.read_u16(&r),
		}
		w.spawn = read_position(&r)
		w.view_radius = game.read_u32(&r)
		w.view_height = game.read_u32(&r)
		read_vars(&r, game.rules_table(), &w.rules)
		w.address = read_address(&r)
		w.content = game.read_fixed64(&r)
		w.packs = game.read_string(&r, MAX_PACKS_TEXT)
		w.game = game.read_string(&r, game.MAX_GAME_ID)
		w.schema = game.read_fixed64(&r)
		if !game.game_id_valid(w.game) ||
		   w.view_radius == 0 ||
		   w.view_radius > MAX_VIEW_RADIUS ||
		   w.view_height == 0 ||
		   w.view_height > game.MAX_VIEW_HEIGHT {
			game.reader_fail(&r)
		}
		m = w
	case u8(Server_Kind.Reject):
		m = Reject {
			reason = game.read_string(&r, MAX_REASON_LENGTH),
		}
	case u8(Server_Kind.Chunk):
		c := Chunk_Message {
			pos = read_chunk_pos(&r),
		}
		c.uniform, c.is_uniform, c.channels = game.read_chunk(&r, blocks)
		m = c
	case u8(Server_Kind.Unload_Chunk):
		m = Unload_Chunk {
			pos = read_chunk_pos(&r),
		}
	case u8(Server_Kind.Pong):
		m = Pong {
			id = game.read_u32(&r),
		}
	case u8(Server_Kind.Edit_Result):
		e := Edit_Result {
			id = game.read_u32(&r),
		}
		flag := game.read_u8(&r)
		if flag > 1 {game.reader_fail(&r)}
		e.accepted = flag == 1
		e.pos = read_block_pos(&r)
		e.block = read_block(&r)
		has := game.read_u8(&r)
		if has > 1 {game.reader_fail(&r)}
		if has == 1 {
			e.companion = Companion_Record{read_block_pos(&r), read_block(&r)}
		}
		m = e
	case u8(Server_Kind.Column):
		c: Column
		c.pos = {game.read_i32(&r), game.read_i32(&r)}
		if !game.in_world({c.pos.x, 0, c.pos.y}) {game.reader_fail(&r)}
		previous: i32
		for &h in c.heights {
			h = previous + game.read_svarint(&r)
			previous = h
			if h < game.WORLD_MIN_Y || h >= game.WORLD_MAX_Y {game.reader_fail(&r)}
		}
		m = c
	case u8(Server_Kind.Bulk_Begin):
		m = Bulk_Begin {
			count = game.read_u16(&r),
		}
	case u8(Server_Kind.State):
		return State_Message{data}, true
	case u8(Server_Kind.Snapshot):
		return Snapshot_Message{data}, true
	case u8(Server_Kind.Challenge):
		c: Challenge
		for &b in c.nonce {b = game.read_u8(&r)}
		m = c
	case u8(Server_Kind.World_Changed):
		c := World_Changed {
			address = read_address(&r),
		}
		read_vars(&r, game.rules_table(), &c.rules)
		m = c
	case u8(Server_Kind.Telemetry_Ack):
		ack := Telemetry_Ack {
			day = game.read_string(&r, 10),
		}
		hi, lo := game.read_u32(&r), game.read_u32(&r)
		ack.end = u64(hi) << 32 | u64(lo)
		m = ack
	case u8(Server_Kind.Dev_Ack):
		m = Dev_Ack {
			id     = game.read_u32(&r),
			ok     = read_bool(&r),
			reason = game.read_string(&r, MAX_REASON_LENGTH),
		}
	case u8(Server_Kind.Dev_Replies):
		rs: Dev_Replies
		rs.count = int(game.read_u8(&r))
		if rs.count > MAX_DEV_REPLIES {game.reader_fail(&r)}
		for &e in rs.entries[:min(rs.count, MAX_DEV_REPLIES)] {
			e.id = game.read_string(&r, MAX_DEV_FIELD)
			e.time = i64(game.read_fixed64(&r))
			e.text = game.read_string(&r, MAX_DEV_TEXT)
			e.link = game.read_string(&r, MAX_DEV_LINK)
		}
		m = rs
	case u8(Server_Kind.Stats_Page):
		m = Stats_Page {
			page  = game.read_u16(&r),
			pages = game.read_u16(&r),
			text  = game.read_string(&r, MAX_STATS_TEXT),
		}
	case u8(Server_Kind.Packs):
		ps: Packs
		ps.content = game.read_fixed64(&r)
		ps.count = game.read_u8(&r)
		if int(ps.count) > game.MAX_PACKS {game.reader_fail(&r)}
		for i in 0 ..< min(int(ps.count), game.MAX_PACKS) {
			e := &ps.entries[i]
			e.namespace = game.read_string(&r, 32)
			e.version = game.read_string(&r, 16)
			e.size = game.read_u32(&r)
			for &b in e.sha256 {b = game.read_u8(&r)}
		}
		m = ps
	case u8(Server_Kind.Packs_Changed):
		m = Packs_Changed{game.read_fixed64(&r)}
	case u8(Server_Kind.Pack_Part):
		part := Pack_Part {
			index  = game.read_u8(&r),
			offset = game.read_u32(&r),
		}
		n := len(r.data) - r.pos
		if n < 1 || n > MAX_PACK_PART {
			game.reader_fail(&r)
		} else {
			part.data = r.data[r.pos:][:n]
			r.pos += n
		}
		m = part
	case u8(Server_Kind.Characters):
		m = Characters {
			names = game.read_string(&r, game.MAX_CHARACTERS * (game.MAX_NAME_LENGTH + 1)),
		}
	case:
		return
	}
	return m, game.reader_finish(&r)
}

// Player inputs on the wire: movement quantized to 1/127 (the client
// predicts with the quantized value too: quantize_input), look angles exact.
@(private = "file")
write_player_input :: proc(w: ^game.Writer, in_: game.Player_Input) {
	q := quantize_input(in_)
	game.write_u8(w, u8(i8(math.round(q.move.x * 127))))
	game.write_u8(w, u8(i8(math.round(q.move.y * 127))))
	game.write_f32(w, q.yaw)
	game.write_f32(w, q.pitch)
	game.write_u8(w, transmute(u8)q.buttons)
}

@(private = "file")
read_player_input :: proc(r: ^game.Reader) -> (in_: game.Player_Input) {
	mx, my := i8(game.read_u8(r)), i8(game.read_u8(r))
	if mx == -128 || my == -128 {game.reader_fail(r)}
	in_.move = {f32(mx) / 127, f32(my) / 127}
	in_.yaw = game.read_f32(r)
	in_.pitch = game.read_f32(r)
	buttons := game.read_u8(r)
	if buttons >= 1 << len(game.Button) ||
	   abs(in_.pitch) > game.PITCH_LIMIT ||
	   abs(in_.yaw) > 1e6 {game.reader_fail(r)}
	in_.buttons = transmute(bit_set[game.Button;u8])buttons
	return
}

// quantize_input is the input as the server will see it after the trip.
quantize_input :: proc(in_: game.Player_Input) -> game.Player_Input {
	q := in_
	for &v in q.move {v = math.round(clamp(v, -1, 1) * 127) / 127}
	return q
}

// write_vars / read_vars carry a variable table's struct field by field, in
// table order; numbers outside their range fail the reader.
@(private)
write_vars :: proc(w: ^game.Writer, t: base.Var_Table, data: rawptr) {
	for &v in t.vars {
		kind, offset := base.var_kind(t, &v)
		if kind == .Text {
			text := base.var_text((^base.Var_Text)(uintptr(data) + offset))
			game.write_u8(w, u8(len(text)))
			for c in transmute([]u8)text {game.write_u8(w, c)}
			continue
		}
		value := base.var_get_f64(t, data, &v)
		switch kind {
		case .Bool:
			game.write_u8(w, 1 if value != 0 else 0)
		case .Int:
			game.write_i32(w, i32(value))
		case .F32:
			game.write_f32(w, f32(value))
		case .Text, .Enum:
			panic("game rules are numbers")
		}
	}
}

@(private)
read_vars :: proc(r: ^game.Reader, t: base.Var_Table, data: rawptr) {
	for &v in t.vars {
		kind, offset := base.var_kind(t, &v)
		if kind == .Text {
			n := int(game.read_u8(r))
			buf: [base.VAR_TEXT_MAX]u8
			if n > len(buf) {game.reader_fail(r)}
			if !r.ok {return}
			for i in 0 ..< n {buf[i] = game.read_u8(r)}
			if !r.ok {return}
			base.var_text_set((^base.Var_Text)(uintptr(data) + offset), string(buf[:n]))
			continue
		}
		value: f64
		switch kind {
		case .Bool:
			b := game.read_u8(r)
			if b > 1 {game.reader_fail(r)}
			value = f64(b)
		case .Int:
			value = f64(game.read_i32(r))
		case .F32:
			value = f64(game.read_f32(r))
		case .Text, .Enum:
			panic("game rules are numbers")
		}
		if !r.ok {return}
		if kind != .Bool && (value < v.min || value > v.max) {
			game.reader_fail(r)
			return
		}
		base.var_set_f64(t, data, &v, value)
	}
}

@(private = "file")
write_position :: proc(w: ^game.Writer, p: [3]f64) {
	for v in p {game.write_f64(w, v)}
}

@(private = "file")
read_position :: proc(r: ^game.Reader) -> (p: [3]f64) {
	for &v in p {
		v = game.read_f64(r)
		if abs(v) >= game.WORLD_LIMIT {game.reader_fail(r)}
	}
	return
}

@(private = "file")
write_chunk_pos :: proc(w: ^game.Writer, c: game.Chunk_Pos) {
	for v in c {game.write_i32(w, v)}
}

@(private = "file")
write_block_pos :: proc(w: ^game.Writer, p: game.Block_Pos) {
	for v in p {game.write_i32(w, v)}
}

// read_block_pos accepts blocks inside the world only.
@(private = "file")
read_block_pos :: proc(r: ^game.Reader) -> (p: game.Block_Pos) {
	for &v in p {v = game.read_i32(r)}
	if !game.in_world(game.chunk_of(p)) {game.reader_fail(r)}
	return
}

@(private = "file")
read_block :: proc(r: ^game.Reader) -> game.Block {
	id := game.read_u16(r)
	if !game.reader_block_valid(r, id) {
		game.reader_fail(r)
		return .Air
	}
	return game.Block(id)
}

@(private = "file")
read_chunk_pos :: proc(r: ^game.Reader) -> (c: game.Chunk_Pos) {
	for &v in c {v = game.read_i32(r)}
	if !game.in_world(c) {game.reader_fail(r)}
	return
}

// Server_Info: what a server tells LAN discovery about itself (netcode
// carries it as bytes).
Server_Info :: struct {
	protocol:    u32,
	name:        string, // view into the bytes when decoded
	players:     int,
	max_players: int,
	password:    bool,
}

encode_server_info :: proc(w: ^game.Writer, i: Server_Info) {
	game.write_u32(w, i.protocol)
	game.write_string(w, i.name)
	game.write_u8(w, u8(i.players))
	game.write_u8(w, u8(i.max_players))
	game.write_u8(w, 1 if i.password else 0)
}

decode_server_info :: proc(data: []u8) -> (i: Server_Info, ok: bool) {
	r := game.reader_make(data)
	i.protocol = game.read_u32(&r)
	i.name = game.read_string(&r, MAX_SERVER_NAME)
	i.players = int(game.read_u8(&r))
	i.max_players = int(game.read_u8(&r))
	i.password = game.read_u8(&r) == 1
	return i, game.reader_finish(&r)
}

MAX_SERVER_NAME :: 48

@(private = "file")
write_address :: proc(w: ^game.Writer, a: starmap.Address) {
	g, wo := a.galaxy, a.world
	for b in g {game.write_u8(w, b)}
	for b in wo {game.write_u8(w, b)}
}

@(private = "file")
read_address :: proc(r: ^game.Reader) -> (a: starmap.Address) {
	for &b in a.galaxy {b = game.read_u8(r)}
	for &b in a.world {b = game.read_u8(r)}
	if !starmap.address_valid(a) {game.reader_fail(r)}
	return
}
