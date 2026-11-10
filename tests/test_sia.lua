-- Receive-only mode: SIA DC-09 reports (panel firmware without JSON).
-- Run from the repo root:  lua5.1 tests/test_sia.lua   (VERBOSE=1 for driver output)
package.path = "src/?.lua;tests/?.lua;" .. package.path
local T = require("testlib")
local M = require("mock_c4")
local F = require("pima_force")

local ACCOUNT = "654321"
local ADDR = "192.168.1.129"
local P1 = 5002

---------------------------------------------------------------------------
T.out("SIA DC-09 protocol")

T.test("CRC-16/ARC check value", function()
	T.eq(F.crc16("123456789"), 0xBB3D)
	T.eq(F.crc16(""), 0)
end)

T.test("frame header: CRC and hex length of the body", function()
	local body = '"NULL"0000R0L0#654321[]'
	local frame = F.siaFrame(body)
	T.eq(frame, "\n" .. string.format("%04X", F.crc16(body)) .. "0017" .. body .. "\r")
end)

-- Captured from the real FORCE 32C (fw 1.5.1) on 2026-11-10: the panel sends
-- a 16-digit zero-padded account, receiver 1 and a local-time timestamp
local REAL = {
	'790D004B"ADM-CID"0001R1L0#0000000000654321[#654321|3407 01 001]_23:28:12,11-10-2026',
	'65F2004B"ADM-CID"0002R1L0#0000000000654321[#654321|1407 01 001]_23:29:20,11-10-2026',
	'1517004B"ADM-CID"0005R1L0#0000000000654321[#654321|3350 01 004]_23:29:20,11-10-2026',
	'EBA90035"NULL"0006R1L0#0000000000654321[]_23:29:20,11-10-2026',
}

T.test("real panel reports: CRC and length match, fields decode", function()
	for _, line in ipairs(REAL) do
		local m = F.siaParse(line)
		T.eq(m.crcOk, true, "crc " .. line)
		T.eq(m.lengthOk, true, "length " .. line)
		T.eq(m.rcvr, "1")
		T.eq(m.acct, "0000000000654321")
	end
	local arm = F.parseAdmCid(F.siaParse(REAL[1]).data)
	T.eq(arm.type, 407)
	T.eq(arm.qualifier, 3)
	T.eq(arm.partition, 1)
	T.eq(arm.zone, 1)
	T.eq(F.siaParse(REAL[4]).id, "NULL")
	T.eq(F.siaParse(REAL[4]).timestamp, "23:29:20,11-10-2026")
	T.eq(F.siaAck(F.siaParse(REAL[1])), F.siaFrame('"ACK"0001R1L0#0000000000654321[]'))
end)

T.test("parses an ADM-CID report", function()
	local msgs, rest = F.siaSplit(F.siaFrame('"ADM-CID"0042R0L0#654321[#654321|1130 01 003]'))
	T.eq(rest, "")
	local m = msgs[1]
	T.eq(m.id, "ADM-CID")
	T.eq(m.seq, "0042")
	T.eq(m.rcvr, "0")
	T.eq(m.line, "0")
	T.eq(m.acct, "654321")
	T.eq(m.data, "#654321|1130 01 003")
	T.eq(m.crcOk, true)
	T.eq(m.lengthOk, true)
	local e = F.parseAdmCid(m.data)
	T.eq(e.qualifier, 1)
	T.eq(e.type, 130)
	T.eq(e.partition, 1)
	T.eq(e.zone, 3)
end)

T.test("parses SIA-DCS with extended data and timestamp", function()
	local m = F.siaParse("ABCD0000" .. '"SIA-DCS"0007R1L232#78919[#78919|Nri1/BA015][S123Main St.]_11:10:00,10-12-2026')
	T.eq(m.id, "SIA-DCS")
	T.eq(m.rcvr, "1")
	T.eq(m.line, "232")
	T.eq(m.acct, "78919")
	T.eq(m.data, "#78919|Nri1/BA015")
	T.eq(m.extended[1], "S123Main St.")
	T.eq(m.timestamp, "11:10:00,10-12-2026")
	T.eq(m.crcOk, false)
	local ev = F.parseSiaDcs(m.data)
	T.eq(#ev, 1)
	T.eq(ev[1].type, 130)
	T.eq(ev[1].qualifier, 1)
	T.eq(ev[1].partition, 1)
	T.eq(ev[1].zone, 15)
end)

T.test("SIA codes: several events, user numbers, unknown codes", function()
	local ev = F.parseSiaDcs("Nri2/CL003/BB007/ZZ001")
	T.eq(#ev, 3)
	T.eq(ev[1].type, 401)
	T.eq(ev[1].qualifier, 3)
	T.eq(ev[1].partition, 2)
	T.eq(ev[1].zone, 3)
	T.eq(ev[2].type, 570)
	T.eq(ev[2].zone, 7)
	T.eq(ev[3].unknown, true)
	local op = F.parseSiaDcs("#1234|Nid5ri1OP")
	T.eq(op[1].type, 401)
	T.eq(op[1].qualifier, 1)
	T.eq(op[1].zone, 5)
	T.eq(op[1].partition, 1)
end)

T.test("Contact-ID without spaces and without account", function()
	local e = F.parseAdmCid("340102004")
	T.eq(e.qualifier, 3)
	T.eq(e.type, 401)
	T.eq(e.partition, 2)
	T.eq(e.zone, 4)
	T.eq(F.parseAdmCid("garbage"), nil)
end)

T.test("encrypted report is recognised", function()
	local m = F.siaParse('12340030"*ADM-CID"0003R0L0#654321[8C3F09AA77]')
	T.eq(m.encrypted, true)
	T.eq(m.id, "ADM-CID")
	T.eq(m.acct, "654321")
end)

T.test("ACK echoes sequence, receiver, line and account", function()
	local m = F.siaParse("00000000" .. '"ADM-CID"0042R0L0#654321[#654321|1130 01 003]')
	T.eq(F.siaAck(m), F.siaFrame('"ACK"0042R0L0#654321[]'))
	local noR = F.siaParse("00000000" .. '"NULL"0001L0#1234[]')
	T.eq(F.siaAck(noR, "21:05:00,11-10-2026"), F.siaFrame('"ACK"0001L0#1234[]_21:05:00,11-10-2026'))
end)

T.test("detects DC-09 traffic, not JSON", function()
	T.truthy(F.looksLikeSia('\n9A3B002D"ADM-CID"0001R0L0#6543'))
	T.truthy(F.looksLikeSia('"*SIA-DCS"0001'))
	T.eq(F.looksLikeSia('{"frame_type":"null","counter":5}'), false)
end)

---------------------------------------------------------------------------
T.out("driver in receive-only mode")

local handle, seq = 20, 0

local function connect()
	handle = handle + 1
	OnServerConnectionStatusChanged(handle, 7780, "ONLINE", ADDR)
end

local function body(id, data, acct)
	seq = seq % 9999 + 1
	acct = acct or ACCOUNT
	return string.format('"%s"%04dR0L0#%s[%s]', id, seq, acct, data)
end

local function cid(q, code, partition, zone, acct)
	acct = acct or ACCOUNT
	return body("ADM-CID", string.format("#%s|%d%03d %02d %03d", acct, q, code, partition, zone), acct)
end

local function send(...)
	local data = ""
	for _, b in ipairs({ ... }) do data = data .. F.siaFrame(b) end
	M.sent = {}
	OnServerDataIn(handle, data, ADDR, 50000)
end

local function acks()
	local list = {}
	for _, s in ipairs(M.sent) do
		local msgs = F.siaSplit(s.data)
		for _, m in ipairs(msgs) do list[#list + 1] = m end
	end
	return list
end

local function partitionState()
	local m = M.partitionState[P1]
	return m and m.params.STATE, m and m.params.TYPE, m and m.cmd
end

local function displayText()
	local m = M.lastProxy(P1, "DISPLAY_TEXT")
	return m and m.params
end

M.load({ ["Account ID"] = ACCOUNT })

T.test("wrong account: no ACK, status explains", function()
	connect()
	send(body("NULL", "", "111111"))
	T.eq(#M.sent, 0)
	T.truthy(Properties["Connection Status"]:find("Account mismatch: panel sent 111111"))
	T.eq(g.mode, nil)
end)

T.test("link test: ACKed, receive-only mode, state unknown until an arm report", function()
	send(body("NULL", ""))
	local a = acks()
	T.eq(#a, 1)
	T.eq(a[1].id, "ACK")
	T.eq(a[1].seq, string.format("%04d", seq))
	T.eq(a[1].acct, ACCOUNT)
	T.eq(a[1].crcOk, true)
	T.eq(g.mode, "sia")
	T.truthy(Properties["Connection Status"]:find("^Receive only %(SIA DC%-09%)"))
	T.eq((partitionState()), "OFFLINE")
	T.eq(displayText(), "Waiting for an arm or disarm report from the panel")
	T.truthy(M.allOutput():find("SIA sample 1/10", 1, true), "first reports logged with Debug Mode off")
end)

T.test("keypad arm Away and Home reports", function()
	M.clearProxy()
	send(cid(3, 401, 1, 2))
	local state, typ, cmd = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Away")
	T.eq(cmd, "PARTITION_STATE")
	send(cid(1, 401, 1, 2))
	T.eq((partitionState()), "DISARMED_READY")
	send(cid(3, 441, 1, 2))
	state, typ = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Home")
end)

T.test("burglary alarm creates the zone and stays until disarm", function()
	M.clearProxy()
	send(cid(1, 130, 1, 3))
	local state, typ = partitionState()
	T.eq(state, "ALARM")
	T.eq(typ, "Burglary")
	T.truthy(M.bindings[103], "zone 3 binding created from the report")
	T.truthy(M.findProxy(5001, "PANEL_ZONE_INFO", { ID = "3" }))
	send(cid(3, 130, 1, 3))
	T.eq((partitionState()), "ALARM")
	send(cid(1, 401, 1, 1))
	T.eq((partitionState()), "DISARMED_READY")
	T.eq(Properties["Alarmed Zones"], "None")
end)

T.test("zone open / close reports", function()
	M.clearProxy()
	send(cid(1, 760, 1, 5))
	T.truthy(M.findProxy(105, "OPENED"))
	T.eq((partitionState()), "DISARMED_NOT_READY")
	send(cid(3, 760, 1, 5))
	T.truthy(M.findProxy(105, "CLOSED"))
	T.eq((partitionState()), "DISARMED_READY")
end)

T.test("trouble reports start and clear troubles", function()
	M.clearProxy()
	send(cid(1, 301, 0, 0))
	T.truthy(M.findProxy(5001, "TROUBLE_START", { TROUBLE_TEXT = "AC loss" }))
	send(cid(1, 333, 0, 0))
	T.truthy(M.findProxy(5001, "TROUBLE_START", { TROUBLE_TEXT = "Trouble 333" }))
	send(cid(3, 301, 0, 0))
	T.truthy(M.findProxy(5001, "TROUBLE_CLEAR"))
	T.eq(Properties["Active Troubles"], "Trouble 333")
	send(cid(3, 333, 0, 0))
	T.eq(Properties["Active Troubles"], "None")
end)

T.test("Control4 cannot arm, disarm or bypass in receive-only mode", function()
	M.clearProxy()
	M.sent = {}
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Away", UserCode = "1234", InterfaceID = "ui1" })
	T.truthy(M.findProxy(P1, "ARM_FAILED", { ACTION = "NA", INTERFACE_ID = "ui1" }))
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = "1234", InterfaceID = "ui1" })
	T.truthy(M.findProxy(P1, "DISARM_FAILED", { INTERFACE_ID = "ui1" }))
	ExecuteCommand("Bypass Zone", { Zone = "3" })
	T.eq(#M.sent, 0, "nothing sent to the panel")
end)

T.test("DirectorLink is told arming can't work while the panel only reports", function()
	T.eq(M.vars.DIRECTORLINK_ALARM, "1")
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "0")
	connect()
	send(body("NULL", ""))
	T.eq(g.mode, "sia")
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "0", "a connected panel that only reports")
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = "1234", InterfaceID = "DirectorLink" })
	T.truthy(M.findProxy(P1, "DISARM_FAILED", { INTERFACE_ID = "DirectorLink" }))
end)

T.test("several reports in one packet get one ACK each", function()
	local first = cid(1, 760, 1, 2)
	local second = cid(3, 760, 1, 2)
	send(first, second)
	local a = acks()
	T.eq(#a, 2)
	T.eq(a[1].seq, string.format("%04d", seq - 1))
	T.eq(a[2].seq, string.format("%04d", seq))
end)

T.test("report split over two TCP packets", function()
	local frame = F.siaFrame(cid(3, 401, 1, 2))
	M.sent = {}
	OnServerDataIn(handle, frame:sub(1, 12), ADDR, 50000)
	T.eq(#M.sent, 0)
	OnServerDataIn(handle, frame:sub(13), ADDR, 50000)
	T.eq(#acks(), 1)
	T.eq((partitionState()), "ARMED")
end)

T.test("SIA-DCS codes work too", function()
	send(body("SIA-DCS", "#" .. ACCOUNT .. "|Nri1/OP002"))
	T.eq((partitionState()), "DISARMED_READY")
	send(body("SIA-DCS", "#" .. ACCOUNT .. "|Nri1/CL002"))
	T.eq((partitionState()), "ARMED")
	send(body("SIA-DCS", "#" .. ACCOUNT .. "|Nri1/OP002"))
	T.eq((partitionState()), "DISARMED_READY")
end)

T.test("encrypted reports are not ACKed", function()
	M.sent = {}
	OnServerDataIn(handle, F.siaFrame('"*ADM-CID"0099R0L0#654321[8C3F09AA77]'), ADDR, 50000)
	T.eq(#M.sent, 0)
	T.truthy(Properties["Connection Status"]:find("encrypted"))
end)

T.test("panel hangs up after reporting: still online, state kept", function()
	OnServerConnectionStatusChanged(handle, 7780, "OFFLINE", ADDR)
	M.advance(200 * 1000)
	T.eq((partitionState()), "DISARMED_READY")
	T.eq(Properties["Active Troubles"], "None")
end)

T.test("missed link tests raise a communication trouble, next report clears it", function()
	connect()
	send(body("NULL", ""))
	M.advance(60 * 1000)
	send(body("NULL", ""))
	T.eq(g.siaLinkInterval, 60)
	M.events = {}
	M.clearProxy()
	M.advance(200 * 1000)
	T.truthy(M.findProxy(5001, "TROUBLE_START", { IDENTIFIER = "9999" }))
	T.eq(M.events[#M.events], "Communication Lost")
	T.eq((partitionState()), "DISARMED_READY", "last reported state kept")
	send(body("NULL", ""))
	T.truthy(M.findProxy(5001, "TROUBLE_CLEAR", { IDENTIFIER = "9999" }))
	T.eq(M.events[#M.events], "Communication Restored")
end)

T.test("state survives a driver restart", function()
	send(cid(3, 441, 1, 2))
	T.eq(PersistData.siaMode, true)
	local saved = PersistData
	M.load({ ["Account ID"] = ACCOUNT }, saved)
	T.eq(g.mode, "sia")
	T.eq((partitionState()), "OFFLINE", "offline until the panel reports again")
	connect()
	send(body("NULL", ""))
	local state, typ, cmd = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Home")
	T.eq(cmd, "PARTITION_STATE_INIT", "restored state does not fire programming")
	T.truthy(M.bindings[105], "zone bindings restored")
end)

T.test("real panel session: padded account accepted, queued reports replayed", function()
	connect()
	M.clearProxy()
	M.sent = {}
	local data = ""
	for _, line in ipairs(REAL) do data = data .. "\n" .. line .. "\r" end
	OnServerDataIn(handle, data, ADDR, 50000)
	local a = acks()
	T.eq(#a, 4)
	T.eq(a[1].seq, "0001")
	T.eq(a[4].seq, "0006")
	T.eq(a[1].rcvr, "1")
	T.eq((partitionState()), "DISARMED_READY")
	local stateReports = 0
	for _, m in ipairs(M.proxy) do
		if m.binding == P1 and (m.cmd == "PARTITION_STATE" or m.cmd == "PARTITION_STATE_INIT") then stateReports = stateReports + 1 end
	end
	T.eq(stateReports, 2, "armed, then disarmed: each reported once")
end)

T.test("Debug Mode change starts its auto-off timer", function()
	M.setProperty("Debug Mode", "On")
	T.eq(M.allOutput():find("Property 'Debug Mode' failed", 1, true), nil)
	M.setProperty("Debug Mode", "Off")
end)

T.test("JSON firmware later: first JSON frame switches to full control", function()
	connect()
	OnServerDataIn(handle, '{"frame_type":"null","counter":1,"account":"654321"}', ADDR, 50000)
	T.eq(g.mode, "json")
	T.eq(PersistData.siaMode, nil)
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "1", "DirectorLink may offer Arm and Disarm now")
end)

T.test("empty Account ID: learned from the first SIA report", function()
	M.load({})
	T.eq(Properties["Account ID"], "")
	connect()
	M.sent = {}
	OnServerDataIn(handle, "\n" .. REAL[1] .. "\r", ADDR, 50000)
	T.eq(#acks(), 1, "first report ACKed")
	T.eq(Properties["Account ID"], "654321")
	T.eq((partitionState()), "ARMED")
	-- a different panel is still refused afterwards
	M.sent = {}
	send(body("NULL", "", "111111"))
	T.eq(#M.sent, 0)
	T.truthy(Properties["Connection Status"]:find("Account mismatch: panel sent 111111"))
end)

T.test("real link-test pattern: batch-end NULLs don't shorten supervision", function()
	-- as seen on the panel: an idle NULL every ~242 s, plus a NULL right after
	-- every batch of reports
	M.load({ ["Account ID"] = ACCOUNT })
	connect()
	send(body("NULL", ""))
	M.advance(242 * 1000)
	connect()
	send(body("NULL", ""))
	T.eq(g.siaLinkInterval, 242)
	M.advance(30 * 1000)
	connect()
	send(cid(3, 407, 1, 1), body("NULL", ""))
	M.advance(15 * 1000)
	connect()
	send(cid(1, 407, 1, 1), body("NULL", ""))
	T.eq(g.siaLinkInterval, 242, "batch-end link tests ignored")
	M.clearProxy()
	M.advance(400 * 1000)
	T.eq(M.findProxy(5001, "TROUBLE_START", { IDENTIFIER = "9999" }), nil, "no false comm trouble")
	M.advance(300 * 1000)
	T.truthy(M.findProxy(5001, "TROUBLE_START", { IDENTIFIER = "9999" }), "real silence is reported")
end)

T.test("empty Account ID: learned from the first JSON frame", function()
	M.load({})
	connect()
	M.sent = {}
	OnServerDataIn(handle, '{"frame_type":"null","counter":3,"account":"654321"}', ADDR, 50000)
	T.eq(M.sent[1].data, '{"account":654321,"counter":3,"frame_type":"ACK","kc":1}')
	T.eq(Properties["Account ID"], "654321")
	T.eq(g.mode, "json")
end)

T.done()
