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
	[5] = "set_rule", [6] = "edit", [7] = "admin", [8] = "attack",
	[9] = "fire",
}
local SERVER_KINDS = {
	[1] = "welcome", [2] = "reject", [3] = "chunk", [4] = "unload",
	[5] = "pong", [6] = "player", [7] = "rules", [8] = "edit_result",
	[9] = "block", [10] = "column", [11] = "time", [12] = "joined",
	[13] = "left", [14] = "players", [15] = "notice", [16] = "spawn",
	[17] = "despawn", [18] = "entities", [19] = "hurt", [20] = "bulk",
	[21] = "explosion",
}

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
				local name_s = gstring(tvb, 5)
				return string.format("hello protocol=%d name=%q", u32(tvb, 1), name_s or "?")
			elseif kind == 2 then
				return string.format("input seq=%d", u32(tvb, 1))
			elseif kind == 3 then
				return string.format("ping id=%d", u32(tvb, 1))
			elseif kind == 6 then
				return string.format("edit id=%d after=%d pos=[%d %d %d] block=%d", u32(tvb, 1),
					u32(tvb, 5), i32(tvb, 9), i32(tvb, 13), i32(tvb, 17), tvb(21, 2):le_uint())
			elseif kind == 7 then
				return string.format("admin %q", gstring(tvb, 1) or "?")
			end
		else
			if kind == 1 then
				return string.format("welcome protocol=%d player=%d cheats=%d spawn=[%.1f %.1f %.1f]",
					u32(tvb, 1), tvb(9, 2):le_uint(), tvb(11, 1):uint(),
					f64(tvb, 12), f64(tvb, 20), f64(tvb, 28))
			elseif kind == 2 or kind == 15 then
				return string.format("%s %q", name, gstring(tvb, 1) or "?")
			elseif kind == 3 or kind == 4 then
				return string.format("%s pos=[%d %d %d]", name, i32(tvb, 1), i32(tvb, 5), i32(tvb, 9))
			elseif kind == 5 then
				return string.format("pong id=%d", u32(tvb, 1))
			elseif kind == 6 then
				return string.format("player acked=%d at=[%.2f %.2f %.2f]", u32(tvb, 1),
					f64(tvb, 5), f64(tvb, 13), f64(tvb, 21))
			elseif kind == 8 then
				return string.format("edit_result id=%d accepted=%d", u32(tvb, 1), tvb(5, 1):uint())
			elseif kind == 9 then
				return string.format("block pos=[%d %d %d] block=%d", i32(tvb, 1), i32(tvb, 5),
					i32(tvb, 9), tvb(13, 2):le_uint())
			elseif kind == 10 then
				return string.format("column pos=[%d %d]", i32(tvb, 1), i32(tvb, 5))
			elseif kind == 11 then
				return string.format("time %.4f", f64(tvb, 1))
			elseif kind == 12 then
				return string.format("joined player=%d name=%q", tvb(1, 2):le_uint(),
					gstring(tvb, 3) or "?")
			elseif kind == 13 then
				return string.format("left player=%d", tvb(1, 2):le_uint())
			elseif kind == 14 then
				return string.format("players tick=%d count=%d", u32(tvb, 1), tvb(5, 1):uint())
			end
		end
		return name
	end)
	if not ok then return nil end
	return text
end

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
			-- only the first fragment of a split message carries its kind.
			local text = describe(payload:tvb(), server)
			if more then text = (text and (text .. " (first fragment)")) or "fragment" end
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
