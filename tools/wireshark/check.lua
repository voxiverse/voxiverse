-- Runs the dissector over a pcap without Wireshark, through a small fake of
-- the Wireshark Lua API (enough for voxiverse.lua): every Voxiverse packet
-- must decode, none malformed. Prints what it saw. (CI also checks with the
-- real tshark.)
--
--   lua tools/wireshark/check.lua build/server.pcap

local path = arg[1] or "build/net.pcap"

-- The fake API.
local fields = {}
ProtoField = setmetatable({}, {__index = function(_, kind)
	return function(abbr, name) fields[#fields + 1] = abbr; return {abbr = abbr, name = name} end
end})
ProtoExpert = {new = function(abbr, text) return {abbr = abbr, text = text} end}
expert = {group = {MALFORMED = 1}, severity = {ERROR = 1}}
base = {DEC = 1, HEX = 2}
local proto
Proto = function(name)
	proto = {name = name, fields = {}, experts = {}}
	function proto:register_heuristic(_, fn) proto.heuristic = fn end
	return proto
end

local Range = {}
Range.__index = Range
local function range(data, off, n) return setmetatable({data = data, off = off, n = n}, Range) end
function Range:bytes() return self.data:sub(self.off + 1, self.off + self.n) end
function Range:uint() assert(self.n <= 4); local v = 0; for i = 1, self.n do v = v * 256 + self.data:byte(self.off + i) end; return v end
function Range:le_uint() assert(self.n <= 4); return (string.unpack("<I" .. self.n, self:bytes())) end
function Range:le_int() return (string.unpack("<i" .. self.n, self:bytes())) end
function Range:le_float() return (string.unpack(self.n == 4 and "<f" or "<d", self:bytes())) end
function Range:string() return self:bytes() end
function Range:tvb() return make_tvb(self:bytes()) end

function make_tvb(data)
	return setmetatable({}, {
		__index = {len = function() return #data end},
		__call = function(_, off, n)
			off = off or 0
			n = n or (#data - off)
			if off < 0 or n < 0 or off + n > #data then error("range out of bounds") end
			return range(data, off, n)
		end,
	})
end

local errors = {}
local Tree = {}
Tree.__index = Tree
local function tree() return setmetatable({}, Tree) end
function Tree:add() return tree() end
function Tree:add_le() return tree() end
function Tree:add_proto_expert_info(_, why) errors[#errors + 1] = why end
function Tree:set_text() end

dofile((arg[0]:match("^(.*)/") or ".") .. "/voxiverse.lua")
assert(proto and proto.heuristic, "the dissector did not register")

-- The pcap (LINKTYPE_IPV4, as netcode/capture.odin writes).
local f = assert(io.open(path, "rb"))
local all = f:read("a")
f:close()
local magic, _, _, _, _, _, linktype = string.unpack("<I4I2I2i4I4I4I4", all)
assert(magic == 0xa1b2c3d4 and linktype == 228, "not a LINKTYPE_IPV4 pcap")
local pos, packets, ours, counts = 25, 0, 0, {}
while pos <= #all do
	local _, _, incl = string.unpack("<I4I4I4I4", all, pos)
	local frame = all:sub(pos + 16, pos + 16 + incl - 1)
	pos = pos + 16 + incl
	packets = packets + 1
	local src_port = string.unpack(">I2", frame, 21)
	local payload = frame:sub(29)
	local pinfo = {cols = {}, src_port = src_port}
	local before = #errors
	if proto.heuristic(make_tvb(payload), pinfo, tree()) then
		ours = ours + 1
		local info = tostring(pinfo.cols.info or "?")
		for word in info:gmatch("[%a_]+") do counts[word] = (counts[word] or 0) + 1 end
		if #errors > before then print(string.format("packet %d malformed: %s (%s)", packets, errors[#errors], info)) end
	end
end
local names = {}
for k, v in pairs(counts) do names[#names + 1] = string.format("%s=%d", k, v) end
table.sort(names)
print(string.format("%d packets, %d Voxiverse, %d malformed", packets, ours, #errors))
print(table.concat(names, " "))
os.exit(#errors == 0 and ours > 0 and 0 or 1)
