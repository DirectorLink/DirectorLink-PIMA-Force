--[[
  PIMA FORCE JSON interface ("Force Interface JSON Format Specification" v2.4)

  Pure Lua 5.1 / LuaJIT helpers with no Control4 dependencies, so they can be
  unit tested off the controller: JSON codec, stream framing, Windows-1255
  text, frame builders and decoders for the panel's parameters and events.

  Transport facts (spec + field reports from efic1/C4-PimaForce,
  amithalp/pima-force-ha-integration, electricmonk/homebridge-pima-force):
    * The panel ("AS") is the TCP client; the home automation side ("HA")
      listens. Frames are bare JSON objects back to back - no length prefix,
      no delimiter. The 'null' heartbeat is padded with 0x00 bytes.
    * Every frame carries frame_type, counter (1-9999) and account.
    * HA must ACK every EVENT / DATA / null frame with kc:1 and a numeric
      account, otherwise the panel NAKs or hangs up.
    * Text (zone names, NAK reasons) arrives as raw Windows-1255 bytes.
]]

local F = {}

local floor = math.floor

---------------------------------------------------------------------------
-- Protocol constants
---------------------------------------------------------------------------
F.OPTYPE = {
	AWAY = 12, HOME1 = 13, HOME2 = 14, HOME3 = 15, HOME4 = 16, SHABBAT = 43,
	DISARM = 17, OUTPUT_ON = 35, OUTPUT_OFF = 36,
}

F.PARAM = {
	EXIT_TIME = 180,
	ZONE_NAME = 260,
	USER_NAME = 411,
	ZONE_COUNT = 2148,
	ZONE_STATUS = 2149,
	BYPASS = 2150,
	FAULTS = 2250,
	OUTPUTS = 2301,
	SYSTEM_KEY = 2310,
}

-- 2310 System Key Status values
F.KEY_NOT_EXIST = 1
F.KEY_DISARMED = 2
F.KEY_ARM_NAMES = {
	[3] = "Away", [4] = "Home", [5] = "Night", [6] = "Home 3", [7] = "Home 4",
	[8] = "Shabbat", [9] = "Shabbat",
}

-- 2149 zone status bits (above the zone-number byte)
F.ZONE_BIT = {
	SUPERVISION = 0, LOW_BATTERY = 1, SHORT = 2, TAMPER = 3, SOAK = 4, CHIME = 5,
	ANTI_MASK = 6, MANUAL_BYPASS = 7, AUTO_BYPASS = 8, ALARMED = 9, ARMED = 10,
	OPEN = 11, DURESS = 12, FIRE = 13, MEDICAL = 14, PANIC = 15,
}

-- Appendix E fault ids. For 30-38 the order byte is a comm path, not a device.
F.FAULTS = {
	[1] = "AC Loss", [2] = "Low Battery", [3] = "Panel Tamper 1", [4] = "Panel Tamper 2",
	[5] = "Panel Aux Voltage", [6] = "PSTN Fault (DC)", [7] = "PSTN Fault (Dial Tone)",
	[8] = "Panel Low DC", [9] = "Zone Expander Fault", [10] = "Zone Expander Tamper",
	[11] = "Zone Expander Voltage", [12] = "Zone Expander AC", [13] = "Zone Expander Low Battery",
	[14] = "Zone Expander Aux Voltage", [15] = "Local Expander Fault", [16] = "Local Expander Voltage",
	[17] = "Local Expander Aux Voltage", [18] = "Output Expander Fault", [19] = "Output Expander Tamper",
	[20] = "Output Expander Voltage", [21] = "Output Expander AC", [22] = "Output Expander Low Battery",
	[23] = "Output Expander Aux Voltage", [24] = "Keypad Fault", [25] = "Keypad Tamper",
	[26] = "Keypad Voltage", [27] = "Wireless Receiver Fault", [28] = "Wireless Receiver Tamper",
	[29] = "Wireless Receiver Voltage", [30] = "Station PSTN Communication", [31] = "Station GPRS",
	[32] = "Station GSM Voice", [33] = "Station Network Communication", [35] = "Contact PSTN Communication",
	[36] = "Contact GSM Voice", [38] = "Contact SMS", [39] = "GSM Transmitter", [40] = "GSM Link 1",
	[41] = "GSM Link 2", [42] = "GSM SIM 1", [43] = "GSM SIM 2", [44] = "GSM Boot 1", [45] = "GSM Boot 2",
	[46] = "GSM Registration 1", [47] = "GSM Registration 2", [48] = "GPRS Registration 1",
	[49] = "GPRS Registration 2", [50] = "GSM No SIM 1", [51] = "GSM No SIM 2", [52] = "GSM SIM PIN 1",
	[53] = "GSM SIM PIN 2", [54] = "GSM SIM Lock 1", [55] = "GSM SIM Lock 2", [56] = "GSM Module",
	[57] = "Network", [58] = "Network Invalid MAC", [59] = "Wireless Receiver Jamming",
	[60] = "Zone Tamper", [61] = "Anti-Mask Alarm", [62] = "Wireless Zone Loss",
	[63] = "Wireless Zone Fire Loss", [64] = "Wireless Zone Low Battery", [65] = "Wireless Zone Anti-Mask",
	[66] = "Invalid Code Alarm", [67] = "External Siren", [68] = "Internal Siren", [69] = "Time Not Set",
	[70] = "Wireless Zone End Of Life", [71] = "Wireless Zone Low Sensitivity",
	[72] = "Wireless Zone Clean Me", [73] = "Wireless Zone Power", [74] = "Wireless Zone AC",
	[75] = "Wireless Zone Trouble", [76] = "Wireless Portable Unit Low Battery",
	[77] = "Wireless Siren Loss", [78] = "Wireless Siren Low Battery", [79] = "Wireless Siren Tamper",
	[80] = "Wireless Repeater Loss", [81] = "Wireless Repeater Low Battery",
	[82] = "Wireless Repeater Tamper", [83] = "Wireless Repeater Jamming", [84] = "Wireless Repeater AC",
	[85] = "Wireless Gas 1", [86] = "Wireless Gas 2", [87] = "Wireless Gas 3", [88] = "Wireless Gas 4",
	[89] = "Zone Expander Genuine", [90] = "Wireless Receiver Genuine", [91] = "Output Expander Genuine",
	[92] = "Keypad Genuine", [93] = "Local Expander Genuine", [95] = "Wireless Arming Station Loss",
	[96] = "Wireless Arming Station Low Battery", [97] = "Wireless Arming Station Tamper",
	[98] = "Wireless Arming Station Not Enrolled",
}
-- Faults whose order byte is a zone number
F.ZONE_FAULTS = { [60] = true, [61] = true, [62] = true, [63] = true, [64] = true, [65] = true,
	[70] = true, [71] = true, [72] = true, [73] = true, [74] = true, [75] = true }

-- Appendix A CID events. Qualifier 1 = new / disarm / open / on,
-- 3 = restore / arm / closed / off.
--   kind: alarm | arm | zone | bypass | output | trouble | config | info
F.CID = {
	[100] = { kind = "alarm", alarm = "Medical", text = "Medical alarm" },
	[110] = { kind = "alarm", alarm = "Fire", text = "Fire alarm" },
	[115] = { kind = "alarm", alarm = "Fire", text = "Keypad fire alarm" },
	[120] = { kind = "alarm", alarm = "Panic", text = "Panic alarm" },
	[121] = { kind = "alarm", alarm = "Duress", text = "Duress alarm" },
	[122] = { kind = "alarm", alarm = "Panic", text = "Silent panic alarm" },
	[130] = { kind = "alarm", alarm = "Burglary", text = "Burglary alarm" },
	[137] = { kind = "trouble", text = "Panel tamper" },
	[138] = { kind = "info", text = "Pre-alarm" },
	[143] = { kind = "trouble", text = "Expander fault" },
	[144] = { kind = "trouble", text = "Zone cut/short" },
	[145] = { kind = "trouble", text = "Expander tamper" },
	[301] = { kind = "trouble", text = "AC loss" },
	[302] = { kind = "trouble", text = "Low battery" },
	[305] = { kind = "info", text = "System power-up" },
	[306] = { kind = "config", text = "Panel programming changed" },
	[312] = { kind = "trouble", text = "Aux voltage fault" },
	[321] = { kind = "trouble", text = "External siren trouble" },
	[322] = { kind = "trouble", text = "Internal siren trouble" },
	[338] = { kind = "trouble", text = "Expander low battery" },
	[342] = { kind = "trouble", text = "Expander AC fault" },
	[344] = { kind = "trouble", text = "Wireless jamming" },
	[350] = { kind = "trouble", text = "Monitoring station communication trouble" },
	[351] = { kind = "trouble", text = "Communication fault" },
	[373] = { kind = "trouble", text = "Wireless detector trouble" },
	[381] = { kind = "trouble", text = "Wireless zone supervision loss" },
	[384] = { kind = "trouble", text = "Wireless zone low battery" },
	[400] = { kind = "arm", text = "Master code" },
	[401] = { kind = "arm", text = "User code" },
	[403] = { kind = "arm", text = "Auto arm" },
	[407] = { kind = "arm", text = "Remote" },
	[408] = { kind = "arm", text = "Fast arm" },
	[409] = { kind = "arm", text = "Key switch" },
	[441] = { kind = "arm", text = "Home/Shabbat arm" },
	[412] = { kind = "info", text = "Remote upload/download" },
	[421] = { kind = "info", text = "Access denied" },
	[454] = { kind = "info", text = "Inactivity" },
	[570] = { kind = "bypass", text = "Zone bypass" },
	[601] = { kind = "info", text = "Manual test" },
	[602] = { kind = "info", text = "Periodic test" },
	[625] = { kind = "info", text = "Time/date changed" },
	[760] = { kind = "zone", text = "Zone open/close" },
	[770] = { kind = "output", text = "Output on/off" },
	-- standard Contact-ID codes a panel may send over SIA DC-09
	[131] = { kind = "alarm", alarm = "Burglary", text = "Perimeter alarm" },
	[132] = { kind = "alarm", alarm = "Burglary", text = "Interior alarm" },
	[133] = { kind = "alarm", alarm = "Burglary", text = "24-hour alarm" },
	[134] = { kind = "alarm", alarm = "Burglary", text = "Entry/exit alarm" },
	[151] = { kind = "alarm", alarm = "Gas", text = "Gas alarm" },
	[154] = { kind = "alarm", alarm = "Water", text = "Water leak alarm" },
	[162] = { kind = "alarm", alarm = "Carbon Monoxide", text = "Carbon monoxide alarm" },
	[402] = { kind = "arm", text = "Group" },
	[406] = { kind = "info", text = "Alarm cancelled by user" },
	[456] = { kind = "arm", text = "Partial arm" },
}
-- Arm reports that mean a Home (partial) arm
F.CID_HOME_ARM = { [441] = true, [456] = true }

F.MAX_WRITE_BYTES = 250

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
function F.hasBit(value, bitIndex)
	return floor((value or 0) / 2 ^ bitIndex) % 2 == 1
end

function F.setBit(value, bitIndex, on)
	value = value or 0
	local has = F.hasBit(value, bitIndex)
	if on and not has then return value + 2 ^ bitIndex end
	if not on and has then return value - 2 ^ bitIndex end
	return value
end

function F.frameType(frame)
	return string.upper(tostring(frame.frame_type or ""))
end

---------------------------------------------------------------------------
-- JSON
---------------------------------------------------------------------------
-- Decoder that keeps string bytes as-is (the panel sends Windows-1255 bytes
-- inside strings, which strict UTF-8 decoders reject). \uXXXX escapes are
-- converted to UTF-8.

local function utf8Char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
	if cp < 0x10000 then
		return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
	end
	return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64,
		0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end
F.utf8Char = utf8Char

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local decodeValue

local function skipWs(s, i)
	return (s:find("[^ \t\r\n]", i)) or (#s + 1)
end

local function decodeString(s, i)
	-- s:sub(i, i) == '"'
	local parts, j = {}, i + 1
	while true do
		local q = s:find('["\\]', j)
		if not q then return nil, "unterminated string" end
		parts[#parts + 1] = s:sub(j, q - 1)
		if s:sub(q, q) == '"' then return table.concat(parts), q + 1 end
		local e = s:sub(q + 1, q + 1)
		if e == "u" then
			local hex = s:sub(q + 2, q + 5)
			local cp = tonumber(hex, 16)
			if not cp or #hex ~= 4 then return nil, "bad \\u escape" end
			local nextPos = q + 6
			if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nextPos, nextPos + 1) == "\\u" then
				local lo = tonumber(s:sub(nextPos + 2, nextPos + 5), 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
					nextPos = nextPos + 6
				end
			end
			parts[#parts + 1] = utf8Char(cp)
			j = nextPos
		elseif ESCAPES[e] then
			parts[#parts + 1] = ESCAPES[e]
			j = q + 2
		else
			return nil, "bad escape"
		end
	end
end

local function decodeArray(s, i)
	local arr, n = {}, 0
	i = skipWs(s, i + 1)
	if s:sub(i, i) == "]" then return arr, i + 1 end
	while true do
		local v, nextPos = decodeValue(s, i)
		if type(nextPos) ~= "number" then return nil, nextPos end
		n = n + 1
		arr[n] = v
		i = skipWs(s, nextPos)
		local c = s:sub(i, i)
		if c == "]" then return arr, i + 1 end
		if c ~= "," then return nil, "expected , or ] in array" end
		i = skipWs(s, i + 1)
	end
end

local function decodeObject(s, i)
	local obj = {}
	i = skipWs(s, i + 1)
	if s:sub(i, i) == "}" then return obj, i + 1 end
	while true do
		if s:sub(i, i) ~= '"' then return nil, "expected key" end
		local key, nextPos = decodeString(s, i)
		if not key then return nil, nextPos end
		i = skipWs(s, nextPos)
		if s:sub(i, i) ~= ":" then return nil, "expected :" end
		local v
		v, nextPos = decodeValue(s, skipWs(s, i + 1))
		if type(nextPos) ~= "number" then return nil, nextPos end
		obj[key] = v
		i = skipWs(s, nextPos)
		local c = s:sub(i, i)
		if c == "}" then return obj, i + 1 end
		if c ~= "," then return nil, "expected , or } in object" end
		i = skipWs(s, i + 1)
	end
end

decodeValue = function(s, i)
	i = skipWs(s, i)
	local c = s:sub(i, i)
	if c == "{" then return decodeObject(s, i) end
	if c == "[" then return decodeArray(s, i) end
	if c == '"' then return decodeString(s, i) end
	if s:sub(i, i + 3) == "true" then return true, i + 4 end
	if s:sub(i, i + 4) == "false" then return false, i + 5 end
	if s:sub(i, i + 3) == "null" then return nil, i + 4 end
	local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
	if num and num ~= "" and num ~= "-" then return tonumber(num), i + #num end
	return nil, "unexpected character at " .. i
end

-- Returns value or nil, error. (Internally every decoder returns value,
-- nextPosition on success and nil, message on failure; JSON null is nil
-- with a numeric position.)
function F.decode(s)
	local ok, v, nextPos = pcall(decodeValue, s, 1)
	if not ok then return nil, tostring(v) end
	if type(nextPos) ~= "number" then return nil, nextPos end
	return v
end

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' end
		if c == "\\" then return "\\\\" end
		return string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function encodeValue(v)
	local t = type(v)
	if t == "string" then return encodeString(v) end
	if t == "number" then
		if v == floor(v) then return string.format("%d", v) end
		return tostring(v)
	end
	if t == "boolean" then return tostring(v) end
	if t == "table" then
		if v[1] ~= nil or next(v) == nil and getmetatable(v) == F.ARRAY then
			local parts = {}
			for i = 1, #v do parts[i] = encodeValue(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		-- Objects: keys sorted, which is also the field order of the frames
		-- captured from working integrations
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(v[k]) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

F.ARRAY = {}
function F.encode(v) return encodeValue(v) end

---------------------------------------------------------------------------
-- Stream framing
---------------------------------------------------------------------------
-- Splits the receive buffer into complete top-level JSON objects using brace
-- depth (string and escape aware) and keeps an incomplete tail for the next
-- read. Returns: frames (array of JSON texts), remaining buffer, residue
-- (non-whitespace bytes found outside any object, e.g. SIA/Contact-ID text).
function F.splitFrames(buf)
	local text = buf:gsub("%z", "")
	local frames, residue = {}, {}
	local depth, start, inStr, esc = 0, nil, false, false
	local consumed = 0
	for i = 1, #text do
		local c = text:sub(i, i)
		if not start then
			if c == "{" then
				start, depth, inStr, esc = i, 1, false, false
			elseif not c:match("%s") then
				residue[#residue + 1] = c
				consumed = i
			else
				consumed = i
			end
		elseif inStr then
			if esc then esc = false
			elseif c == "\\" then esc = true
			elseif c == '"' then inStr = false end
		elseif c == '"' then
			inStr = true
		elseif c == "{" then
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 then
				frames[#frames + 1] = text:sub(start, i)
				start, consumed = nil, i
			end
		end
	end
	return frames, text:sub(consumed + 1), table.concat(residue)
end

-- Classifies data that is not JSON: "sia" for SIA DC-09 / Contact-ID
-- receiver traffic, "binary" for encrypted or unknown data.
function F.classifyForeign(residue)
	if residue == nil or residue == "" then return nil end
	if residue:find('"ADM%-CID"') or residue:find('"SIA%-DCS"') or residue:find('"NULL"')
		or residue:find("ADM%-CID") or residue:find("SIA%-DCS") then
		return "sia"
	end
	local printable = select(2, residue:gsub("[%w%p ]", ""))
	if #residue >= 8 and printable < #residue * 0.7 then return "binary" end
	return nil
end

---------------------------------------------------------------------------
-- Text (Windows-1255 -> UTF-8)
---------------------------------------------------------------------------
local CP1255_HIGH = {
	0x20AC, false, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, false, 0x2039,
	false, false, false, false, false, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC,
	0x2122, false, 0x203A, false, false, false, false, 0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x20AA, 0x00A5,
	0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x00D7, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF, 0x00B0, 0x00B1,
	0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x00B9, 0x00F7, 0x00BB, 0x00BC, 0x00BD,
	0x00BE, 0x00BF, 0x05B0, 0x05B1, 0x05B2, 0x05B3, 0x05B4, 0x05B5, 0x05B6, 0x05B7, 0x05B8, 0x05B9,
	false, 0x05BB, 0x05BC, 0x05BD, 0x05BE, 0x05BF, 0x05C0, 0x05C1, 0x05C2, 0x05C3, 0x05F0, 0x05F1,
	0x05F2, 0x05F3, 0x05F4, false, false, false, false, false, false, false, 0x05D0, 0x05D1, 0x05D2,
	0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, 0x05D8, 0x05D9, 0x05DA, 0x05DB, 0x05DC, 0x05DD, 0x05DE,
	0x05DF, 0x05E0, 0x05E1, 0x05E2, 0x05E3, 0x05E4, 0x05E5, 0x05E6, 0x05E7, 0x05E8, 0x05E9, 0x05EA,
	false, false, 0x200E, 0x200F, false,
}

function F.isValidUtf8(s)
	local i, n = 1, #s
	while i <= n do
		local c = s:byte(i)
		local len
		if c < 0x80 then len = 1
		elseif c >= 0xC2 and c <= 0xDF then len = 2
		elseif c >= 0xE0 and c <= 0xEF then len = 3
		elseif c >= 0xF0 and c <= 0xF4 then len = 4
		else return false end
		for k = 1, len - 1 do
			local cc = s:byte(i + k)
			if not cc or cc < 0x80 or cc > 0xBF then return false end
		end
		i = i + len
	end
	return true
end

function F.cp1255ToUtf8(s)
	return (s:gsub("[\128-\255]", function(c)
		local cp = CP1255_HIGH[c:byte() - 0x7F]
		return cp and utf8Char(cp) or "?"
	end))
end

-- Reverses a UTF-8 string by code point (for panels storing visual order)
function F.utf8Reverse(s)
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(chars, 1, ch) end
	return table.concat(chars)
end

-- Panel text -> clean UTF-8: Windows-1255 unless already valid UTF-8
function F.decodeText(s, reverse)
	s = tostring(s or ""):gsub("%z", "")
	if not F.isValidUtf8(s) then s = F.cp1255ToUtf8(s) end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if reverse then s = F.utf8Reverse(s) end
	return s
end

---------------------------------------------------------------------------
-- Frame builders (HA -> AS). Account is sent as a number, password as a
-- string; field order is alphabetical (see encodeValue).
---------------------------------------------------------------------------
function F.ack(account, counter)
	return F.encode({ account = account, counter = counter, frame_type = "ACK", kc = 1 })
end

function F.operation(account, counter, password, optype, partition, order)
	return F.encode({
		account = account, counter = counter, frame_type = "OPERATION", opclass = 1,
		optype = optype, order = order, partition = partition, password = tostring(password),
	})
end

function F.dataRequest(account, counter, password, id, startOrder, stopOrder)
	return F.encode({
		account = account, counter = counter, frame_type = "DATA-REQ", id = id,
		password = tostring(password), start_order = startOrder, stop_order = stopOrder,
	})
end

function F.dataWrite(account, counter, password, id, startOrder, params)
	local frame = F.encode({
		account = account, counter = counter, frame_type = "DATA", id = id,
		parameters = params, password = tostring(password), start_order = startOrder,
	})
	if #frame > F.MAX_WRITE_BYTES then return nil, "frame exceeds 250 bytes" end
	return frame
end

function F.isValidCode(code)
	return tostring(code or ""):match("^%d%d%d%d%d?%d?$") ~= nil
end

---------------------------------------------------------------------------
-- Decoders
---------------------------------------------------------------------------
-- 2149: sparse list of hex strings, low byte = zone, upper bytes = status.
-- Returns map zone -> status bits. Zones not listed are closed and clear.
function F.decodeZoneStatus(params)
	local zones = {}
	for _, p in ipairs(params or {}) do
		local v = tonumber(tostring(p), 16)
		if v then
			local z = v % 256
			if z > 0 then zones[z] = floor(v / 256) end
		end
	end
	return zones
end

-- 2250: hex strings "<order byte><fault id byte>". Returns array of
-- { key =, id =, order =, text =, zone = }
function F.decodeFaults(params)
	local faults = {}
	for _, p in ipairs(params or {}) do
		local v = tonumber(tostring(p), 16)
		if v then
			local id, order = v % 256, floor(v / 256)
			local text = F.FAULTS[id] or ("Fault " .. id)
			local zone
			if F.ZONE_FAULTS[id] and order > 0 then
				zone = order
			elseif order > 0 and not (id >= 30 and id <= 38) then
				text = text .. " #" .. order
			end
			faults[#faults + 1] = { key = v, id = id, order = order, text = text, zone = zone }
		end
	end
	return faults
end

-- Positional "0"/"1" values (2150, 2301)
function F.decodeFlags(params, startOrder)
	local flags = {}
	for i, p in ipairs(params or {}) do
		local n = tonumber(p)
		if n then flags[startOrder + i - 1] = (n ~= 0) end
	end
	return flags
end

---------------------------------------------------------------------------
-- SIA DC-09 (receive-only mode, for firmware without the JSON interface)
---------------------------------------------------------------------------
-- The panel reports to the driver as it would to a monitoring station:
--   <LF><CRC: 4 hex><length: "0" + 3 hex><body><CR>
--   body = "<id>"<seq 4 digits>[R<receiver>][L<line>]#<account>[<data>][<extended>...][_HH:MM:SS,MM-DD-YYYY]
-- id: ADM-CID (Contact-ID data), SIA-DCS (SIA codes), NULL (link test);
-- a leading '*' means encrypted. CRC-16/ARC and length cover the body.
-- Every report must be answered with an ACK, or the panel sends it again.

local function bxor(a, b)
	local r, bitValue = 0, 1
	while a > 0 or b > 0 do
		if a % 2 ~= b % 2 then r = r + bitValue end
		a, b, bitValue = floor(a / 2), floor(b / 2), bitValue * 2
	end
	return r
end

local CRC_TABLE = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if c % 2 == 1 then c = bxor(floor(c / 2), 0xA001) else c = floor(c / 2) end
	end
	CRC_TABLE[i] = c
end

function F.crc16(s)
	local crc = 0
	for i = 1, #s do
		crc = bxor(floor(crc / 256), CRC_TABLE[bxor(crc % 256, s:byte(i))])
	end
	return crc
end

-- True when the buffer holds DC-09 traffic (a quoted id followed by a
-- 4-digit sequence number, which JSON never contains)
function F.looksLikeSia(s)
	return s:find('"%*?[A-Z][A-Z%-]*"%d%d%d%d') ~= nil
end

function F.siaFrame(body)
	return "\n" .. string.format("%04X", F.crc16(body)) .. string.format("0%03X", #body) .. body .. "\r"
end

-- One message (the text between LF and CR) -> table; .error when unreadable
function F.siaParse(line)
	local m = { raw = line }
	local crcHex, lenHex, body = line:match('^(%x%x%x%x)(%x%x%x%x)(".*)$')
	if crcHex then
		m.crcOk = tonumber(crcHex, 16) == F.crc16(body)
		m.lengthOk = tonumber(lenHex, 16) == #body
	else
		body = line:match('(".*)$')
		if not body then m.error = "no DC-09 header" return m end
	end
	m.body = body
	local id, rest = body:match('^"([^"]*)"(.*)$')
	if not id then m.error = "no message id" return m end
	if id:sub(1, 1) == "*" then m.encrypted, id = true, id:sub(2) end
	m.id = id
	local seq, after = rest:match("^(%d%d%d%d)(.*)$")
	if not seq then m.error = "no sequence number" return m end
	m.seq, rest = seq, after
	local v
	v, after = rest:match("^R(%x+)(.*)$")
	if v then m.rcvr, rest = v, after end
	v, after = rest:match("^L(%x+)(.*)$")
	if v then m.line, rest = v, after end
	v, after = rest:match("^#(%x+)(.*)$")
	if v then m.acct, rest = v, after end
	if m.encrypted then
		m.payload = rest
		return m
	end
	m.data = rest:match("^%[(.-)%]") or ""
	m.extended = {}
	local first = true
	for block in rest:gmatch("%[(.-)%]") do
		if not first then m.extended[#m.extended + 1] = block end
		first = false
	end
	m.timestamp = rest:match("_(%d%d:%d%d:%d%d,%d%d%-%d%d%-%d%d%d%d)")
	return m
end

-- Splits complete messages out of the receive buffer. Returns messages, rest.
function F.siaSplit(buf)
	local msgs, pos = {}, 1
	while true do
		local s = buf:find("\n", pos, true)
		if not s then return msgs, "" end
		local e = buf:find("\r", s + 1, true)
		if not e then return msgs, buf:sub(s) end
		msgs[#msgs + 1] = F.siaParse(buf:sub(s + 1, e - 1))
		pos = e + 1
	end
end

-- ACK for a received message. timestamp ("HH:MM:SS,MM-DD-YYYY", UTC) is
-- added when the panel sent one.
function F.siaAck(m, timestamp)
	local body = '"ACK"' .. m.seq .. (m.rcvr and ("R" .. m.rcvr) or "") .. "L" .. (m.line or "0")
		.. "#" .. (m.acct or "") .. "[]" .. (timestamp and ("_" .. timestamp) or "")
	return F.siaFrame(body)
end

-- ADM-CID data "#acct|QEEE GG ZZZ" -> { qualifier, type, partition, zone }
function F.parseAdmCid(data)
	local text = tostring(data or ""):match("|(.*)$") or tostring(data or "")
	local q, code, group, zone = text:match("(%d)(%d%d%d) ?(%w%w) ?(%w%w%w)")
	if not q then return nil end
	return {
		qualifier = tonumber(q), type = tonumber(code),
		partition = tonumber(group) or tonumber(group, 16) or 0,
		zone = tonumber(zone) or tonumber(zone, 16) or 0,
	}
end

-- SIA codes -> equivalent Contact-ID { type, qualifier }, so both formats
-- share one event handler
F.SIA_CODES = {
	BA = { 130, 1 }, BH = { 130, 3 }, BR = { 130, 3 }, BB = { 570, 1 }, BU = { 570, 3 },
	FA = { 110, 1 }, FH = { 110, 3 }, FR = { 110, 3 },
	PA = { 120, 1 }, PH = { 120, 3 }, PR = { 120, 3 }, HA = { 121, 1 }, HH = { 121, 3 },
	MA = { 100, 1 }, MH = { 100, 3 }, MR = { 100, 3 },
	GA = { 151, 1 }, GH = { 151, 3 }, WA = { 154, 1 }, WH = { 154, 3 },
	CL = { 401, 3 }, OP = { 401, 1 }, NL = { 441, 3 }, CG = { 402, 3 }, OG = { 402, 1 },
	CA = { 403, 3 }, OA = { 403, 1 }, CS = { 409, 3 }, OS = { 409, 1 }, CF = { 408, 3 },
	CQ = { 407, 3 }, OQ = { 407, 1 },
	TA = { 137, 1 }, TR = { 137, 3 }, AT = { 301, 1 }, AR = { 301, 3 }, YT = { 302, 1 }, YR = { 302, 3 },
	YC = { 350, 1 }, YK = { 350, 3 }, RP = { 602, 1 }, RX = { 601, 1 },
}

-- SIA-DCS data "#acct|Nri1/BA015/BA016" -> list of events (unknown codes
-- are returned with .unknown = true)
function F.parseSiaDcs(data)
	local text = tostring(data or ""):match("|(.*)$") or tostring(data or "")
	text = text:gsub("^N", "")
	local events, partition, user = {}, 0, nil
	for token in text:gmatch("[^/%^]+") do
		local rest = token
		while true do
			local v, r = rest:match("^ri(%d+)(.*)$")
			if v then partition, rest = tonumber(v), r
			else
				v, r = rest:match("^id(%d+)(.*)$")
				if v then user, rest = tonumber(v), r
				else
					v, r = rest:match("^ti(%d%d:%d%d)(.*)$")
					if v then rest = r else break end
				end
			end
		end
		local code, num = rest:match("^(%u%u)(%d*)$")
		if code then
			local map = F.SIA_CODES[code]
			local zone = tonumber(num) or user or 0
			if map then
				events[#events + 1] = { type = map[1], qualifier = map[2], partition = partition, zone = zone, sia = code }
			else
				events[#events + 1] = { unknown = true, sia = code, partition = partition, zone = zone }
			end
		end
	end
	return events
end

return F
