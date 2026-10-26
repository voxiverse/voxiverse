-- Voxiverse protocol dissector for Wireshark / tshark.
--
-- Install: copy this file to your personal Lua plugins folder (Help >
-- About Wireshark > Folders), or load it for one run:
--   tshark -X lua_script:tools/wireshark/voxiverse.lua -r build/net.pcap
--
-- Decodes the netcode layer (netcode/conn.odin, host.odin, link.odin):
-- handshake packets and data packets with their records; and the game
-- messages inside them (game/protocol.odin), by kind, with the main fields
-- of each. A message split into fragments is labelled, not reassembled.
-- Packets are recognised by their magic ("VXV1"), on any UDP port; the
-- side that sent them is told by the port (servers use 27315..27324).

local vx = Proto("voxiverse", "Voxiverse")

local MAGIC = 0x31565856
local SERVER_PORT_FIRST, SERVER_PORT_LAST = 27315, 27324

-- Keep in step with netcode.Packet_Kind and game's Client_Kind /
-- Server_Kind (game/protocol_test.odin checks these tables).
local PACKET_KINDS = {
	[1] = "data", [2] = "connect", [3] = "challenge", [4] = "response",
	[5] = "accept", [6] = "deny", [7] = "disconnect", [8] = "discover",
	[9] = "discover_reply",
}
local CLIENT_KINDS = {
	[1] = "hello", [2] = "input", [3] = "ping", [4] = "teleport",
	[5] = "set_rule", [6] = "edit", [7] = "command", [8] = "attack",
	[9] = "fire", [10] = "chat", [11] = "inventory_request", [12] = "proof", [13] = "choose", [14] = "dial", [15] = "use_entity", [16] = "stats_request", [17] = "telemetry", [18] = "telemetry_batch", [19] = "use_block", [20] = "prediction_check",
}
local SERVER_KINDS = {
	[1] = "welcome", [2] = "reject", [3] = "chunk", [4] = "unload",
	[5] = "pong", [8] = "edit_result", [10] = "column", [20] = "bulk",
	[28] = "challenge", [29] = "characters", [30] = "world_changed",
	[33] = "stats_page", [34] = "telemetry_ack", [36] = "state", [37] = "snapshot",
}
local STATE, SNAPSHOT = 36, 37

-- The state model's kinds (game/state_kinds.odin), generated from the game's
-- types: `./build.sh schema` rewrites this block; game's
-- test_dissector_schema_current fails when it is stale.
-- schema begin (generated: ./build.sh schema)
local SCHEMA = {
  { id = 0, name = "own_player", key = "none", lane = "snapshot", fields = {
    { name = "acked", t = "u32" },
    { name = "state.position", t = "array", scalar = true, count = 3, elem = { t = "f64" } },
    { name = "state.velocity", t = "array", scalar = true, count = 3, elem = { t = "f32" } },
    { name = "state.on_ground", t = "bool" },
    { name = "state.flying", t = "bool" },
    { name = "state.crouched", t = "bool" },
    { name = "state.jump_held", t = "bool" },
    { name = "state.air_jumps", t = "u8" },
    { name = "teleports", t = "u8" },
    { name = "yaw", t = "f32" },
    { name = "pitch", t = "f32" },
  } },
  { id = 1, name = "health", key = "none", lane = "reliable", fields = {
    { name = "health", t = "f32" },
    { name = "max", t = "f32" },
  } },
  { id = 2, name = "inventory", key = "none", lane = "reliable", fields = {
    { name = "acked", t = "u32" },
    { name = "inventory.slots", t = "array", scalar = false, count = 30, elem = { t = "struct", fields = { { name = "item", t = "u16" }, { name = "count", t = "i64" }, } } },
    { name = "inventory.equipment", t = "array", scalar = false, count = 5, elem = { t = "struct", fields = { { name = "item", t = "u16" }, { name = "count", t = "i64" }, } } },
    { name = "inventory.cursor.item", t = "u16" },
    { name = "inventory.cursor.count", t = "i64" },
    { name = "inventory.selected", t = "i64" },
    { name = "inventory.chest", t = "array", scalar = false, count = 25, elem = { t = "struct", fields = { { name = "item", t = "u16" }, { name = "count", t = "i64" }, } } },
    { name = "inventory.chest_open", t = "bool" },
  } },
  { id = 3, name = "rules", key = "none", lane = "reliable", fields = {
    { name = "gravity", t = "f32" },
    { name = "terminal_velocity", t = "f32" },
    { name = "walk_speed", t = "f32" },
    { name = "sprint_speed", t = "f32" },
    { name = "sneak_speed", t = "f32" },
    { name = "jump_height", t = "f32" },
    { name = "fly_speed", t = "f32" },
    { name = "fly_sprint_speed", t = "f32" },
    { name = "ground_control", t = "f32" },
    { name = "air_control", t = "f32" },
    { name = "reach", t = "f32" },
    { name = "allow_flying", t = "bool" },
    { name = "day_length", t = "f32" },
    { name = "daylight_cycle", t = "bool" },
    { name = "drops", t = "bool" },
    { name = "damage", t = "bool" },
    { name = "death_drops", t = "bool" },
    { name = "random_tick_speed", t = "i32" },
  } },
  { id = 4, name = "clock", key = "none", lane = "reliable", fields = {
    { name = "time", t = "f64" },
    { name = "tick", t = "u32" },
  } },
  { id = 5, name = "grants", key = "none", lane = "reliable", fields = {
    { name = "text", t = "string", max = 16384 },
    { name = "commands", t = "string", max = 16384 },
  } },
  { id = 6, name = "variables", key = "none", lane = "reliable", fields = {
    { name = "text", t = "string", max = 4096 },
  } },
  { id = 7, name = "selection", key = "none", lane = "reliable", fields = {
    { name = "corners", t = "array", scalar = false, count = 2, elem = { t = "union", variants = { { t = "array", scalar = true, count = 3, elem = { t = "i32" } }, } } },
  } },
  { id = 8, name = "player", key = "player", lane = "reliable", fields = {
    { name = "name", t = "string", max = 16 },
    { name = "worn", t = "array", scalar = true, count = 4, elem = { t = "u16" } },
  } },
  { id = 9, name = "player_motion", key = "player", lane = "snapshot", fields = {
    { name = "position", t = "array", scalar = true, count = 3, elem = { t = "f64" } },
    { name = "yaw", t = "f32" },
    { name = "pitch", t = "f32" },
    { name = "flying", t = "bool" },
    { name = "crouched", t = "bool" },
  } },
  { id = 10, name = "entity", key = "entity", lane = "reliable", fields = {
    { name = "kind", t = "enum", signed = false },
    { name = "stack.item", t = "u16" },
    { name = "stack.count", t = "i64" },
  } },
  { id = 11, name = "entity_motion", key = "entity", lane = "snapshot", fields = {
    { name = "position", t = "array", scalar = true, count = 3, elem = { t = "f64" } },
    { name = "yaw", t = "f32" },
    { name = "pitch", t = "f32" },
    { name = "flags", t = "bits" },
  } },
  { id = 12, name = "block", key = "block", lane = "reliable", fields = {
    { name = "block", t = "enum", signed = false },
    { name = "heard", t = "bool" },
  } },
  { id = 13, name = "notice", key = "none", lane = "event", fields = {
    { name = "text", t = "string", max = 1024 },
  } },
  { id = 14, name = "chat_line", key = "none", lane = "event", fields = {
    { name = "id", t = "u32" },
    { name = "sender", t = "u16" },
    { name = "text", t = "string", max = 1024 },
  } },
  { id = 15, name = "chat_delete", key = "none", lane = "event", fields = {
    { name = "id", t = "u32" },
  } },
  { id = 16, name = "entity_hurt", key = "none", lane = "event", fields = {
    { name = "entity", t = "u32" },
  } },
  { id = 17, name = "entity_died", key = "none", lane = "event", fields = {
    { name = "entity", t = "u32" },
  } },
  { id = 18, name = "explosion", key = "none", lane = "event", fields = {
    { name = "position", t = "array", scalar = true, count = 3, elem = { t = "f64" } },
    { name = "radius", t = "f32" },
  } },
}
-- schema end

local f = vx.fields
f.kind = ProtoField.uint8("voxiverse.kind", "Packet", base.DEC, PACKET_KINDS)
f.token = ProtoField.uint32("voxiverse.token", "Token", base.HEX)
f.seq = ProtoField.uint16("voxiverse.seq", "Sequence")
f.ack = ProtoField.uint16("voxiverse.ack", "Ack")
f.ack_bits = ProtoField.uint32("voxiverse.ack_bits", "Ack bits", base.HEX)
f.before = ProtoField.uint16("voxiverse.reliable_ack", "Reliable messages before")
f.salt = ProtoField.uint64("voxiverse.salt", "Salt", base.HEX)
f.cookie = ProtoField.bytes("voxiverse.cookie", "Cookie")
f.proof = ProtoField.bytes("voxiverse.proof", "Password proof")
f.reason = ProtoField.string("voxiverse.reason", "Reason")
f.nonce = ProtoField.uint32("voxiverse.nonce", "Nonce", base.HEX)
f.instance = ProtoField.uint64("voxiverse.instance", "Server instance", base.HEX)
f.info = ProtoField.bytes("voxiverse.info", "Server info")
f.record = ProtoField.bytes("voxiverse.record", "Record")
f.reliable = ProtoField.bool("voxiverse.reliable", "Reliable")
f.more = ProtoField.bool("voxiverse.more", "More fragments follow")
f.id = ProtoField.uint16("voxiverse.message_id", "Message id")
f.length = ProtoField.uint16("voxiverse.length", "Length")
f.message = ProtoField.string("voxiverse.message", "Message")

local e_malformed = ProtoExpert.new("voxiverse.malformed", "Malformed Voxiverse packet",
	expert.group.MALFORMED, expert.severity.ERROR)
vx.experts = {e_malformed}

-- The game's encodings (game/codec.odin): little-endian, varint lengths.
local function varint(tvb, off)
	local v, shift = 0, 0
	for i = 0, 4 do
		if off + i >= tvb:len() then return nil, off end
		local b = tvb(off + i, 1):uint()
		v = v + (b % 128) * (2 ^ shift)
		if b < 128 then return v, off + i + 1 end
		shift = shift + 7
	end
	return nil, off
end

local function gstring(tvb, off)
	local n, o = varint(tvb, off)
	if not n or o + n > tvb:len() then return nil, off end
	return tvb(o, n):string(), o + n
end

local function u32(tvb, off) return tvb(off, 4):le_uint() end
local function i32(tvb, off) return tvb(off, 4):le_int() end
local function f32(tvb, off) return tvb(off, 4):le_float() end
local function f64(tvb, off) return tvb(off, 8):le_float() end

-- The state model's wire (game/replica.odin), decoded from SCHEMA. Numbers
-- are Lua doubles: exact to 2^53, which no field reaches. A change carries
-- only the fields its mask names, as deltas: shown as "+n" (the dissector has
-- no baseline).
local function varint64(tvb, off)
	local v, shift = 0, 0
	for i = 0, 9 do
		if off + i >= tvb:len() then error("short varint") end
		local b = tvb(off + i, 1):uint()
		v = v + (b % 128) * (2 ^ shift)
		if b < 128 then return v, off + i + 1 end
		shift = shift + 7
	end
	error("varint too long")
end

local function unzigzag(v)
	if v % 2 == 0 then return v / 2 end
	return -(v + 1) / 2
end

local function whole(tvb, off, ty)
	local t = ty.t
	if t == "bool" then
		return tvb(off, 1):uint() ~= 0 and "true" or "false", off + 1
	elseif t:match("^u%d+$") or t == "bits" or (t == "enum" and not ty.signed) then
		local v, o = varint64(tvb, off)
		return string.format("%.0f", v), o
	elseif t:match("^i%d+$") or t == "enum" then
		local v, o = varint64(tvb, off)
		return string.format("%.0f", unzigzag(v)), o
	elseif t == "f32" then
		return string.format("%g", f32(tvb, off)), off + 4
	elseif t == "f64" then
		return string.format("%g", f64(tvb, off)), off + 8
	elseif t == "array" then
		local parts = {}
		for i = 1, ty.count do parts[i], off = whole(tvb, off, ty.elem) end
		return "[" .. table.concat(parts, " ") .. "]", off
	elseif t == "struct" then
		local parts = {}
		for i, fd in ipairs(ty.fields) do
			local text
			text, off = whole(tvb, off, fd)
			parts[i] = fd.name .. "=" .. text
		end
		return "{" .. table.concat(parts, " ") .. "}", off
	elseif t == "union" then
		local tag = tvb(off, 1):uint()
		off = off + 1
		if tag == 0 then return "nil", off end
		local variant = ty.variants[tag]
		if not variant then error("bad union tag") end
		return whole(tvb, off, variant)
	elseif t == "string" then
		local n, o = varint64(tvb, off)
		if o + n > tvb:len() then error("short string") end
		return string.format("%q", tvb(o, n):string()), o + n
	end
	error("unknown type " .. t)
end

local function delta(tvb, off, ty)
	local t = ty.t
	if t:match("^[ui]%d+$") then
		local v, o = varint64(tvb, off)
		return string.format("%+.0f", unzigzag(v)), o
	elseif t == "array" and not ty.scalar then
		local n, o = varint64(tvb, off)
		local parts = {}
		for i = 1, n do
			local index
			index, o = varint64(tvb, o)
			local text
			text, o = whole(tvb, o, ty.elem)
			parts[i] = string.format("%.0f:%s", index, text)
		end
		return "[" .. table.concat(parts, " ") .. "]", o
	end
	return whole(tvb, off, ty)
end

local function key_text(tvb, off, key, prev)
	if key == "none" then return "", off, prev end
	if key == "player" or key == "entity" then
		local d, o = varint64(tvb, off)
		local id = (prev or 0) + d
		return string.format("#%.0f", id), o, id
	end
	-- block: (local index + 1) in the chunk of the last, else 0, chunk, index
	local head, o = varint64(tvb, off)
	if head ~= 0 then return string.format("@%.0f", head - 1), o, prev end
	local cx, cy, cz, index
	cx, o = varint64(tvb, o); cy, o = varint64(tvb, o); cz, o = varint64(tvb, o)
	index, o = varint64(tvb, o)
	return string.format("@[%d %d %d]+%.0f", unzigzag(cx), unzigzag(cy), unzigzag(cz), index), o, prev
end

local OPS = {[0] = "change", [1] = "create", [2] = "remove"}

-- describe_state: "state tick=N kind#key op{field=value ...} ..." (or the
-- snapshot's, with its baseline and part); errors if it does not decode.
function describe_state(tvb, snapshot)
	local off = 1
	local tick, back, part, parts
	tick, off = varint64(tvb, off)
	local head = string.format("%s tick=%.0f", snapshot and "snapshot" or "state", tick)
	if snapshot then
		back, off = varint64(tvb, off)
		part, parts = tvb(off, 1):uint(), tvb(off + 1, 1):uint()
		off = off + 2
		if parts < 1 or parts > 8 or part >= parts then error("bad snapshot part") end
		head = head .. string.format(" back=%.0f part=%d/%d", back, part + 1, parts)
	end
	local out = {head}
	local len = tvb:len()
	while off < len do
		local id, count
		id, off = varint64(tvb, off)
		count, off = varint64(tvb, off)
		local kind = SCHEMA[id + 1]
		if not kind then error("unknown kind id") end
		if count < 1 or count > len - off then error("bad count") end
		local prev
		for _ = 1, count do
			local fields = {}
			if kind.lane == "event" then
				for _, fd in ipairs(kind.fields) do
					local text
					text, off = whole(tvb, off, fd)
					fields[#fields + 1] = fd.name .. "=" .. text
				end
				out[#out + 1] = string.format("%s{%s}", kind.name, table.concat(fields, " "))
			else
				local h
				h, off = varint64(tvb, off)
				local op = h % 4
				local mask = math.floor(h / 4)
				if op == 3 then error("bad op") end
				local key
				key, off, prev = key_text(tvb, off, kind.key, prev)
				if op == 1 then
					for _, fd in ipairs(kind.fields) do
						local text
						text, off = whole(tvb, off, fd)
						fields[#fields + 1] = fd.name .. "=" .. text
					end
				elseif op == 0 then
					for i, fd in ipairs(kind.fields) do
						if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
							local text
							text, off = delta(tvb, off, fd)
							fields[#fields + 1] = fd.name .. "=" .. text
						end
					end
					if mask >= 2 ^ #kind.fields then error("mask past the fields") end
				end
				out[#out + 1] = string.format("%s%s %s{%s}", kind.name, key, OPS[op], table.concat(fields, " "))
			end
		end
	end
	if off ~= len then error("trailing bytes") end
	local text = table.concat(out, " ")
	if #text > 300 then text = text:sub(1, 297) .. "..." end
	return text
end

-- describe: a one-line summary of a game message (the first bytes of a
-- record's payload). Returns nil if it does not decode.
local function describe(tvb, from_server)
	local kind = tvb(0, 1):uint()
	local names = from_server and SERVER_KINDS or CLIENT_KINDS
	local name = names[kind]
	if not name then return nil end
	local ok, text = pcall(function()
		if not from_server then
			if kind == 1 then
				local name_s = gstring(tvb, 37)
				return string.format("hello protocol=%d character=%q", u32(tvb, 1), name_s or "?")
			elseif kind == 2 then
				return string.format("input seq=%d", u32(tvb, 1))
			elseif kind == 3 then
				return string.format("ping id=%d", u32(tvb, 1))
			elseif kind == 6 then
				return string.format("edit id=%d after=%d pos=[%d %d %d] block=%d", u32(tvb, 1),
					u32(tvb, 5), i32(tvb, 9), i32(tvb, 13), i32(tvb, 17), tvb(21, 2):le_uint())
			elseif kind == 7 then
				return string.format("command %q", gstring(tvb, 1) or "?")
			elseif kind == 10 then
				return string.format("chat %q", gstring(tvb, 1) or "?")
			elseif kind == 20 then
				return string.format("prediction_check seq=%d position=%08x velocity=%08x on_ground=%08x flying=%08x crouched=%08x jump_held=%08x air_jumps=%08x",
					u32(tvb, 1), u32(tvb, 5), u32(tvb, 9), u32(tvb, 13), u32(tvb, 17), u32(tvb, 21), u32(tvb, 25), u32(tvb, 29))
			elseif kind == 11 then
				return string.format("inventory_request seq=%d action=%d slot=%d arg=%d", u32(tvb, 1),
					tvb(5, 1):uint(), tvb(6, 1):int(), tvb(7, 2):le_uint())
			end
		else
			if kind == 1 then
				return string.format("welcome protocol=%d player=%d spawn=[%.1f %.1f %.1f]",
					u32(tvb, 1), tvb(9, 2):le_uint(), f64(tvb, 11), f64(tvb, 19), f64(tvb, 27))
			elseif kind == 2 then
				return string.format("%s %q", name, gstring(tvb, 1) or "?")
			elseif kind == 3 or kind == 4 then
				return string.format("%s pos=[%d %d %d]", name, i32(tvb, 1), i32(tvb, 5), i32(tvb, 9))
			elseif kind == 5 then
				return string.format("pong id=%d", u32(tvb, 1))
			elseif kind == 8 then
				return string.format("edit_result id=%d accepted=%d", u32(tvb, 1), tvb(5, 1):uint())
			elseif kind == 10 then
				return string.format("column pos=[%d %d]", i32(tvb, 1), i32(tvb, 5))
			elseif kind == STATE or kind == SNAPSHOT then
				return describe_state(tvb, kind == SNAPSHOT)
			end
		end
		return name
	end)
	if not ok then
		if (kind == STATE or kind == SNAPSHOT) and from_server then return nil, text end
		return nil
	end
	return text
end

-- Per direction of a flow: whether the last record had more fragments to come.
local pending_fragment = {}

local function from_server(pinfo)
	return pinfo.src_port >= SERVER_PORT_FIRST and pinfo.src_port <= SERVER_PORT_LAST
end

local function malformed(tree, tvb, why)
	tree:add_proto_expert_info(e_malformed, why)
	return tvb:len()
end

function vx.dissector(tvb, pinfo, root)
	if tvb:len() < 5 or tvb(0, 4):le_uint() ~= MAGIC then return 0 end
	pinfo.cols.protocol = "Voxiverse"
	local tree = root:add(vx, tvb())
	local kind = tvb(4, 1):uint()
	tree:add(f.kind, tvb(4, 1))
	local kind_name = PACKET_KINDS[kind]
	if not kind_name then return malformed(tree, tvb, "unknown packet kind") end
	local server = from_server(pinfo)
	local len = tvb:len()

	if kind == 1 then -- data
		if len < 19 then return malformed(tree, tvb, "short data header") end
		tree:add_le(f.token, tvb(5, 4))
		tree:add_le(f.seq, tvb(9, 2))
		tree:add_le(f.ack, tvb(11, 2))
		tree:add_le(f.ack_bits, tvb(13, 4))
		tree:add_le(f.before, tvb(17, 2))
		local off = 19
		local summary = {}
		local flow = tostring(pinfo.src_port) .. ">" .. tostring(pinfo.dst_port)
		while off < len do
			local flags = tvb(off, 1):uint()
			local reliable = flags % 2 == 1
			local more = math.floor(flags / 2) % 2 == 1
			if flags > 3 then return malformed(tree, tvb, "bad record flags") end
			local head = 1 + (reliable and 2 or 0) + 2
			if off + head > len then return malformed(tree, tvb, "short record header") end
			local id_off = off + 1
			local n_off = id_off + (reliable and 2 or 0)
			local n = tvb(n_off, 2):le_uint()
			if n == 0 or off + head + n > len then return malformed(tree, tvb, "bad record length") end
			local payload = tvb(off + head, n)
			local rec = tree:add(f.record, tvb(off, head + n))
			rec:add(f.reliable, reliable)
			rec:add(f.more, more)
			if reliable then rec:add_le(f.id, tvb(id_off, 2)) end
			rec:add_le(f.length, tvb(n_off, 2))
			-- A message starts where the previous record had no MORE flag;
			-- only the first fragment of a split message carries its kind
			-- (the records that follow it, up to one without MORE, are labelled).
			local continuing = pending_fragment[flow]
			local text, why
			if not continuing then text, why = describe(payload:tvb(), server) end
			pending_fragment[flow] = more
			if more then text = (text and (text .. " (first fragment)")) or "fragment" end
			if why and not more and not continuing then
				tree:add_proto_expert_info(e_malformed, "does not decode: " .. why)
			end
			rec:add(f.message, payload, text or "fragment / unknown")
			rec:set_text((reliable and "reliable " or "unreliable ") .. (text or "fragment"))
			summary[#summary + 1] = text and text:match("^(%S+)") or "fragment"
			off = off + head + n
		end
		pinfo.cols.info = string.format("%s seq=%d ack=%d %s", server and "S->C" or "C->S",
			tvb(9, 2):le_uint(), tvb(11, 2):le_uint(), table.concat(summary, ","))
	elseif kind == 2 then -- connect
		if len < 13 then return malformed(tree, tvb, "short connect") end
		tree:add_le(f.salt, tvb(5, 8))
		pinfo.cols.info = "connect"
	elseif kind == 3 then -- challenge
		if len < 29 then return malformed(tree, tvb, "short challenge") end
		tree:add_le(f.salt, tvb(5, 8))
		tree:add(f.cookie, tvb(13, 16))
		pinfo.cols.info = "challenge"
	elseif kind == 4 then -- response
		if len < 45 then return malformed(tree, tvb, "short response") end
		tree:add_le(f.salt, tvb(5, 8))
		tree:add(f.cookie, tvb(13, 16))
		tree:add(f.proof, tvb(29, 16))
		pinfo.cols.info = "response"
	elseif kind == 5 then -- accept
		if len < 17 then return malformed(tree, tvb, "short accept") end
		tree:add_le(f.salt, tvb(5, 8))
		tree:add_le(f.token, tvb(13, 4))
		pinfo.cols.info = "accept"
	elseif kind == 6 or kind == 7 then -- deny / disconnect
		local at = (kind == 6) and 13 or 9
		if len < at + 2 then return malformed(tree, tvb, "short " .. kind_name) end
		if kind == 6 then tree:add_le(f.salt, tvb(5, 8)) else tree:add_le(f.token, tvb(5, 4)) end
		local n = tvb(at, 2):le_uint()
		if at + 2 + n > len then return malformed(tree, tvb, "bad reason length") end
		local reason = n > 0 and tvb(at + 2, n):string() or ""
		if n > 0 then tree:add(f.reason, tvb(at + 2, n)) end
		pinfo.cols.info = string.format("%s %q", kind_name, reason)
	elseif kind == 8 then -- discover
		if len < 9 then return malformed(tree, tvb, "short discover") end
		tree:add_le(f.nonce, tvb(5, 4))
		pinfo.cols.info = "discover"
	elseif kind == 9 then -- discover reply
		if len < 19 then return malformed(tree, tvb, "short discover reply") end
		tree:add_le(f.nonce, tvb(5, 4))
		tree:add_le(f.instance, tvb(9, 8))
		local n = tvb(17, 2):le_uint()
		if 19 + n > len then return malformed(tree, tvb, "bad info length") end
		if n > 0 then tree:add(f.info, tvb(19, n)) end
		pinfo.cols.info = "discover_reply"
	end
	return len
end

-- Any UDP packet that starts with the magic.
local function heuristic(tvb, pinfo, root)
	if tvb:len() < 5 or tvb(0, 4):le_uint() ~= MAGIC then return false end
	vx.dissector(tvb, pinfo, root)
	return true
end
vx:register_heuristic("udp", heuristic)
