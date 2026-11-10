-- Offline tests for src/pima_force.lua. Run from the repo root:
--   lua5.1 tests/test_force_protocol.lua
package.path = "src/?.lua;tests/?.lua;" .. package.path
local T = require("testlib")
local F = require("pima_force")

T.out("pima_force")

-- Frames captured from a real FORCE panel (amithalp/pima-force-ha-integration
-- fixtures; account and names are synthetic there)
local REAL = {
	'{"frame_type":"null","counter":9,"account":"654321"}',
	'{"frame_type":"DATA","counter":1,"account":"654321","id":2310,"start_order":1,"parameters":["2","1","1","1","1","1","1","1","1","1","1","1","1","1","1","1"],"more":"no"}',
	'{"frame_type":"DATA","counter":3,"account":"654321","id":2149,"start_order":1,"parameters":[],"more":"no"}',
	'{"frame_type":"DATA","counter":4,"account":"654321","id":260,"start_order":1,"parameters":["Zone 01","Zone 02","Zone 03","Zone 04","Zone 05","Zone 06","Zone 07","Zone 08","Zone 09"],"more":"yes"}',
	'{"frame_type":"event","counter":2188,"account":"654321","type":441,"qualifier":3,"zone":21,"partition":1}',
	'{"frame_type":"NAK","counter":130,"account":999001,"DATA":"Wrong User Code"}',
}

T.test("decodes real panel frames", function()
	local null = assert(F.decode(REAL[1]))
	T.eq(F.frameType(null), "NULL")
	T.eq(tonumber(null.account), 654321)
	local keys = assert(F.decode(REAL[2]))
	T.eq(keys.id, 2310)
	T.eq(#keys.parameters, 16)
	T.eq(keys.parameters[1], "2")
	local empty = assert(F.decode(REAL[3]))
	T.eq(#empty.parameters, 0)
	local names = assert(F.decode(REAL[4]))
	T.eq(names.more, "yes")
	T.eq(names.parameters[9], "Zone 09")
	local ev = assert(F.decode(REAL[5]))
	T.eq(F.frameType(ev), "EVENT")
	T.eq(ev.type, 441)
	T.eq(ev.qualifier, 3)
	local nak = assert(F.decode(REAL[6]))
	T.eq(nak.DATA, "Wrong User Code")
end)

T.test("JSON decoder edge cases", function()
	local v = assert(F.decode('{"a":[1,-2.5,true,false,null,"x\\"y\\\\z\\u05d0"],"b":{}}'))
	T.eq(v.a[1], 1)
	T.eq(v.a[2], -2.5)
	T.eq(v.a[3], true)
	T.eq(v.a[4], false)
	T.eq(v.a[6], 'x"y\\z\215\144')
	T.eq(type(v.b), "table")
	T.eq((F.decode('{"a":')), nil)
	T.eq((F.decode('{"a" 1}')), nil)
	T.eq((F.decode('nonsense')), nil)
end)

T.test("raw Windows-1255 bytes survive JSON decoding", function()
	local v = assert(F.decode('{"parameters":["\227\236\250 \235\240\233\241\228"]}'))
	T.eq(v.parameters[1], "\227\236\250 \235\240\233\241\228")
end)

T.test("ACK frame: numeric account, kc 1, sorted fields", function()
	T.eq(F.ack(654321, 9), '{"account":654321,"counter":9,"frame_type":"ACK","kc":1}')
end)

T.test("OPERATION frame matches the documented shape", function()
	T.eq(F.operation(123456, 5001, "1234", F.OPTYPE.AWAY, 1, 1),
		'{"account":123456,"counter":5001,"frame_type":"OPERATION","opclass":1,"optype":12,"order":1,"partition":1,"password":"1234"}')
	T.eq(F.operation(123456, 5003, "1234", F.OPTYPE.DISARM, 0, 0),
		'{"account":123456,"counter":5003,"frame_type":"OPERATION","opclass":1,"optype":17,"order":0,"partition":0,"password":"1234"}')
end)

T.test("DATA-REQ with and without stop_order", function()
	T.eq(F.dataRequest(654321, 2, "1234", 2310, 1, 16),
		'{"account":654321,"counter":2,"frame_type":"DATA-REQ","id":2310,"password":"1234","start_order":1,"stop_order":16}')
	T.eq(F.dataRequest(654321, 3, "1234", 2149, 1, nil),
		'{"account":654321,"counter":3,"frame_type":"DATA-REQ","id":2149,"password":"1234","start_order":1}')
end)

T.test("DATA write (bypass) and the 250 byte limit", function()
	T.eq(F.dataWrite(1234, 42, "1111", 2150, 13, { "1" }),
		'{"account":1234,"counter":42,"frame_type":"DATA","id":2150,"parameters":["1"],"password":"1111","start_order":13}')
	local many = {}
	for i = 1, 60 do many[i] = "1" end
	T.eq((F.dataWrite(1234, 42, "1111", 2150, 1, many)), nil)
end)

T.test("splitFrames: back-to-back objects, NUL padding, partial tail", function()
	local null = '{"frame_type":"null","counter":9,"account":"654321"}' .. string.rep("\0", 200)
	local stream = null .. REAL[5] .. REAL[2]:sub(1, 40)
	local frames, rest, residue = F.splitFrames(stream)
	T.eq(#frames, 2)
	T.eq(frames[2], REAL[5])
	T.eq(rest, REAL[2]:sub(1, 40))
	T.eq(residue, "")
	frames, rest = F.splitFrames(rest .. REAL[2]:sub(41))
	T.eq(#frames, 1)
	T.eq(frames[1], REAL[2])
	T.eq(rest, "")
end)

T.test("splitFrames: braces and quotes inside strings", function()
	local tricky = '{"frame_type":"NAK","DATA":"a } { \\" b"}'
	local frames, rest = F.splitFrames(tricky .. tricky)
	T.eq(#frames, 2)
	T.eq(frames[1], tricky)
	T.eq(rest, "")
end)

T.test("splitFrames: byte-by-byte delivery", function()
	local stream = REAL[4] .. REAL[1]
	local buf, got = "", 0
	for i = 1, #stream do
		local frames
		frames, buf = F.splitFrames(buf .. stream:sub(i, i))
		got = got + #frames
	end
	T.eq(got, 2)
end)

T.test("classifyForeign recognises SIA DC-09 / Contact-ID and binary", function()
	local _, _, residue = F.splitFrames('\n9A3B0042"ADM-CID"0001R0L0#654321[#654321|1130 01 003]\r')
	T.eq(F.classifyForeign(residue), "sia")
	local _, _, bin = F.splitFrames("\1\2\3\4\5\6\7\8\9\10\11\12\128\129")
	T.eq(F.classifyForeign(bin), "binary")
	T.eq(F.classifyForeign(""), nil)
end)

T.test("Windows-1255 Hebrew zone name -> UTF-8", function()
	local raw = "\227\236\250 \235\240\233\241\228  " -- "דלת כניסה" in cp1255, padded
	local name = F.decodeText(raw)
	T.eq(name, "\215\147\215\156\215\170 \215\155\215\160\215\153\215\161\215\148")
	T.truthy(F.isValidUtf8(name))
	-- visual-order panels: reversed by character
	T.eq(F.decodeText(raw, true), "\215\148\215\161\215\153\215\160\215\155 \215\170\215\156\215\147")
	-- valid UTF-8 and plain ASCII pass through
	T.eq(F.decodeText("Front Door\0\0"), "Front Door")
	T.eq(F.decodeText(name), name)
end)

T.test("zone status decode (spec worked examples)", function()
	local z = F.decodeZoneStatus({ "80005", "800C", "A0019", "81B", "40007" })
	T.truthy(F.hasBit(z[5], F.ZONE_BIT.OPEN), "zone 5 open")
	T.truthy(F.hasBit(z[12], F.ZONE_BIT.MANUAL_BYPASS), "zone 12 bypassed")
	T.truthy(F.hasBit(z[25], F.ZONE_BIT.ALARMED) and F.hasBit(z[25], F.ZONE_BIT.OPEN), "zone 25 alarmed+open")
	T.truthy(F.hasBit(z[27], F.ZONE_BIT.TAMPER), "zone 27 tamper")
	T.truthy(F.hasBit(z[7], F.ZONE_BIT.ARMED) and not F.hasBit(z[7], F.ZONE_BIT.OPEN), "zone 7 armed")
	T.eq(z[1], nil, "unlisted zones are clear")
	T.eq(next(F.decodeZoneStatus({})), nil)
end)

T.test("setBit / hasBit", function()
	local v = F.setBit(0, 11, true)
	T.eq(v, 2048)
	T.eq(F.setBit(v, 11, true), 2048)
	T.eq(F.setBit(v, 11, false), 0)
	T.eq(F.setBit(v, 7, false), 2048)
end)

T.test("fault decode (spec examples)", function()
	local faults = F.decodeFaults({ "1", "6", "309", "2B3C" })
	T.eq(faults[1].text, "AC Loss")
	T.eq(faults[2].text, "PSTN Fault (DC)")
	T.eq(faults[3].text, "Zone Expander Fault #3")
	T.eq(faults[4].text, "Zone Tamper")
	T.eq(faults[4].zone, 43)
	-- comm path faults do not get a device suffix
	T.eq(F.decodeFaults({ "221" })[1].text, "Station Network Communication")
end)

T.test("positional flags (2301 sirens)", function()
	local f = F.decodeFlags({ "0", "1" }, 1)
	T.eq(f[1], false)
	T.eq(f[2], true)
end)

T.test("code validation", function()
	T.truthy(F.isValidCode("1234") and F.isValidCode("123456"))
	T.truthy(not F.isValidCode("123") and not F.isValidCode("1234567") and not F.isValidCode("12a4") and not F.isValidCode(nil))
end)

T.done()
