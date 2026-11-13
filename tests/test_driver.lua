-- End-to-end test: src/driver.lua against a simulated FORCE panel, on the
-- mocked Control4 runtime. Run from the repo root:
--   lua5.1 tests/test_driver.lua        (VERBOSE=1 to see driver output)
package.path = "src/?.lua;tests/?.lua;" .. package.path
local T = require("testlib")
local M = require("mock_c4")
local F = require("pima_force")

local CODE = "2580"
local ACCOUNT = "654321"
local P1 = 5002

---------------------------------------------------------------------------
-- Simulated panel
---------------------------------------------------------------------------
local Panel = {
	handle = 7, address = "192.168.1.129", counter = 100,
	keys = { "2", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1" },
	zones = {},             -- [z] = status bits
	zoneCount = 8,
	names = {},
	faults = {},
	sirens = { "0", "0" },
	exitTime = 30,
	pendingArm = nil,
	autoRespond = true,
	received = {},          -- frames from the driver (decoded), with .at (ms)
	violations = {},
}
Panel.names[1] = "\227\236\250 \235\240\233\241\228" -- "דלת כניסה" (cp1255)
for z = 2, 8 do Panel.names[z] = "Zone " .. z end

local ARM_KEYS = { [12] = "3", [13] = "4", [14] = "5", [43] = "8" }
local NAK_OPEN_ZONES = "\241\226\229\248/\225\232\236 \224\230\229\248\233\237!" -- "סגור/בטל אזורים!"

function Panel.send(frame)
	frame.account = frame.account or ACCOUNT
	OnServerDataIn(Panel.handle, F.encode(frame), Panel.address, 50123)
end

function Panel.event(cid, q, zone, partition)
	Panel.counter = Panel.counter + 1
	Panel.send({ frame_type = "event", counter = Panel.counter, type = cid, qualifier = q, zone = zone, partition = partition })
end

function Panel.null()
	Panel.counter = Panel.counter + 1
	OnServerDataIn(Panel.handle, F.encode({ frame_type = "null", counter = Panel.counter, account = ACCOUNT }) .. string.rep("\0", 180), Panel.address, 50123)
end

function Panel.connect()
	OnServerConnectionStatusChanged(Panel.handle, 7780, "ONLINE", Panel.address)
end

local function zoneStatusParams()
	local list = {}
	for z = 1, 144 do
		local bits = Panel.zones[z]
		if bits and bits > 0 then list[#list + 1] = string.format("%X", bits * 256 + z) end
	end
	return list
end

local function setBit(z, b, on) Panel.zones[z] = F.setBit(Panel.zones[z] or 0, b, on) end

local function respondData(req)
	local id, start, stop = req.id, req.start_order, req.stop_order
	local params, more = {}, nil
	if req.password ~= CODE then
		return Panel.send({ frame_type = "NAK", counter = req.counter, DATA = "Wrong User Code" })
	end
	if id == 2148 then params = { tostring(Panel.zoneCount) }
	elseif id == 180 then params = { tostring(Panel.exitTime) }
	elseif id == 2310 then for p = start, stop or 16 do params[#params + 1] = Panel.keys[p] end
	elseif id == 2149 then params = zoneStatusParams()
	elseif id == 2250 then params = Panel.faults
	elseif id == 2301 then for o = start, stop do params[#params + 1] = Panel.sirens[o] or "0" end
	elseif id == 260 then
		-- like the real panel: at most 9 names per frame, then "more":"yes"
		local last = math.min(stop or Panel.zoneCount, start + 8)
		for z = start, last do params[#params + 1] = Panel.names[z] or "" end
		more = (last < (stop or Panel.zoneCount)) and "yes" or "no"
	else
		return Panel.send({ frame_type = "NAK", counter = req.counter, DATA = "Parameter Not Exist" })
	end
	Panel.send({ frame_type = "DATA", counter = req.counter, id = id, start_order = start, parameters = params, more = more or "no" })
end

local function respondOperation(op)
	if op.password ~= CODE then
		return Panel.send({ frame_type = "NAK", counter = op.counter, DATA = "Wrong User Code" })
	end
	local p = op.partition
	if ARM_KEYS[op.optype] then
		for z = 1, Panel.zoneCount do
			local bits = Panel.zones[z] or 0
			if F.hasBit(bits, 11) and not F.hasBit(bits, 7) then
				return Panel.send({ frame_type = "NAK", counter = op.counter, DATA = NAK_OPEN_ZONES })
			end
		end
		Panel.send({ frame_type = "ACK", counter = op.counter })
		Panel.event(407, 3, 1, p)
		-- reads disarmed until the exit delay ends
		Panel.pendingArm = { p = p, key = ARM_KEYS[op.optype], at = M.nowMs + Panel.exitTime * 1000 }
	elseif op.optype == 17 then
		Panel.send({ frame_type = "ACK", counter = op.counter })
		Panel.pendingArm = nil
		Panel.keys[p] = "2"
		Panel.event(407, 1, 1, p)
	elseif op.optype == 35 or op.optype == 36 then
		Panel.send({ frame_type = "ACK", counter = op.counter })
	end
end

local lastWriteAt, lastWasOperation, lastType, outstanding = nil, false, nil, nil

function Panel.serve()
	local sent = M.sent
	M.sent = {}
	for _, s in ipairs(sent) do
		local frame = assert(F.decode(s.data), "driver sent invalid JSON: " .. s.data)
		frame.at = s.at
		table.insert(Panel.received, frame)
		local ftype = F.frameType(frame)
		-- write pacing: >= 100 ms between writes, >= 500 ms after an OPERATION
		if lastWriteAt then
			local gap = s.at - lastWriteAt
			if gap < 100 or (lastWasOperation and gap < 500) then
				table.insert(Panel.violations, string.format("%s sent %d ms after previous %s", ftype, gap, tostring(lastType)))
			end
		end
		lastWriteAt, lastWasOperation, lastType = s.at, (ftype == "OPERATION"), ftype
		if ftype ~= "ACK" then
			if outstanding then table.insert(Panel.violations, "second request while one was outstanding") end
			outstanding = frame
		end
		if Panel.autoRespond and ftype ~= "ACK" then
			outstanding = nil
			if ftype == "DATA-REQ" then respondData(frame)
			elseif ftype == "OPERATION" then respondOperation(frame)
			elseif ftype == "DATA" then
				Panel.send({ frame_type = "ACK", counter = frame.counter })
				local z, on = frame.start_order, frame.parameters[1] == "1"
				setBit(z, 7, on)
				Panel.event(570, on and 1 or 3, z, 1)
			end
		end
	end
	if Panel.pendingArm and M.nowMs >= Panel.pendingArm.at then
		Panel.keys[Panel.pendingArm.p] = Panel.pendingArm.key
		Panel.pendingArm = nil
	end
end

-- advances time in small steps, letting the panel answer in between
local function run(ms)
	for _ = 1, math.ceil(ms / 50) do
		M.advance(50)
		Panel.serve()
	end
end

local function lastSentOfType(ftype)
	for i = #Panel.received, 1, -1 do
		if F.frameType(Panel.received[i]) == ftype then return Panel.received[i] end
	end
end

local function partitionState()
	local m = M.partitionState[P1]
	return m and m.params.STATE, m and m.params.TYPE, m and m.cmd
end

---------------------------------------------------------------------------
T.out("driver (simulated FORCE panel)")

M.load({ ["Account ID"] = ACCOUNT, ["Panel User Code"] = CODE, ["Debug Mode"] = "Trace" })

T.test("starts listening and reports partitions offline", function()
	T.eq(M.listening, 7780)
	T.truthy(M.findProxy(P1, "PARTITION_ENABLED", { ENABLED = "true" }))
	T.truthy(M.findProxy(5003, "PARTITION_ENABLED", { ENABLED = "false" }))
	local state, _, cmd = partitionState()
	T.eq(state, "OFFLINE")
	T.eq(cmd, "PARTITION_STATE_INIT")
end)

T.test("DirectorLink's alarm agreement: its variables, no control before the panel connects", function()
	T.eq(table.concat(M.varOrder, ","), "DIRECTORLINK_ALARM,DIRECTORLINK_ALARM_CONTROL")
	T.eq(M.vars.DIRECTORLINK_ALARM, "1")
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "0")
	-- "dev" from src/, VERSION in the package
	T.eq(Properties["Driver Version"], DRIVER_SEMVER .. " (1)")
	T.truthy(DRIVER_SEMVER ~= "", "a version")
end)

T.test("rejects a connection from another IP when Panel IP Address is set", function()
	M.setProperty("Panel IP Address", "192.168.1.129")
	OnServerConnectionStatusChanged(99, 7780, "ONLINE", "192.168.1.50")
	T.eq(M.closed[#M.closed], 99)
end)

T.test("ignores a panel with the wrong account but keeps it talking", function()
	OnServerConnectionStatusChanged(8, 7780, "ONLINE", "192.168.1.129")
	OnServerDataIn(8, '{"frame_type":"null","counter":5,"account":"111111"}', "192.168.1.129", 1)
	T.eq(M.sent[1].data, '{"account":111111,"counter":5,"frame_type":"ACK","kc":1}')
	T.truthy(Properties["Connection Status"]:find("Account mismatch"))
	OnServerConnectionStatusChanged(8, 7780, "OFFLINE", "192.168.1.129")
	M.sent = {}
end)

T.test("panel connects: ACK with numeric account and kc:1, then full sync", function()
	Panel.connect()
	Panel.null()
	T.eq(M.sent[1].data, '{"account":654321,"counter":101,"frame_type":"ACK","kc":1}')
	run(15000)
	local ids = {}
	for _, f in ipairs(Panel.received) do
		if F.frameType(f) == "DATA-REQ" then ids[tostring(f.id)] = true end
	end
	for _, id in ipairs({ "2148", "180", "2310", "2149", "2250", "2301", "260" }) do
		T.truthy(ids[id], "requested " .. id)
	end
	T.eq(Properties["Connection Status"], "Connected to 192.168.1.129")
	T.eq(#Panel.violations, 0, table.concat(Panel.violations, "; "))
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "1", "DirectorLink may offer Arm and Disarm")
end)

T.test("zones come from the panel: bindings and Hebrew names", function()
	for z = 1, 8 do T.truthy(M.bindings[100 + z], "binding for zone " .. z) end
	T.eq(M.bindings[109], nil)
	local info = M.findProxy(5001, "PANEL_ZONE_INFO", { ID = "1", NAME = "\215\147\215\156\215\170 \215\155\215\160\215\153\215\161\215\148" })
	T.truthy(info, "zone 1 has the decoded Hebrew name")
	T.truthy(M.findProxy(5001, "PANEL_ZONE_INFO", { ID = "8", NAME = "Zone 8" }), "names paged past 'more:yes'")
end)

T.test("initial state is reported without firing programming", function()
	local state, _, cmd = partitionState()
	T.eq(state, "DISARMED_READY")
	T.eq(cmd, "PARTITION_STATE_INIT")
	T.eq(Properties["Panel Info"], "panel 192.168.1.129, account 654321, 8 zones, exit time 30 s")
end)

T.test("zone open event: contact OPENED and partition not ready", function()
	M.clearProxy()
	setBit(3, 11, true)
	Panel.event(760, 1, 3, 1)
	T.truthy(M.findProxy(103, "OPENED"))
	T.truthy(M.findProxy(P1, "ZONE_STATE", { ZONE_ID = "3", ZONE_OPEN = "true" }))
	local state, _, cmd = partitionState()
	T.eq(state, "DISARMED_NOT_READY")
	T.eq(cmd, "PARTITION_STATE")
	T.eq(Properties["Open Zones"], "3")
	run(500)
	T.eq(F.frameType(lastSentOfType("ACK")), "ACK")
end)

T.test("retransmitted event is ACKed again but handled once", function()
	M.clearProxy()
	Panel.send({ frame_type = "event", counter = Panel.counter, type = 760, qualifier = 1, zone = 3, partition = 1 })
	run(300)
	T.eq(M.findProxy(103, "OPENED"), nil)
	T.eq(lastSentOfType("ACK").counter, Panel.counter)
end)

T.test("arm with an open zone: panel refuses, Navigator offers bypass", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Away", UserCode = "", Bypass = "false", InterfaceID = "ui1" })
	run(1500)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 12)
	T.eq(op.order, 1)
	T.eq(op.password, CODE, "no code typed: the driver's code is used")
	T.truthy(M.findProxy(P1, "ARM_FAILED", { ACTION = "bypass", INTERFACE_ID = "ui1" }))
end)

T.test("arm with bypass: zone bypassed first, then armed with exit delay", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Away", UserCode = "", Bypass = "true", InterfaceID = "ui1" })
	run(3000)
	local write
	for _, f in ipairs(Panel.received) do
		if F.frameType(f) == "DATA" and f.id == 2150 then write = f end
	end
	T.truthy(write, "bypass write sent")
	T.eq(write.start_order, 3)
	T.eq(write.parameters[1], "1")
	T.truthy(M.findProxy(P1, "PARTITION_STATE", { STATE = "EXIT_DELAY", TYPE = "Away", DELAY_TIME_TOTAL = "30" }))
	T.eq(Properties["Bypassed Zones"], "3")
	-- the panel still reads disarmed during the delay: must not flip back
	run(10000)
	T.eq((partitionState()), "EXIT_DELAY")
	run(25000)
	local state, typ = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Away")
	T.eq(#Panel.violations, 0, table.concat(Panel.violations, "; "))
end)

T.test("burglary alarm while armed", function()
	M.clearProxy()
	Panel.event(130, 1, 5, 1)
	local state, typ, cmd = partitionState()
	T.eq(state, "ALARM")
	T.eq(typ, "Burglary")
	T.eq(cmd, "PARTITION_STATE")
	-- a restore while armed keeps the alarm until disarm
	Panel.event(130, 3, 5, 1)
	T.eq((partitionState()), "ALARM")
end)

T.test("disarm needs a code typed on the Control4 screen", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = "", InterfaceID = "ui1" })
	T.truthy(M.findProxy(P1, "DISARM_FAILED", { INTERFACE_ID = "ui1" }))
end)

T.test("wrong code: the panel rejects it and Control4 is told", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = "7531", InterfaceID = "ui1" })
	run(1500)
	T.eq(lastSentOfType("OPERATION").password, "7531")
	T.truthy(M.findProxy(P1, "DISARM_FAILED", { INTERFACE_ID = "ui1" }))
	T.eq((partitionState()), "ALARM")
end)

T.test("right code disarms and clears the alarm", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = CODE, InterfaceID = "ui1" })
	run(3000)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 17)
	T.eq(op.order, 0)
	local state = partitionState()
	T.truthy(state == "DISARMED_READY" or state == "DISARMED_NOT_READY", "disarmed, got " .. tostring(state))
end)

T.test("programming arms Home without a code and confirms the mode via 2310", function()
	M.clearProxy()
	setBit(3, 11, false)
	setBit(3, 7, false)
	Panel.event(760, 3, 3, 1)
	Panel.event(570, 3, 3, 1)
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Home", InterfaceID = "DirectorProgramming" })
	run(40000)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 13)
	local state, typ = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Home")
	-- keypad disarm reported by the panel
	Panel.keys[1] = "2"
	Panel.event(401, 1, 2, 1)
	T.eq((partitionState()), "DISARMED_READY")
end)

local function operationCount()
	local n = 0
	for _, f in ipairs(Panel.received) do
		if F.frameType(f) == "OPERATION" then n = n + 1 end
	end
	return n
end

T.test("DirectorLink without a typed code: refused, never sent with Panel User Code", function()
	M.clearProxy()
	local before = operationCount()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Away", InterfaceID = "DirectorLink" })
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = " ", InterfaceID = "DirectorLink" })
	run(1500)
	T.eq(operationCount(), before, "nothing sent to the panel")
	T.truthy(M.findProxy(P1, "ARM_FAILED", { INTERFACE_ID = "DirectorLink" }))
	T.truthy(M.findProxy(P1, "DISARM_FAILED", { INTERFACE_ID = "DirectorLink" }))
	T.eq((partitionState()), "DISARMED_READY")
end)

T.test("DirectorLink's typed code goes to the panel as typed: a wrong one fails", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Away", UserCode = "1470", InterfaceID = "DirectorLink" })
	run(1500)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 12)
	T.eq(op.password, "1470")
	T.truthy(M.findProxy(P1, "ARM_FAILED", { INTERFACE_ID = "DirectorLink" }))
	T.eq((partitionState()), "DISARMED_READY")
end)

T.test("DirectorLink arms Night and disarms with the typed code", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Night", UserCode = CODE, InterfaceID = "DirectorLink" })
	run(3000)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 14)
	T.eq(op.password, CODE)
	T.truthy(M.findProxy(P1, "PARTITION_STATE", { STATE = "EXIT_DELAY", TYPE = "Night" }))
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = CODE, InterfaceID = "DirectorLink" })
	run(3000)
	T.eq(lastSentOfType("OPERATION").optype, 17)
	T.eq((partitionState()), "DISARMED_READY")
	T.eq(#Panel.violations, 0, table.concat(Panel.violations, "; "))
end)

T.test("Shabbat: armed with operation 43; the panel's Shabbat key reads as armed Shabbat", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_ARM", { ArmType = "Shabbat", UserCode = CODE, InterfaceID = "ui1" })
	run(3000)
	local op = lastSentOfType("OPERATION")
	T.eq(op.optype, 43)
	T.eq(op.password, CODE)
	T.truthy(M.findProxy(P1, "PARTITION_STATE", { STATE = "EXIT_DELAY", TYPE = "Shabbat" }))
	run(Panel.exitTime * 1000 + 5000)
	local state, typ = partitionState()
	T.eq(state, "ARMED")
	T.eq(typ, "Shabbat")
end)

T.test("Shabbat: zones opening and closing are kept from Control4, an alarm is not", function()
	M.clearProxy()
	setBit(4, 11, true)
	Panel.event(760, 1, 4, 1)
	setBit(4, 11, false)
	Panel.event(760, 3, 4, 1)
	setBit(4, 11, true)
	Panel.event(760, 1, 4, 1)
	run(65000) -- a status poll reads the open zone too
	T.eq(M.findProxy(104, "OPENED"), nil, "no contact change")
	T.eq(M.findProxy(104, "CLOSED"), nil)
	T.eq(M.findProxy(5001, "PANEL_ZONE_STATE"), nil, "no panel zone state")
	T.eq(M.findProxy(P1, "ZONE_STATE"), nil, "no partition zone state")
	T.eq((partitionState()), "ARMED")
	Panel.event(130, 1, 5, 1)
	local state, typ = partitionState()
	T.eq(state, "ALARM")
	T.eq(typ, "Burglary")
end)

T.test("after Shabbat each zone is told as it is", function()
	M.clearProxy()
	ReceivedFromProxy(P1, "PARTITION_DISARM", { UserCode = CODE, InterfaceID = "ui1" })
	run(3000)
	T.truthy(M.findProxy(104, "OPENED"), "zone 4 opened during Shabbat")
	T.truthy(M.findProxy(P1, "ZONE_STATE", { ZONE_ID = "4", ZONE_OPEN = "true" }))
	T.eq((partitionState()), "DISARMED_NOT_READY")
	M.clearProxy()
	setBit(4, 11, false)
	Panel.event(760, 3, 4, 1)
	T.truthy(M.findProxy(104, "CLOSED"), "reported again once disarmed")
	T.eq((partitionState()), "DISARMED_READY")
	T.eq(#Panel.violations, 0, table.concat(Panel.violations, "; "))
end)

T.test("panel troubles from the fault list (2250)", function()
	M.clearProxy()
	Panel.faults = { "1", "309", "33C" }
	Panel.event(301, 1, 0, 0)
	run(3000)
	T.truthy(M.findProxy(5001, "TROUBLE_START", { TROUBLE_TEXT = "AC Loss" }))
	T.truthy(M.findProxy(5001, "TROUBLE_START", { TROUBLE_TEXT = "Zone Expander Fault #3" }))
	T.truthy(M.findProxy(5001, "TROUBLE_START", { TROUBLE_TEXT = "Zone Tamper: Zone 3 (zone 3)" }))
	M.clearProxy()
	Panel.faults = { "309" }
	Panel.event(301, 3, 0, 0)
	run(3000)
	T.truthy(M.findProxy(5001, "TROUBLE_CLEAR"))
	T.eq(Properties["Active Troubles"], "Zone Expander Fault #3")
end)

T.test("siren output event", function()
	Panel.event(770, 1, 1, 1)
	T.eq(M.events[#M.events], "Siren Active")
	T.eq((partitionState()), "ALARM")
	Panel.event(770, 3, 1, 1)
	T.eq(M.events[#M.events], "Siren Inactive")
end)

T.test("Composer zone rename and type", function()
	M.clearProxy()
	ReceivedFromProxy(5001, "SET_ZONE_INFO", { ZONE_ID = "2", NAME = "Kitchen PIR", TYPE_ID = "5" })
	T.truthy(M.findProxy(5001, "PANEL_ZONE_INFO", { ID = "2", NAME = "Kitchen PIR", TYPE_ID = "5" }))
	T.eq(PersistData.zoneInfo[2].name, "Kitchen PIR")
end)

T.test("only one request in flight when the panel is slow", function()
	Panel.autoRespond = false
	outstanding = nil
	local before = #Panel.received
	ExecuteCommand("LUA_ACTION", { ACTION = "ReadPanel" })
	run(2000)
	local requests = 0
	for i = before + 1, #Panel.received do
		if F.frameType(Panel.received[i]) ~= "ACK" then requests = requests + 1 end
	end
	T.eq(requests, 1)
end)

T.test("panel stops answering: connection closed, OFFLINE after grace", function()
	M.events = {}
	run(30000) -- three request timeouts
	T.eq(M.closed[#M.closed], Panel.handle)
	T.truthy(Properties["Connection Status"]:find("waiting for it to reconnect"))
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "0", "DirectorLink stops offering Arm and Disarm")
	run(125000)
	T.eq((partitionState()), "OFFLINE")
	T.truthy(M.findProxy(5001, "TROUBLE_START", { IDENTIFIER = "9999" }))
	T.eq(M.events[#M.events], "Communication Lost")
end)

T.test("panel reconnects: communication restored and state resynced", function()
	Panel.autoRespond = true
	outstanding = nil
	M.clearProxy()
	OnServerConnectionStatusChanged(Panel.handle, 7780, "OFFLINE", Panel.address)
	Panel.handle = 11
	Panel.connect()
	Panel.null()
	run(15000)
	T.eq(M.events[#M.events], "Communication Restored")
	T.truthy(M.findProxy(5001, "TROUBLE_CLEAR", { IDENTIFIER = "9999" }))
	T.eq((partitionState()), "DISARMED_READY")
	T.eq(M.vars.DIRECTORLINK_ALARM_CONTROL, "1")
end)

T.test("SIA DC-09 report next to a JSON connection: ACKed, JSON keeps control", function()
	M.sent = {}
	OnServerConnectionStatusChanged(12, 7780, "ONLINE", "192.168.1.129")
	OnServerDataIn(12, '\n9A3B0042"ADM-CID"0001R0L0#654321[#654321|1602 00 000]\r', "192.168.1.129", 1)
	T.eq(M.sent[1].handle, 12)
	T.truthy(M.sent[1].data:find('"ACK"0001R0L0#654321[]', 1, true), "DC-09 ACK sent")
	T.eq(g.mode, "json")
	T.eq(Properties["Connection Status"], "Connected to 192.168.1.129")
	M.sent = {}
end)

T.test("user codes never reach the logs", function()
	local out = M.allOutput()
	T.truthy(out:find("password", 1, true), "trace logging was on")
	T.eq(out:find(CODE, 1, true), nil, "panel code leaked")
	T.eq(out:find("7531", 1, true), nil, "typed code leaked")
	T.eq(out:find("1470", 1, true), nil, "DirectorLink's typed code leaked")
end)

T.done()
