--[[
  DirectorLink · PIMA FORCE for Control4 (DriverWorks)
  Copyright 2026 DirectorLink. Licensed under the Apache License 2.0 (LICENSE, NOTICE).

  Uses the panel's local JSON interface ("Force Interface JSON Format
  Specification" v2.4, see pima_force.lua). The panel is configured with a
  monitoring-station (CMS) path pointing at the Control4 controller, so the
  panel connects to this driver, which listens on a TCP port.

  Bindings
    5001        securitypanel proxy (zone list, troubles)
    5002-5005   security proxies, partitions 1-4 (room bindings 7002-7005)
    101-244     CONTACT_SENSOR provider bindings, one per zone (created at runtime)

  Panel session rules (from the spec and field reports):
    * ACK every EVENT / DATA / null frame, with kc:1 and a numeric account.
    * Only one request (DATA-REQ / OPERATION / DATA write) in flight at a
      time, with a gap between writes - the panel drops frames that arrive
      in the same TCP segment.
    * An ACK only means "received": state is confirmed by reading System Key
      Status (2310) and Zone Status (2149) back from the panel.

  DirectorLink's alarm agreement, version 1 (DirectorLink 1.15.0 and later):
    * DIRECTORLINK_ALARM = "1" (the agreement's version), written at every start.
    * DIRECTORLINK_ALARM_CONTROL = "1" while arming and disarming can work
      (the JSON interface connected and verified), "0" otherwise (receive
      only, or no panel connection). DirectorLink offers Arm and Disarm only
      while it says "1".
    * A PARTITION_ARM or PARTITION_DISARM from DirectorLink (InterfaceID
      "DirectorLink") always carries the code a person typed; the panel
      checks it. It is never carried out with Panel User Code.
    * DIRECTORLINK_ALARM_KEY = "" and DIRECTORLINK_ALARM_WITHOUT_CODE = "none":
      1.2.0 and 1.2.1 sealed DirectorLink's commands (version 2); 1.2.2 no
      longer does (on the controller one X25519 in this driver took 14 s), and
      clears both so that DirectorLink sends the typed code. A sealed command
      ("dl2:...") is refused.
]]

local F = require("pima_force")

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
PANEL_BINDING = 5001
MAX_PARTITIONS = 4             -- FORCE 32/32C/16 support 4 partitions
MAX_ZONES = 144
ZONE_BINDING_BASE = 100

-- Navigator arm buttons (driver.xml <arm_states>) -> PIMA operation types
ARM_OPTYPES = { Away = F.OPTYPE.AWAY, Home = F.OPTYPE.HOME1, Night = F.OPTYPE.HOME2, Shabbat = F.OPTYPE.SHABBAT }

-- Control4 security sensor type ids (SET_ZONE_INFO / PANEL_ZONE_INFO)
ZONE_TYPES = {
	UNKNOWN = 0, CONTACT_SENSOR = 1, EXTERIOR_DOOR = 2, EXTERIOR_WINDOW = 3, INTERIOR_DOOR = 4,
	MOTION_SENSOR = 5, FIRE = 6, GAS = 7, CARBON_MONOXIDE = 8, HEAT = 9, WATER = 10, SMOKE = 11,
	PRESSURE = 12, GLASS_BREAK = 13, GATE = 14, GARAGE_DOOR = 15,
}
ALARM_TYPE_BY_ZONE_TYPE = { [6] = "Fire", [9] = "Fire", [11] = "Fire", [7] = "Gas", [8] = "Carbon Monoxide", [10] = "Water" }
ALARM_PRIORITY = { Fire = 5, Medical = 4, Panic = 3, Duress = 3, Gas = 2, ["Carbon Monoxide"] = 2, Water = 1, Burglary = 0 }

COMM_TROUBLE_ID = 9999
FAULT_TROUBLE_BASE = 100000    -- trouble id = base + raw 2250 fault value

REQUEST_TIMEOUT_MS = 8000
ACK_GAP_MS = 100
WRITE_GAP_MS = 250
OPERATION_GAP_MS = 700         -- field reports: >= 500 ms after an OPERATION
SYNC_START_DELAY_MS = 10000    -- read status after the first null frame, or this long after connecting
RECONNECT_GRACE_S = 120        -- after a disconnect, wait this long before reporting OFFLINE
WATCHDOG_MS = 15000
FAULT_POLL_S = 300
MAX_TIMEOUTS = 3
DEDUP_WINDOW_S = 300
DISPLAY_HOLD_S = 10
ZONE_NAME_PAGE = 32
NO_EXIT_TIME_CHECK_S = 3       -- re-read state this long after an arm when the exit time is unknown
DEBUG_AUTO_OFF_MS = 4 * 60 * 60 * 1000
RX_BUFFER_LIMIT = 16384

-- Receive-only mode (SIA DC-09)
SIA_TROUBLE_BASE = 200000      -- trouble id = base + CID code * 1000 + zone
SIA_SAMPLE_LOGS = 10           -- first reports after a restart are logged even with Debug Mode off
SIA_SUPERVISION_FACTOR = 2.5   -- comm trouble after this many missed link tests
RECEIVE_ONLY_TEXT = "Receive-only mode: arming and disarming from Control4 needs the panel's JSON interface"

-- tools/build.py writes VERSION here in the package
DRIVER_SEMVER = "dev"

-- DirectorLink's alarm agreement (header). Never reorder: Director numbers
-- variables in the order they are added, and DirectorLink reads them by name.
DIRECTORLINK_INTERFACE = "DirectorLink"
AGREEMENT_VARIABLES = {
	{ "DIRECTORLINK_ALARM", "1", "STRING" },
	{ "DIRECTORLINK_ALARM_CONTROL", "0", "STRING" },
	{ "DIRECTORLINK_ALARM_KEY", "", "STRING" },
	{ "DIRECTORLINK_ALARM_WITHOUT_CODE", "none", "STRING" },
}
-- What 1.2.0 and 1.2.1 sent DirectorLink's commands sealed with, and where
-- they kept their private key (deleted at start)
SEALED_PREFIX = "dl2:"
OLD_SECRET_STORE = "directorlink_alarm_secret"

PROPERTY_ORDER = {
	"Debug Mode", "Listen Port", "Account ID", "Panel IP Address", "Panel User Code",
	"Require Code To Arm", "Partitions In Use", "Partition 1 Zones", "Partition 2 Zones",
	"Partition 3 Zones", "Partition 4 Zones", "Zone Count", "Reverse Zone Names",
	"Allow Zone Bypass", "Status Poll Interval (s)", "Link Timeout (s)",
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
g = {
	-- configuration (from properties)
	listenPort = 7780,
	account = nil,                -- number
	accountText = "",             -- as typed (SIA accounts may contain hex digits)
	panelIp = "",
	panelCode = "",
	requireArmCode = false,
	partitionCount = 1,
	partitionZones = {},          -- [p] = set of zone numbers
	zoneCountOverride = 0,
	reverseNames = false,
	allowBypass = true,
	pollInterval = 60,
	linkTimeout = 300,

	-- server / connection
	serverPort = nil,
	clients = {},                 -- [handle] = { address, buf, verified, account }
	active = nil,                 -- handle of the verified panel connection
	online = false,
	lastRx = 0,
	synced = false,
	syncing = false,

	-- outbound
	counter = 0,
	acks = {},
	requests = {},
	inFlight = nil,
	gap = false,
	timeouts = 0,

	-- panel model
	zoneCount = 0,
	panelZoneCount = nil,
	panelNames = {},              -- [z] = name read from the panel (UTF-8)
	zoneInfo = {},                -- [z] = { name =, typeId = } overrides from Composer (persisted)
	zoneBits = {},                -- [z] = 2149 status bits
	systemKey = {},               -- [p] = 2310 value
	alarms = {},                  -- [p] = { [key] = { type =, zone = } } active alarm events
	sirens = {},
	sirenOn = false,
	exitTime = 0,
	exitDelay = {},               -- [p] = { mode, total, endsAt, ours, iface }
	recentEvents = {},
	lastPoll = 0,
	lastFaultPoll = 0,

	-- protocol: nil until the panel talks, "json" or "sia" (receive only)
	mode = nil,
	lastSiaRx = 0,
	lastIdleLinkTest = nil,
	siaLinkInterval = nil,        -- learned from the panel's idle link tests
	siaTroubles = {},             -- [id] = text, from trouble reports
	siaSamples = 0,
	siaAddress = nil,

	-- what Control4 has been told
	reported = nil,
	displayHold = {},
	initMode = true,              -- report state with *_INIT notifications (no programming)

	timers = {},
	dirty = {},
	initializing = false,
}

local function Now() return os.time() end

local function Trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function XmlEscape(s)
	return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function ResetReported()
	local troubles = g.reported and g.reported.troubles or {}
	g.reported = { partition = {}, display = {}, zoneOpen = {}, zoneBypassed = {}, troubles = troubles }
end
ResetReported()

---------------------------------------------------------------------------
-- Logging (user codes are never logged)
---------------------------------------------------------------------------
local LOG_LEVELS = { ERROR = 1, WARN = 2, INFO = 3, TRACE = 4 }
local DEBUG_LEVELS = { Off = 2, On = 3, Trace = 4 }
local SECRET_KEYS = { UserCode = true, USER_CODE = true, Code = true, CODE = true, password = true }

function Log(level, fmt, ...)
	local mode = Properties and Properties["Debug Mode"] or "Off"
	if LOG_LEVELS[level] > (DEBUG_LEVELS[mode] or 2) then return end
	local ok, msg = pcall(string.format, fmt, ...)
	if not ok then msg = tostring(fmt) end
	msg = "PIMA " .. level .. ": " .. msg
	print(msg)
	if level == "ERROR" then C4:ErrorLog(msg) else C4:DebugLog(msg) end
end

local function DumpParams(t)
	if type(t) ~= "table" then return tostring(t) end
	local parts = {}
	for k, v in pairs(t) do
		parts[#parts + 1] = tostring(k) .. "=" .. (SECRET_KEYS[k] and "****" or tostring(v))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
end

function Redact(text)
	return (tostring(text):gsub('"password":"[^"]*"', '"password":"****"'))
end

---------------------------------------------------------------------------
-- Proxy / property helpers
---------------------------------------------------------------------------
function Notify(binding, cmd, params)
	local t = {}
	for k, v in pairs(params or {}) do t[k] = tostring(v) end
	Log("TRACE", "-> %d %s %s", binding, cmd, DumpParams(t))
	C4:SendToProxy(binding, cmd, t, "NOTIFY", true)
end

function NotifyString(binding, cmd, str)
	Log("TRACE", "-> %d %s %s", binding, cmd, str)
	C4:SendToProxy(binding, cmd, str, "NOTIFY")
end

local propertyCache = {}
function SetReadOnlyProperty(name, value)
	value = tostring(value)
	if propertyCache[name] ~= value then
		propertyCache[name] = value
		C4:UpdateProperty(name, value)
	end
end

function SetConnStatus(text)
	if g.connStatus ~= text then
		g.connStatus = text
		Log("INFO", "Status: %s", text)
		SetReadOnlyProperty("Connection Status", text)
	end
	-- Every change of connection or protocol comes with a new status
	UpdateControlMarker()
end

local function Param(t, ...)
	for _, key in ipairs({ ... }) do
		if t[key] ~= nil then return t[key] end
	end
	return nil
end

function StartTimer(key, ms, fn, repeating)
	StopTimer(key)
	local timer
	timer = C4:SetTimer(ms, function()
		if not repeating and g.timers[key] == timer then g.timers[key] = nil end
		local ok, err = pcall(fn)
		if not ok then Log("ERROR", "Timer %s failed: %s", key, tostring(err)) end
	end, repeating == true) -- the controller rejects a nil "repeat" argument
	g.timers[key] = timer
end

function StopTimer(key)
	if g.timers[key] then
		g.timers[key]:Cancel()
		g.timers[key] = nil
	end
end

function DriverVersion()
	local ok, v = pcall(function() return C4:GetDriverConfigInfo("version") end)
	local number = (ok and v and v ~= "") and tostring(v) or "unknown"
	return DRIVER_SEMVER .. " (" .. number .. ")"
end

---------------------------------------------------------------------------
-- Zones and partitions
---------------------------------------------------------------------------
function PartitionBinding(p) return PANEL_BINDING + p end
function ZoneBinding(z) return ZONE_BINDING_BASE + z end

function ZoneName(z)
	local info = g.zoneInfo[z]
	if info and info.name and info.name ~= "" then return info.name end
	if g.panelNames[z] and g.panelNames[z] ~= "" then return g.panelNames[z] end
	return "Zone " .. z
end

function ZoneType(z)
	local info = g.zoneInfo[z]
	return (info and tonumber(info.typeId)) or ZONE_TYPES.CONTACT_SENSOR
end

local function Bits(z) return g.zoneBits[z] or 0 end
function ZoneOpen(z) return F.hasBit(Bits(z), F.ZONE_BIT.OPEN) end
function ZoneBypassed(z)
	return F.hasBit(Bits(z), F.ZONE_BIT.MANUAL_BYPASS) or F.hasBit(Bits(z), F.ZONE_BIT.AUTO_BYPASS)
end
function ZoneAlarmed(z) return F.hasBit(Bits(z), F.ZONE_BIT.ALARMED) end

function SetZoneBit(z, bitIndex, on)
	if z < 1 or z > MAX_ZONES then return end
	g.zoneBits[z] = F.setBit(Bits(z), bitIndex, on)
end

function ZoneInPartition(z, p)
	return p <= g.partitionCount and z <= g.zoneCount
		and g.partitionZones[p] ~= nil and g.partitionZones[p][z] == true
end

function ZonePartitions(z)
	local list = {}
	for p = 1, g.partitionCount do
		if ZoneInPartition(z, p) then list[#list + 1] = p end
	end
	return list
end

function PartitionListString(z)
	local list = ZonePartitions(z)
	return #list > 0 and table.concat(list, ",") or " "
end

function ZoneListText(zones, max)
	max = max or 4
	local names = {}
	for i, z in ipairs(zones) do
		if i > max then
			names[#names + 1] = string.format("+%d more", #zones - max)
			break
		end
		names[#names + 1] = ZoneName(z)
	end
	return table.concat(names, ", ")
end

local function PartitionZonesWhere(p, test)
	local list = {}
	for z = 1, g.zoneCount do
		if ZoneInPartition(z, p) and test(z) then list[#list + 1] = z end
	end
	return list
end

function OpenZonesInPartition(p)
	return PartitionZonesWhere(p, function(z) return ZoneOpen(z) and not ZoneBypassed(z) end)
end

-- Partitions an event applies to (partition 0 = all)
function TargetPartitions(p)
	if p and p >= 1 and p <= g.partitionCount then return { p } end
	local all = {}
	for i = 1, g.partitionCount do all[i] = i end
	return all
end

local function BetterAlarm(a, b)
	if not a then return b end
	if (ALARM_PRIORITY[b] or 0) > (ALARM_PRIORITY[a] or 0) then return b end
	return a
end

-- Returns Control4 STATE, TYPE, display text, delay total, delay remaining.
-- Returns nil when the panel reported a value this driver does not know, so
-- the last report stays rather than guessing.
function PartitionView(p)
	if not g.online then return "OFFLINE", "", "Panel offline" end
	local key = g.systemKey[p]
	local armName = key and F.KEY_ARM_NAMES[key]

	local alarmType, alarmZones = nil, {}
	for _, a in pairs(g.alarms[p] or {}) do
		alarmType = BetterAlarm(alarmType, a.type)
		if a.zone and a.zone > 0 and a.zone <= g.zoneCount then alarmZones[#alarmZones + 1] = a.zone end
	end
	if armName then
		for _, z in ipairs(PartitionZonesWhere(p, ZoneAlarmed)) do
			alarmType = BetterAlarm(alarmType, ALARM_TYPE_BY_ZONE_TYPE[ZoneType(z)] or "Burglary")
			alarmZones[#alarmZones + 1] = z
		end
	end
	if not alarmType and g.sirenOn and g.partitionCount == 1 then alarmType = "Burglary" end
	if alarmType then
		table.sort(alarmZones)
		local text = "ALARM"
		if #alarmZones > 0 then text = text .. ": " .. ZoneListText(alarmZones) end
		return "ALARM", alarmType, text
	end

	local exit = g.exitDelay[p]
	if exit then
		local remaining = math.max(0, exit.endsAt - Now())
		return "EXIT_DELAY", exit.mode or "", "Exit delay", exit.total, remaining
	end

	if key == nil then
		if g.mode == "sia" then return "OFFLINE", "", "Waiting for an arm or disarm report from the panel" end
		return "OFFLINE", "", "Waiting for panel status"
	end
	if key == F.KEY_NOT_EXIST then return "OFFLINE", "", "Partition not defined on the panel" end
	local bypassed = PartitionZonesWhere(p, ZoneBypassed)
	local bypassText = #bypassed > 0 and (" (bypassed: " .. ZoneListText(bypassed) .. ")") or ""
	if armName then return "ARMED", armName, "Armed " .. armName .. bypassText end
	if key ~= F.KEY_DISARMED then return nil end
	local open = OpenZonesInPartition(p)
	if #open > 0 then return "DISARMED_NOT_READY", "", "Not ready: " .. ZoneListText(open) .. bypassText end
	return "DISARMED_READY", "", "Ready" .. bypassText
end

function ReportPartition(p, state, stateType, init, total, remaining)
	local key = state .. "|" .. stateType
	if g.reported.partition[p] == key and not init then return false end
	g.reported.partition[p] = key
	-- *_INIT notifications do not fire programming; an alarm always should
	local cmd = (init and state ~= "ALARM") and "PARTITION_STATE_INIT" or "PARTITION_STATE"
	Notify(PartitionBinding(p), cmd, {
		STATE = state, TYPE = stateType, DELAY_TIME_TOTAL = total or 0, DELAY_TIME_REMAINING = remaining or 0,
		CODE_REQUIRED_TO_CLEAR = true,
	})
	Notify(PANEL_BINDING, "PANEL_PARTITION_STATE", { PARTITION_ID = p, STATE = state, TYPE = stateType })
	Log("INFO", "Partition %d: %s %s", p, state, stateType)
	return true
end

function ReportDisplayText(p, text)
	if g.displayHold[p] and Now() < g.displayHold[p] then return end
	if g.reported.display[p] == text then return end
	g.reported.display[p] = text
	Log("TRACE", "-> %d DISPLAY_TEXT %s", PartitionBinding(p), text)
	C4:SendToProxy(PartitionBinding(p), "DISPLAY_TEXT", text)
end

-- Shows a message on the partition's status line for DISPLAY_HOLD_S seconds
function ShowMessage(p, text)
	g.displayHold[p] = nil
	ReportDisplayText(p, text)
	g.displayHold[p] = Now() + DISPLAY_HOLD_S
end

-- A partition no longer armed for Shabbat: its zones are told as they are now
local shabbatArmed = {}
local function ShabbatEnded()
	for p = 1, g.partitionCount do
		local now = F.KEY_SHABBAT[g.systemKey[p] or 0] == true
		if shabbatArmed[p] and not now then
			Log("INFO", "Partition %d: no longer armed for Shabbat; zones reported again", p)
			for z = 1, g.zoneCount do
				if ZoneInPartition(z, p) then ReportZone(z, false) end
			end
		elseif now and not shabbatArmed[p] then
			Log("INFO", "Partition %d: armed for Shabbat; zone changes are kept from Control4", p)
		end
		shabbatArmed[p] = now
	end
end

function RefreshPartitions(init)
	ShabbatEnded()
	local changed = false
	for p = 1, g.partitionCount do
		local state, stateType, text, total, remaining = PartitionView(p)
		if state then
			if ReportPartition(p, state, stateType, init, total, remaining) then changed = true end
			ReportDisplayText(p, text)
		end
	end
	-- Navigator's partition header reads its state from ALL_PARTITIONS_INFO
	if changed then SendAllPartitionsInfo() end
end

-- Shabbat (1.1.0): while a partition is armed for Shabbat, its zones
-- opening and closing are kept from Control4 (contact connections, the
-- panel's and the partition's zone lists), so that people moving in the
-- house cause nothing there; an alarm is still reported. The driver keeps
-- following the zones, and once the partition is no longer armed for
-- Shabbat it tells Control4 each zone as it is then (ShabbatEnded).
function ShabbatQuiet(z)
	for _, p in ipairs(ZonePartitions(z)) do
		if F.KEY_SHABBAT[g.systemKey[p] or 0] then return true end
	end
	return false
end

function ReportZone(z, init)
	local r = g.reported
	if not init and ShabbatQuiet(z) then return end
	local open, bypassed = ZoneOpen(z), ZoneBypassed(z)
	local openChanged = r.zoneOpen[z] ~= open
	if openChanged or init then
		local contact
		if init then contact = open and "STATE_OPENED" or "STATE_CLOSED" else contact = open and "OPENED" or "CLOSED" end
		Notify(ZoneBinding(z), contact, {})
		Notify(PANEL_BINDING, "PANEL_ZONE_STATE", { ZONE_ID = z, ZONE_OPEN = open, INITIALIZING = init })
	end
	if openChanged or init or r.zoneBypassed[z] ~= bypassed then
		for _, p in ipairs(ZonePartitions(z)) do
			Notify(PartitionBinding(p), "ZONE_STATE", { ZONE_ID = z, ZONE_OPEN = open, ZONE_BYPASSED = bypassed })
		end
	end
	r.zoneOpen[z], r.zoneBypassed[z] = open, bypassed
end

function ReportAll(init)
	for z = 1, g.zoneCount do ReportZone(z, init) end
	RefreshPartitions(init)
	UpdateDiagnostics()
end

-- troubles: [id] = text. Replaces every panel trouble except the
-- communication trouble, which the driver manages itself.
function ReportTroubles(troubles)
	local r = g.reported.troubles
	for id, text in pairs(troubles) do
		if r[id] ~= text then
			r[id] = text
			Notify(PANEL_BINDING, "TROUBLE_START", { TROUBLE_TEXT = text, IDENTIFIER = id })
			Log("INFO", "Trouble: %s", text)
		end
	end
	for id, text in pairs(r) do
		if id ~= COMM_TROUBLE_ID and troubles[id] == nil then
			r[id] = nil
			Notify(PANEL_BINDING, "TROUBLE_CLEAR", { IDENTIFIER = id })
			Log("INFO", "Trouble cleared: %s", text)
		end
	end
	UpdateDiagnostics()
end

function SendZoneInfo(z)
	Notify(PANEL_BINDING, "PANEL_ZONE_INFO", {
		ID = z, NAME = ZoneName(z), TYPE_ID = ZoneType(z), PARTITIONS = PartitionListString(z), IS_OPEN = ZoneOpen(z),
	})
end

function SendAllZonesInfo()
	local parts = { "<zones>" }
	for z = 1, g.zoneCount do
		parts[#parts + 1] = string.format(
			"<zone><id>%d</id><name>%s</name><type_id>%d</type_id><partitions>%s</partitions>"
				.. "<can_bypass>%s</can_bypass><is_open>%s</is_open></zone>",
			z, XmlEscape(ZoneName(z)), ZoneType(z), PartitionListString(z), tostring(g.allowBypass), tostring(ZoneOpen(z)))
	end
	parts[#parts + 1] = "</zones>"
	NotifyString(PANEL_BINDING, "ALL_ZONES_INFO", table.concat(parts))
end

function SendAllPartitionsInfo()
	local parts = { "<partitions>" }
	for p = 1, MAX_PARTITIONS do
		local state, stateType = PartitionView(p)
		if p > g.partitionCount or not state then state, stateType = "OFFLINE", "" end
		parts[#parts + 1] = string.format(
			'<partition><id>%d</id><enabled>%s</enabled><binding_id>%d</binding_id><state type="%s">%s</state></partition>',
			p, tostring(p <= g.partitionCount), PartitionBinding(p), XmlEscape(stateType), state)
	end
	parts[#parts + 1] = "</partitions>"
	NotifyString(PANEL_BINDING, "ALL_PARTITIONS_INFO", table.concat(parts))
end

function SendCodeRequired()
	for p = 1, g.partitionCount do
		C4:SendToProxy(PartitionBinding(p), "CODE_REQUIRED", { CODE_REQUIRED_TO_ARM = tostring(g.requireArmCode) })
	end
end

-- Creates / removes the per-zone CONTACT_SENSOR bindings (101..100+count)
function EnsureZoneBindings(count)
	local have = tonumber(PersistData.zoneBindings) or 0
	for z = have + 1, count do
		C4:AddDynamicBinding(ZoneBinding(z), "CONTROL", true, "Zone " .. z, "CONTACT_SENSOR", false, false)
	end
	for z = count + 1, have do
		C4:RemoveDynamicBinding(ZoneBinding(z))
	end
	PersistData.zoneBindings = count
end

-- Tells the proxies about partitions, zone membership and current state
function AnnounceConfig()
	EnsureZoneBindings(g.zoneCount)
	for p = 1, MAX_PARTITIONS do
		local b = PartitionBinding(p)
		local enabled = p <= g.partitionCount
		Notify(b, "PARTITION_ENABLED", { ENABLED = enabled })
		if enabled then
			Notify(b, "CLEAR_ZONE_LIST", {})
			for z = 1, g.zoneCount do
				if ZoneInPartition(z, p) then Notify(b, "HAS_ZONE", { ZONE_ID = z }) end
			end
		end
	end
	SendCodeRequired()

	local previous = tonumber(PersistData.announcedZones) or 0
	for z = 1, g.zoneCount do SendZoneInfo(z) end
	for z = g.zoneCount + 1, previous do
		Notify(PANEL_BINDING, "PANEL_REMOVE_ZONE", { ID = z })
	end
	PersistData.announcedZones = g.zoneCount

	ResetReported()
	ReportAll(true)
	SendAllPartitionsInfo()
	Notify(PANEL_BINDING, "PANEL_INITIALIZED", {})
end

function ApplyZoneCount()
	local n = g.zoneCountOverride
	if n <= 0 then n = g.panelZoneCount or tonumber(PersistData.zoneCount) or 0 end
	n = math.max(0, math.min(n, MAX_ZONES))
	if n ~= g.zoneCount then
		g.zoneCount = n
		g.dirty.announce = true
	end
end

local function ZoneListOf(test)
	local list = {}
	for z = 1, g.zoneCount do
		if test(z) then list[#list + 1] = z end
	end
	return #list > 0 and table.concat(list, ", ") or "None"
end

function UpdateDiagnostics()
	SetReadOnlyProperty("Open Zones", ZoneListOf(ZoneOpen))
	SetReadOnlyProperty("Bypassed Zones", ZoneListOf(ZoneBypassed))
	SetReadOnlyProperty("Alarmed Zones", ZoneListOf(ZoneAlarmed))
	local ids, texts = {}, {}
	for id in pairs(g.reported.troubles) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do texts[#texts + 1] = g.reported.troubles[id] end
	SetReadOnlyProperty("Active Troubles", #texts > 0 and table.concat(texts, "; ") or "None")
	local sirens = {}
	if g.sirens[1] then sirens[#sirens + 1] = "external" end
	if g.sirens[2] then sirens[#sirens + 1] = "internal" end
	SetReadOnlyProperty("Sirens", #sirens > 0 and ("ON: " .. table.concat(sirens, ", ")) or "Off")
end

function UpdatePanelInfo()
	local parts = {}
	local c = g.active and g.clients[g.active]
	if c then parts[#parts + 1] = "panel " .. tostring(c.address) end
	if g.mode == "sia" then parts[#parts + 1] = "receive only (SIA DC-09) from " .. tostring(g.siaAddress or "?") end
	if g.accountText ~= "" then parts[#parts + 1] = "account " .. g.accountText end
	parts[#parts + 1] = g.zoneCount .. " zones"
	if g.exitTime > 0 then parts[#parts + 1] = "exit time " .. g.exitTime .. " s" end
	SetReadOnlyProperty("Panel Info", table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- Online / offline
---------------------------------------------------------------------------
function SetOnline()
	if g.reported.troubles[COMM_TROUBLE_ID] then
		g.reported.troubles[COMM_TROUBLE_ID] = nil
		Notify(PANEL_BINDING, "TROUBLE_CLEAR", { IDENTIFIER = COMM_TROUBLE_ID })
		UpdateDiagnostics()
		C4:FireEvent("Communication Restored")
	end
	if g.online then return end
	g.online = true
	g.initMode = true
	Log("INFO", "Panel communication established")
end

function GoOffline(reason)
	if not g.online then return end
	g.online = false
	for p in pairs(g.exitDelay) do EndExitDelay(p) end
	Log("WARN", "Communication with panel lost: %s", reason)
	RefreshPartitions(false)
	local text = "Communication with panel lost"
	g.reported.troubles[COMM_TROUBLE_ID] = text
	Notify(PANEL_BINDING, "TROUBLE_START", { TROUBLE_TEXT = text, IDENTIFIER = COMM_TROUBLE_ID })
	UpdateDiagnostics()
	C4:FireEvent("Communication Lost")
end

---------------------------------------------------------------------------
-- Outbound: ACKs first, one request in flight, gap between writes
---------------------------------------------------------------------------
local function ActiveVerified()
	return g.active ~= nil and g.clients[g.active] ~= nil and g.clients[g.active].verified
end

---------------------------------------------------------------------------
-- DirectorLink's alarm agreement (header)
---------------------------------------------------------------------------
local agreementValues = {}

local function SetAgreementVariable(name, value, force)
	if agreementValues[name] == value and not force then return end
	agreementValues[name] = value
	pcall(function() C4:SetVariable(name, value) end)
end

-- Added in OnDriverInit; Director keeps an added variable at its default
function AddAgreementVariables()
	for _, v in ipairs(AGREEMENT_VARIABLES) do
		pcall(function() C4:AddVariable(v[1], v[2], v[3], true, false) end)
		agreementValues[v[1]] = v[2]
	end
end

-- Whether an arm or disarm can reach the panel now: the same test
-- ArmPartition and DisarmPartition make
function CanControl()
	return g.mode == "json" and ActiveVerified() == true
end

function UpdateControlMarker(force)
	SetAgreementVariable("DIRECTORLINK_ALARM_CONTROL", CanControl() and "1" or "0", force)
end

-- Written on every start, so they are right after a driver update too
function WriteAgreementVariables()
	SetAgreementVariable("DIRECTORLINK_ALARM", "1", true)
	SetAgreementVariable("DIRECTORLINK_ALARM_KEY", "", true)
	SetAgreementVariable("DIRECTORLINK_ALARM_WITHOUT_CODE", "none", true)
	UpdateControlMarker(true)
end

function AgreementVariable(name)
	return agreementValues[name]
end

function Write(text, desc)
	if not g.active then return false end
	Log("TRACE", ">>> %s", Redact(text))
	C4:ServerSend(g.active, text)
	return true
end

function StartGap(ms)
	g.gap = true
	StartTimer("gap", ms, function()
		g.gap = false
		Pump()
	end)
end

function Pump()
	if not g.active or g.gap then return end
	local ack = table.remove(g.acks, 1)
	if ack then
		Write(ack, "ACK")
		StartGap(ACK_GAP_MS)
		return
	end
	if not ActiveVerified() then return end
	-- a marker callback may itself start a request, so re-check every pass
	while #g.requests > 0 and not g.inFlight and not g.gap do
		local req = table.remove(g.requests, 1)
		if req.kind == "marker" then
			if req.onDone then pcall(req.onDone, true) end
		else
			g.counter = g.counter % 9999 + 1
			req.counter = g.counter
			local text, err = req.build(req.counter)
			if text then
				g.inFlight = req
				Write(text, req.desc)
				StartTimer("request", REQUEST_TIMEOUT_MS, OnRequestTimeout)
				StartGap(req.kind == "op" and OPERATION_GAP_MS or WRITE_GAP_MS)
				return
			end
			Log("ERROR", "Cannot send %s: %s", req.desc, tostring(err))
			if req.onDone then pcall(req.onDone, false, err) end
		end
	end
end

function QueueRequest(req)
	table.insert(g.requests, req)
	Pump()
end

-- Runs fn once every request queued before it has finished
function QueueMarker(fn)
	QueueRequest({ kind = "marker", onDone = fn })
end

function QueueAck(frame)
	table.insert(g.acks, F.ack(g.account, tonumber(frame.counter) or 0))
	Pump()
end

function CompleteRequest(ok, result)
	local req = g.inFlight
	if not req then return end
	g.inFlight = nil
	StopTimer("request")
	if ok then g.timeouts = 0 end
	if req.onDone then
		local good, err = pcall(req.onDone, ok, result)
		if not good then Log("ERROR", "%s handler failed: %s", req.desc, tostring(err)) end
	end
	Pump()
end

function OnRequestTimeout()
	local req = g.inFlight
	if not req then return end
	g.timeouts = g.timeouts + 1
	Log("WARN", "No response to %s (%d in a row)", req.desc, g.timeouts)
	CompleteRequest(false, "no response from panel")
	if g.timeouts >= MAX_TIMEOUTS then CloseActive("panel stopped answering") end
end

function FailAllRequests(reason)
	local pending = g.requests
	local inFlight = g.inFlight
	g.requests, g.inFlight, g.acks = {}, nil, {}
	StopTimer("request")
	if inFlight then table.insert(pending, 1, inFlight) end
	for _, req in ipairs(pending) do
		if req.onDone and req.kind ~= "marker" then pcall(req.onDone, false, reason) end
	end
end

-- DATA-REQ with automatic paging ("more":"yes"). onDone(ok, { id, start, params })
function RequestData(id, startOrder, stopOrder, onDone)
	local req = { kind = "data", id = id, start = startOrder, stop = stopOrder, firstStart = startOrder, collected = {}, pages = 0 }
	req.desc = string.format("DATA-REQ %d [%d-%s]", id, startOrder, stopOrder and tostring(stopOrder) or "end")
	req.build = function(counter)
		return F.dataRequest(g.account, counter, g.panelCode, req.id, req.start, req.stop)
	end
	req.onDone = onDone or function(ok, r)
		if ok then ProcessData(r.id, r.start, r.params) end
	end
	QueueRequest(req)
	return req
end

---------------------------------------------------------------------------
-- Panel data
---------------------------------------------------------------------------
function OnSystemKeys(start, params)
	for i, v in ipairs(params) do
		local p = start + i - 1
		local key = tonumber(v)
		if p >= 1 and p <= 16 and key then
			local old = g.systemKey[p]
			if g.exitDelay[p] and key == F.KEY_DISARMED then
				-- the panel may read disarmed until its exit delay ends
			else
				g.systemKey[p] = key
				if key == F.KEY_DISARMED and old ~= F.KEY_DISARMED then g.alarms[p] = nil end
			end
			if key ~= F.KEY_NOT_EXIST and key ~= F.KEY_DISARMED and not F.KEY_ARM_NAMES[key] then
				Log("WARN", "Partition %d: unknown system key value %d", p, key)
			end
		end
	end
	RefreshPartitions(g.initMode)
end

function OnZoneStatus(params)
	local zones = F.decodeZoneStatus(params)
	for z = 1, MAX_ZONES do g.zoneBits[z] = zones[z] end
	ReportAll(g.initMode)
end

function OnFaults(params)
	g.lastFaultPoll = Now()
	local troubles = {}
	for _, f in ipairs(F.decodeFaults(params)) do
		local text = f.text
		if f.zone then text = string.format("%s: %s (zone %d)", text, ZoneName(f.zone), f.zone) end
		troubles[FAULT_TROUBLE_BASE + f.key] = text
	end
	ReportTroubles(troubles)
end

function ApplySiren()
	local on = (g.sirens[1] or g.sirens[2]) == true
	if on ~= g.sirenOn then
		g.sirenOn = on
		Log("INFO", "Siren %s", on and "on" or "off")
		C4:FireEvent(on and "Siren Active" or "Siren Inactive")
		RefreshPartitions(false)
	end
	UpdateDiagnostics()
end

function OnZoneCount(n)
	if not n then return end
	g.panelZoneCount = math.max(0, math.min(n, MAX_ZONES))
	PersistData.zoneCount = g.panelZoneCount
	ApplyZoneCount()
	if not g.initializing then FlushDirty() end
	UpdatePanelInfo()
	RequestZoneNames(1)
end

function RequestZoneNames(start)
	if g.zoneCount < start then return end
	local stop = math.min(start + ZONE_NAME_PAGE - 1, g.zoneCount)
	RequestData(F.PARAM.ZONE_NAME, start, stop, function(ok, r)
		if not ok then return end
		OnZoneNames(r.start, r.params)
		RequestZoneNames(stop + 1)
	end)
end

function OnZoneNames(start, params)
	local changed = false
	for i, raw in ipairs(params) do
		local z = start + i - 1
		if z >= 1 and z <= MAX_ZONES then
			local name = F.decodeText(raw, g.reverseNames)
			if name == "" then name = nil end
			if g.panelNames[z] ~= name then
				g.panelNames[z] = name
				changed = true
				if z <= g.zoneCount then SendZoneInfo(z) end
			end
		end
	end
	PersistData.panelNames = g.panelNames
	PersistData.namesReversed = g.reverseNames
	if changed then
		g.reported.display = {}
		RefreshPartitions(false)
	end
end

function ProcessData(id, start, params)
	if id == F.PARAM.SYSTEM_KEY then
		OnSystemKeys(start, params)
	elseif id == F.PARAM.ZONE_STATUS then
		OnZoneStatus(params)
	elseif id == F.PARAM.FAULTS then
		OnFaults(params)
	elseif id == F.PARAM.OUTPUTS then
		for o, on in pairs(F.decodeFlags(params, start)) do
			if o == 1 or o == 2 then g.sirens[o] = on end
		end
		ApplySiren()
	elseif id == F.PARAM.ZONE_COUNT then
		OnZoneCount(tonumber(params[1]))
	elseif id == F.PARAM.ZONE_NAME then
		OnZoneNames(start, params)
	elseif id == F.PARAM.EXIT_TIME then
		g.exitTime = math.max(0, math.min(tonumber(params[1]) or 0, 600))
		UpdatePanelInfo()
	else
		Log("INFO", "Unhandled DATA id %s", tostring(id))
	end
end

function PollStatus()
	g.lastPoll = Now()
	RequestData(F.PARAM.SYSTEM_KEY, 1, 16)
	RequestData(F.PARAM.ZONE_STATUS, 1, nil)
	RequestData(F.PARAM.OUTPUTS, 1, 2)
end

function RequestFaults()
	g.lastFaultPoll = Now()
	RequestData(F.PARAM.FAULTS, 1, nil)
end

local function Debounce(key, ms, fn)
	if ActiveVerified() and F.isValidCode(g.panelCode) then StartTimer(key, ms, fn) end
end

-- Full read of the panel; state is reported without firing programming
function StartSync(reason)
	StopTimer("syncStart")
	if not ActiveVerified() or g.syncing then return end
	if not F.isValidCode(g.panelCode) then
		g.synced, g.initMode = true, false
		SetConnStatus("Connected - set 'Panel User Code' to read zones and status")
		return
	end
	g.syncing = true
	Log("INFO", "Reading panel status (%s)", reason)
	SetConnStatus("Connected - reading panel status")
	RequestData(F.PARAM.ZONE_COUNT, 1, 1)
	RequestData(F.PARAM.EXIT_TIME, 1, 1)
	PollStatus()
	RequestFaults()
	QueueMarker(function()
		g.syncing, g.synced, g.initMode = false, true, false
		local c = g.active and g.clients[g.active]
		SetConnStatus("Connected" .. (c and (" to " .. tostring(c.address)) or ""))
		UpdatePanelInfo()
	end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
function IsDuplicateEvent(f)
	local key = table.concat({ tostring(f.counter), tostring(f.type), tostring(f.qualifier),
		tostring(f.zone), tostring(f.partition) }, "|")
	local seen = g.recentEvents[key]
	g.recentEvents[key] = Now()
	return seen ~= nil and Now() - seen < DEDUP_WINDOW_S
end

local function DescribeEvent(t, q, zone, p, info)
	local text = info and info.text or ("Event " .. tostring(t))
	local kind = info and info.kind
	if kind == "arm" then
		text = (q == 3 and "Armed" or "Disarmed") .. " (" .. text .. (zone > 0 and (", user " .. zone) or "") .. ")"
	elseif kind == "zone" then
		text = ZoneName(zone) .. (q == 1 and " opened" or " closed")
	elseif kind == "bypass" then
		text = ZoneName(zone) .. (q == 1 and " bypassed" or " unbypassed")
	elseif kind == "output" then
		text = "Output " .. zone .. (q == 1 and " on" or " off")
	else
		if q == 3 then text = text .. " restored" end
		if zone > 0 and (kind == "alarm" or t == 138 or t == 144 or t == 381 or t == 384 or t == 373) then
			text = text .. ": " .. ZoneName(zone)
		end
	end
	if p > 0 then text = text .. " [partition " .. p .. "]" end
	return text
end

function HandleEvent(f)
	local t = tonumber(f.type) or 0
	local q = tonumber(f.qualifier) or 0
	local zone = tonumber(f.zone) or 0
	local p = tonumber(f.partition) or 0
	local info = F.CID[t]
	-- Contact-ID 3xx codes are all trouble reports
	if not info and t >= 300 and t < 400 then info = { kind = "trouble", text = "Trouble " .. t } end
	local summary = DescribeEvent(t, q, zone, p, info)
	Log("INFO", "Event %d-%d-%d: %s", t, q, zone, summary)
	SetReadOnlyProperty("Last Event", os.date("%H:%M:%S ") .. summary)
	if not info then return end
	local receiveOnly = (g.mode == "sia")

	-- receive only: zones appear as the panel reports them
	if receiveOnly and zone > g.zoneCount and zone <= MAX_ZONES and g.zoneCountOverride <= 0
		and (info.kind == "zone" or info.kind == "bypass" or t == 130 or t == 110) then
		Log("INFO", "Zone %d reported: zone count is now %d", zone, zone)
		g.panelZoneCount = zone
		PersistData.zoneCount = zone
		ApplyZoneCount()
		FlushDirty()
	end

	if info.kind == "zone" then
		SetZoneBit(zone, F.ZONE_BIT.OPEN, q == 1)
		if zone <= g.zoneCount then ReportZone(zone, false) end
		RefreshPartitions(false)
		UpdateDiagnostics()
	elseif info.kind == "bypass" then
		SetZoneBit(zone, F.ZONE_BIT.MANUAL_BYPASS, q == 1)
		if zone <= g.zoneCount then ReportZone(zone, false) end
		g.reported.display = {}
		RefreshPartitions(false)
		UpdateDiagnostics()
	elseif info.kind == "alarm" then
		-- duress reports a code / keyfob in the zone field, not a zone
		local alarmZone = (t ~= 121) and zone or 0
		if alarmZone > 0 then SetZoneBit(alarmZone, F.ZONE_BIT.ALARMED, q == 1) end
		for _, pp in ipairs(TargetPartitions(p)) do
			local key = t .. ":" .. zone
			if q == 1 then
				g.alarms[pp] = g.alarms[pp] or {}
				g.alarms[pp][key] = { type = info.alarm, zone = alarmZone }
			elseif g.alarms[pp] and g.systemKey[pp] == F.KEY_DISARMED then
				-- while armed the alarm stays until disarm, like the keypad
				g.alarms[pp][key] = nil
			end
		end
		RefreshPartitions(false)
		UpdateDiagnostics()
	elseif info.kind == "arm" then
		for _, pp in ipairs(TargetPartitions(p)) do
			if q == 1 then
				EndExitDelay(pp)
				g.systemKey[pp] = F.KEY_DISARMED
				g.alarms[pp] = nil
				if receiveOnly then
					-- no zone status to read back: alarm memory ends with the disarm
					for z = 1, g.zoneCount do
						if ZoneInPartition(z, pp) then SetZoneBit(z, F.ZONE_BIT.ALARMED, false) end
					end
				end
			elseif q == 3 and receiveOnly then
				-- the panel reports the arm when its exit delay is over
				EndExitDelay(pp)
				g.systemKey[pp] = F.CID_HOME_ARM[t] and 4 or 3
			elseif q == 3 and not g.exitDelay[pp] and g.systemKey[pp] ~= nil
				and not F.KEY_ARM_NAMES[g.systemKey[pp]] then
				BeginExitDelay(pp, F.CID_HOME_ARM[t] and "Home" or "", false)
			end
		end
		RefreshPartitions(false)
		UpdateDiagnostics()
		Debounce("statusPoll", 1500, PollStatus)
	elseif info.kind == "output" then
		if zone == 1 or zone == 2 then
			g.sirens[zone] = (q == 1)
			ApplySiren()
		end
	elseif info.kind == "trouble" and receiveOnly then
		local id = SIA_TROUBLE_BASE + t * 1000 + zone
		g.siaTroubles[id] = (q ~= 3) and DescribeEvent(t, 1, zone, 0, info) or nil
		PersistData.siaTroubles = g.siaTroubles
		ReportTroubles(g.siaTroubles)
	elseif info.kind == "trouble" then
		Debounce("faultPoll", 2000, RequestFaults)
	elseif info.kind == "config" then
		Debounce("configPoll", 5000, function() RequestData(F.PARAM.ZONE_COUNT, 1, 1) end)
	end
	if t == 421 then C4:FireEvent("Access Denied") end
end

---------------------------------------------------------------------------
-- Exit delay: shown as a countdown after an arm, then confirmed by 2310
---------------------------------------------------------------------------
function BeginExitDelay(p, mode, ours, iface)
	local total = g.exitTime
	if total <= 0 then
		-- No exit time known: confirm the arm with a status read shortly
		StartTimer("exit" .. p, NO_EXIT_TIME_CHECK_S * 1000, function() ConfirmArm(p, ours, iface) end)
		return
	end
	g.exitDelay[p] = { mode = mode, total = total, endsAt = Now() + total, ours = ours, iface = iface }
	RefreshPartitions(false)
	StartTimer("exit" .. p, (total + 2) * 1000, function()
		g.exitDelay[p] = nil
		ConfirmArm(p, ours, iface)
	end)
end

function EndExitDelay(p)
	StopTimer("exit" .. p)
	g.exitDelay[p] = nil
end

-- Reads 2310; if the partition is still disarmed, an arm sent by this
-- driver is reported as failed (usually an open zone at the end of the delay)
function ConfirmArm(p, ours, iface)
	if not ActiveVerified() then
		RefreshPartitions(false)
		return
	end
	RequestData(F.PARAM.SYSTEM_KEY, 1, 16, function(ok, r)
		if ok then OnSystemKeys(r.start, r.params) end
		if ours and g.systemKey[p] == F.KEY_DISARMED then
			ArmFailed(p, "NA", iface, "Arm failed: the panel is not armed")
		end
		RefreshPartitions(false)
	end)
end

---------------------------------------------------------------------------
-- Commands to the panel
---------------------------------------------------------------------------
function ArmFailed(p, action, iface, text)
	Log("WARN", "Arm partition %d failed: %s", p, text or action)
	Notify(PartitionBinding(p), "ARM_FAILED", { ACTION = action, INTERFACE_ID = iface or "" })
	if text then ShowMessage(p, text) end
end

function DisarmFailed(p, iface, text)
	Log("WARN", "Disarm partition %d failed: %s", p, text)
	Notify(PartitionBinding(p), "DISARM_FAILED", { INTERFACE_ID = iface or "" })
	ShowMessage(p, text)
end

-- Code to send with an operation: programming uses the driver's code, a
-- code typed on a Control4 screen is sent as-is (the panel checks it).
-- DirectorLink's commands carry a typed code and never fall back to the
-- driver's code (DirectorLink's alarm agreement).
local function ResolveCode(t, codeRequired)
	local iface = Param(t, "InterfaceID", "INTERFACE_ID") or ""
	local typed = Trim(Param(t, "UserCode", "USER_CODE") or "")
	if iface == DIRECTORLINK_INTERFACE then
		if typed:sub(1, #SEALED_PREFIX) == SEALED_PREFIX then
			Log("WARN", "DirectorLink sent a sealed command: this driver takes the typed code only (DirectorLink reads that again within seconds)")
			return nil
		end
		return typed ~= "" and typed or nil
	end
	if iface == "DirectorProgramming" then return g.panelCode end
	if typed ~= "" then return typed end
	if codeRequired then return nil end
	return g.panelCode
end

local function CodeProblem(code)
	if F.isValidCode(code) then return nil end
	if code == g.panelCode then return "Set 'Panel User Code' in the driver properties" end
	return "Invalid code"
end

function SendArm(p, optype, mode, code, iface, order)
	local req = { kind = "op", desc = string.format("ARM %s partition %d", mode, p) }
	req.build = function(counter) return F.operation(g.account, counter, code, optype, p, order) end
	req.onDone = function(ok, reason)
		if ok then
			Log("INFO", "Panel accepted arm %s of partition %d", mode, p)
			BeginExitDelay(p, mode, true, iface)
			return
		end
		reason = tostring(reason or "rejected")
		-- The spec disagrees with itself on 'order' for arming (0 vs 1)
		if order == 1 and (reason:find("Order") or reason:find("Parameter")) then
			Log("INFO", "Retrying arm with order 0")
			return SendArm(p, optype, mode, code, iface, 0)
		end
		local open = OpenZonesInPartition(p)
		if #open > 0 and g.allowBypass then
			-- Navigator then lists the open zones and offers to bypass them
			ArmFailed(p, "bypass", iface, "Open zones: " .. ZoneListText(open))
		else
			ArmFailed(p, "NA", iface, "Arm failed: " .. reason)
		end
	end
	QueueRequest(req)
end

function SendDisarm(p, code, iface)
	local req = { kind = "op", desc = string.format("DISARM partition %d", p) }
	req.build = function(counter) return F.operation(g.account, counter, code, F.OPTYPE.DISARM, p, 0) end
	req.onDone = function(ok, reason)
		if ok then
			Log("INFO", "Panel accepted disarm of partition %d", p)
			EndExitDelay(p)
			-- Disarmed now: a FORCE reads armed from the start of its exit delay,
			-- so without this the partition showed Armed for a moment before the
			-- status read (1.2.2). The status read still follows.
			if g.systemKey[p] ~= F.KEY_DISARMED then
				g.systemKey[p] = F.KEY_DISARMED
				g.alarms[p] = nil
			end
			Debounce("statusPoll", 500, PollStatus)
			RefreshPartitions(false)
			return
		end
		local alarm = g.alarms[p] and next(g.alarms[p])
		if g.systemKey[p] == F.KEY_DISARMED and not alarm and not g.exitDelay[p] then
			-- e.g. "all partitions are disarmed": nothing to do
			Log("INFO", "Partition %d was already disarmed (%s)", p, tostring(reason))
			RefreshPartitions(false)
		else
			DisarmFailed(p, iface, "Disarm failed: " .. tostring(reason))
		end
	end
	QueueRequest(req)
end

function ArmPartition(p, t)
	local iface = Param(t, "InterfaceID", "INTERFACE_ID") or ""
	local mode = Param(t, "ArmType", "ARM_TYPE") or ""
	local optype = ARM_OPTYPES[mode]
	if not optype then return ArmFailed(p, "NA", iface, "Unsupported arm mode: " .. mode) end
	if p > g.partitionCount then return ArmFailed(p, "NA", iface, "Partition not in use") end
	if g.mode == "sia" then return ArmFailed(p, "NA", iface, RECEIVE_ONLY_TEXT) end
	if not ActiveVerified() then return ArmFailed(p, "NA", iface, "Arm failed: panel not connected") end
	local code = ResolveCode(t, g.requireArmCode)
	if not code then return ArmFailed(p, "keypad", iface, nil) end
	local problem = CodeProblem(code)
	if problem then return ArmFailed(p, "NA", iface, problem) end
	if tostring(Param(t, "Bypass", "BYPASS")) == "true" and g.allowBypass then
		for _, z in ipairs(OpenZonesInPartition(p)) do QueueBypass(z, true) end
	end
	SendArm(p, optype, mode, code, iface, 1)
end

function DisarmPartition(p, t)
	local iface = Param(t, "InterfaceID", "INTERFACE_ID") or ""
	if p > g.partitionCount then return DisarmFailed(p, iface, "Partition not in use") end
	if g.mode == "sia" then return DisarmFailed(p, iface, RECEIVE_ONLY_TEXT) end
	if not ActiveVerified() then return DisarmFailed(p, iface, "Disarm failed: panel not connected") end
	local code = ResolveCode(t, true)
	if not code then return DisarmFailed(p, iface, "Enter your alarm code to disarm") end
	local problem = CodeProblem(code)
	if problem then return DisarmFailed(p, iface, problem) end
	SendDisarm(p, code, iface)
end

-- Cancel during an exit delay (Navigator sends no code): disarm with the
-- driver's code, only while the countdown is running
function CancelArm(p)
	if g.mode == "sia" then return ShowMessage(p, RECEIVE_ONLY_TEXT) end
	local exit = g.exitDelay[p]
	if not exit then return Log("INFO", "Arm cancel ignored: partition %d is not in exit delay", p) end
	if CodeProblem(g.panelCode) then return ShowMessage(p, "Enter your code to disarm") end
	SendDisarm(p, g.panelCode, exit.iface or "")
end

function QueueBypass(z, on)
	local req = { kind = "write", desc = string.format("%s zone %d", on and "BYPASS" or "UNBYPASS", z) }
	req.build = function(counter)
		return F.dataWrite(g.account, counter, g.panelCode, F.PARAM.BYPASS, z, { on and "1" or "0" })
	end
	req.onDone = function(ok, reason)
		if not ok then Log("WARN", "%s failed: %s", req.desc, tostring(reason)) end
		-- the ACK alone is not proof: read the zone status back
		Debounce("statusPoll", 1000, PollStatus)
	end
	QueueRequest(req)
end

function SetZoneBypass(z, on)
	if not g.allowBypass then return Log("WARN", "Zone bypass is disabled in the driver properties") end
	if not z or z < 1 or z > g.zoneCount then return Log("WARN", "Bypass: invalid zone %s", tostring(z)) end
	if g.mode == "sia" then return Log("WARN", "Bypass zone %d: %s", z, RECEIVE_ONLY_TEXT) end
	if not ActiveVerified() then return Log("WARN", "Bypass zone %d: panel not connected", z) end
	if CodeProblem(g.panelCode) then return Log("WARN", "Bypass needs 'Panel User Code'") end
	if ZoneBypassed(z) == on then
		return Log("INFO", "Zone %d is already %s", z, on and "bypassed" or "not bypassed")
	end
	QueueBypass(z, on)
end

function SetOutput(n, on)
	if not n or n < 1 or n > 8 then return Log("WARN", "Output must be 1-8") end
	if g.mode == "sia" then return Log("WARN", "Output %d: %s", n, RECEIVE_ONLY_TEXT) end
	if not ActiveVerified() then return Log("WARN", "Output %d: panel not connected", n) end
	if CodeProblem(g.panelCode) then return Log("WARN", "Outputs need 'Panel User Code'") end
	local optype = on and F.OPTYPE.OUTPUT_ON or F.OPTYPE.OUTPUT_OFF
	local req = { kind = "op", desc = string.format("OUTPUT %d %s", n, on and "ON" or "OFF") }
	req.build = function(counter) return F.operation(g.account, counter, g.panelCode, optype, 0, 33 + n) end
	req.onDone = function(ok, reason)
		if not ok then Log("WARN", "%s failed: %s", req.desc, tostring(reason)) end
	end
	QueueRequest(req)
end

---------------------------------------------------------------------------
-- Panel connection (the panel is the TCP client)
---------------------------------------------------------------------------
function StartServer()
	StopServer()
	local port = g.listenPort
	local ok, result, err = pcall(function() return C4:CreateServer(port) end)
	if not ok or result == false then
		SetConnStatus(string.format("Cannot listen on port %d: %s", port, tostring(err or result)))
		return
	end
	g.serverPort = port
	SetConnStatus(string.format("Waiting for the panel to connect on port %d", port))
end

function StopServer()
	if g.active then DropActive("listener restarted") end
	for handle in pairs(g.clients) do pcall(function() C4:ServerCloseClient(handle) end) end
	g.clients = {}
	if g.serverPort then
		pcall(function() C4:DestroyServer(g.serverPort) end)
		g.serverPort = nil
	end
end

function OnServerStatusChanged(nPort, strStatus)
	Log("INFO", "Listener on port %s is %s", tostring(nPort), tostring(strStatus))
end

local function AddressAllowed(address)
	return g.panelIp == "" or address == nil or address == "" or address == g.panelIp
end

function OnServerConnectionStatusChanged(nHandle, nPort, strStatus, strAddress)
	if strStatus == "ONLINE" then
		if not AddressAllowed(strAddress) then
			Log("WARN", "Rejected connection from %s (Panel IP Address is %s)", tostring(strAddress), g.panelIp)
			pcall(function() C4:ServerCloseClient(nHandle) end)
			return
		end
		g.clients[nHandle] = { address = strAddress, buf = "", verified = false }
		Log("INFO", "Connection from %s", tostring(strAddress or "?"))
		if not g.active then SetConnStatus("Panel connected from " .. tostring(strAddress or "?") .. ", waiting for data") end
	else
		g.clients[nHandle] = nil
		if g.active == nHandle then DropActive("connection closed by panel") end
	end
end

-- Forget the active connection; report OFFLINE if the panel does not return
function DropActive(reason)
	g.active = nil
	g.synced, g.syncing = false, false
	FailAllRequests(reason)
	for p in pairs(g.exitDelay) do EndExitDelay(p) end
	Log("WARN", "Panel connection lost: %s", reason)
	SetConnStatus("Panel disconnected (" .. reason .. "), waiting for it to reconnect")
	StartTimer("grace", RECONNECT_GRACE_S * 1000, function()
		if not g.active then GoOffline(reason) end
	end)
end

function CloseActive(reason)
	local handle = g.active
	if not handle then return end
	DropActive(reason)
	g.clients[handle] = nil
	pcall(function() C4:ServerCloseClient(handle) end)
end

function ActivateClient(handle)
	if g.active and g.active ~= handle then
		Log("INFO", "Panel opened a new connection, closing the old one")
		CloseActive("replaced by a new connection")
	end
	local c = g.clients[handle]
	c.verified = true
	g.active = handle
	g.timeouts = 0
	if g.mode ~= "json" then
		if g.mode == "sia" then Log("INFO", "The panel now talks JSON: full control enabled") end
		g.mode = "json"
		PersistData.siaMode, PersistData.siaKeys, PersistData.siaTroubles = nil, nil, nil
		g.siaTroubles = {}
	end
	StopTimer("grace")
	SetOnline()
	SetConnStatus("Connected to " .. tostring(c.address or "panel"))
	UpdatePanelInfo()
	-- The panel replays buffered events first and signals the end with a
	-- null frame; read the status then (or after a delay at the latest)
	StartTimer("syncStart", SYNC_START_DELAY_MS, function() StartSync("connected") end)
end

local FOREIGN_MESSAGES = {
	sia = "Panel is sending Contact-ID/SIA, not JSON: set Protocol = JSON on this CMS path (needs JSON-capable panel firmware)",
	binary = "Unreadable data from the panel: disable encryption on this CMS path and set Protocol = JSON",
}

function OnServerDataIn(nHandle, strData, strAddress)
	local c = g.clients[nHandle]
	if not c then
		if not AddressAllowed(strAddress) then
			pcall(function() C4:ServerCloseClient(nHandle) end)
			return
		end
		c = { address = strAddress, buf = "", verified = false }
		g.clients[nHandle] = c
	end
	if c.verified then g.lastRx = Now() end
	c.buf = c.buf .. strData
	if c.mode == nil and not c.buf:find("{", 1, true) then
		if F.looksLikeSia(c.buf) then
			c.mode = "sia"
		elseif c.buf:find("\n", 1, true) and not c.buf:find("\r", 1, true) and #c.buf < 1024 then
			return -- start of an SIA DC-09 message: wait for the rest
		end
	end
	if c.mode == "sia" then
		if #c.buf > RX_BUFFER_LIMIT then c.buf = "" end
		return HandleSiaData(nHandle, c)
	end
	local frames, rest, residue = F.splitFrames(c.buf)
	c.buf = rest
	if #c.buf > RX_BUFFER_LIMIT then c.buf = "" end
	local foreign = F.classifyForeign(residue)
	if foreign and not c.foreignWarned then
		c.foreignWarned = true
		Log("WARN", "%s", FOREIGN_MESSAGES[foreign])
		SetConnStatus(FOREIGN_MESSAGES[foreign])
	end
	for _, text in ipairs(frames) do
		Log("TRACE", "<<< %s", text)
		local frame, err = F.decode(text)
		if type(frame) == "table" then
			local ok, perr = pcall(HandleFrame, nHandle, c, frame)
			if not ok then Log("ERROR", "Frame handling failed: %s", tostring(perr)) end
		else
			Log("WARN", "Unreadable frame (%s): %s", tostring(err), text:sub(1, 120))
		end
	end
end

local ACKED_TYPES = { EVENT = true, NULL = true, DATA = true }

function HandleFrame(handle, c, f)
	local ftype = F.frameType(f)
	local account = tonumber(f.account)
	local acked = false
	c.account = account

	if not c.verified then
		if ACKED_TYPES[ftype] then
			-- harmless and keeps the panel talking while we wait for a match
			C4:ServerSend(handle, F.ack(account or 0, tonumber(f.counter) or 0))
			acked = true
		end
		if g.account == nil and g.accountText == "" and account then AdoptAccount(tostring(f.account)) end
		if g.account == nil then
			SetConnStatus(string.format("Panel connected with account %s: enter it in 'Account ID'", tostring(f.account)))
			return
		elseif account ~= g.account then
			SetConnStatus(string.format("Account mismatch: panel sent %s, 'Account ID' is %d", tostring(f.account), g.account))
			return
		end
		ActivateClient(handle)
		-- the ACK above went out directly: keep the next write apart from it
		if acked then StartGap(ACK_GAP_MS) end
	end
	if handle ~= g.active then return end
	g.lastRx = Now()

	if ftype == "ACK" then
		local req = g.inFlight
		if req and req.kind ~= "data" and tonumber(f.counter) == req.counter then CompleteRequest(true) end
		return
	elseif ftype == "NAK" then
		local reason = F.decodeText(f.DATA or f.data or f.Data or "rejected")
		SetReadOnlyProperty("Last Panel Error", os.date("%H:%M:%S ") .. reason)
		Log("WARN", "Panel rejected a request: %s", reason)
		local req = g.inFlight
		local counter = tonumber(f.counter)
		if req and (counter == nil or counter == 0 or counter == req.counter) then CompleteRequest(false, reason) end
		return
	end

	-- Everything else is acknowledged first (the first frame of a new
	-- connection was already ACKed above)
	if not acked then QueueAck(f) end

	if ftype == "NULL" then
		if not g.synced and not g.syncing then StartSync("panel ready") end
	elseif ftype == "EVENT" then
		if IsDuplicateEvent(f) then
			Log("TRACE", "Duplicate event ignored")
		else
			HandleEvent(f)
		end
	elseif ftype == "DATA" then
		OnPanelData(f)
	else
		Log("INFO", "Unhandled frame type %s", ftype)
	end
end

function OnPanelData(f)
	local id = tonumber(f.id)
	local start = tonumber(f.start_order) or 1
	local params = f.parameters
	if type(params) ~= "table" then params = (params ~= nil) and { params } or {} end
	local req = g.inFlight
	if req and req.kind == "data" and req.id == id then
		for _, v in ipairs(params) do req.collected[#req.collected + 1] = v end
		local more = string.lower(tostring(f.more or "")) == "yes"
		if more and #params > 0 and req.pages < 50 then
			-- ask for the next page as a new request, ahead of everything else
			req.pages = req.pages + 1
			req.start = start + #params
			g.inFlight = nil
			StopTimer("request")
			table.insert(g.requests, 1, req)
			Pump()
			return
		end
		CompleteRequest(true, { id = id, start = req.firstStart, params = req.collected })
	else
		ProcessData(id, start, params)
	end
end

---------------------------------------------------------------------------
-- Receive-only mode: SIA DC-09 reports (Contact-ID or SIA codes)
--
-- Used when the panel firmware has no JSON option. The panel calls in like
-- it would call a monitoring station, sends one or more reports, waits for an
-- ACK to each and may hang up. Partition state comes only from arm / disarm
-- reports, so it is unknown until the first one (and is kept across driver
-- restarts). Nothing can be sent to the panel besides ACKs.
---------------------------------------------------------------------------
local function NormalizeAccount(s)
	return (tostring(s or ""):upper():gsub("^0+", ""))
end

-- Account ID left empty: take the account from the first panel report and
-- show it in the property (edit the property to lock onto another panel)
function AdoptAccount(acct)
	local text = NormalizeAccount(acct)
	if not text:match("^%x+$") then return false end
	g.accountText = text
	g.account = text:match("^%d+$") and tonumber(text) or nil
	C4:UpdateProperty("Account ID", text)
	Log("INFO", "Account ID set to %s from the panel's first report", text)
	UpdatePanelInfo()
	return true
end

local function Printable(s)
	return (tostring(s):gsub("[%c]", function(ch) return string.format("<%02X>", ch:byte()) end))
end

function HandleSiaData(handle, c)
	local msgs, rest = F.siaSplit(c.buf)
	c.buf = rest
	for _, m in ipairs(msgs) do
		local ok, err = pcall(HandleSiaMessage, handle, c, m)
		if not ok then Log("ERROR", "SIA report handling failed: %s", tostring(err)) end
	end
end

function HandleSiaMessage(handle, c, m)
	if g.siaSamples < SIA_SAMPLE_LOGS then
		g.siaSamples = g.siaSamples + 1
		Log("WARN", "SIA sample %d/%d from %s: %s", g.siaSamples, SIA_SAMPLE_LOGS, tostring(c.address), Printable(m.raw))
	else
		Log("INFO", "SIA <<< %s", Printable(m.raw))
	end
	if m.error then return Log("WARN", "Unreadable SIA report (%s)", m.error) end
	if m.crcOk == false or m.lengthOk == false then
		Log("WARN", "SIA report header check failed (crc %s, length %s), handled anyway",
			tostring(m.crcOk), tostring(m.lengthOk))
	end
	if m.encrypted then
		return SetConnStatus("Panel reports are encrypted: turn encryption off on this CMS path")
	end
	if g.accountText == "" then AdoptAccount(m.acct) end
	if g.accountText == "" then
		return SetConnStatus(string.format("Panel connected (SIA) with account %s: enter it in 'Account ID'", NormalizeAccount(m.acct)))
	end
	if NormalizeAccount(m.acct) ~= NormalizeAccount(g.accountText) then
		return SetConnStatus(string.format("Account mismatch: panel sent %s, 'Account ID' is %s", NormalizeAccount(m.acct), g.accountText))
	end
	-- ACK first: the panel repeats a report until it is acknowledged
	local ack = F.siaAck(m, m.timestamp and os.date("!%H:%M:%S,%m-%d-%Y") or nil)
	Log("TRACE", "SIA >>> %s", Printable(ack))
	C4:ServerSend(handle, ack)
	OnSiaReport(c, m)
end

function OnSiaReport(c, m)
	local t = Now()
	-- a JSON panel connection keeps full control; SIA reports are then extra events
	if g.mode ~= "sia" and not ActiveVerified() then
		Log("INFO", "Receive-only mode: the panel reports with SIA DC-09 (%s)", tostring(m.id))
		g.mode = "sia"
		PersistData.siaMode = true
	end
	local prevRx = g.lastSiaRx
	g.lastSiaRx, g.siaAddress = t, c.address
	local wasOnline = g.online
	SetOnline()

	local events = {}
	if m.id == "NULL" then
		-- link test only
	elseif m.id == "ADM-CID" then
		local e = F.parseAdmCid(m.data)
		if e then events[1] = e else Log("WARN", "Unreadable Contact-ID data: %s", tostring(m.data)) end
	elseif m.id == "SIA-DCS" then
		events = F.parseSiaDcs(m.data)
	else
		Log("WARN", "Unhandled SIA report type %s", tostring(m.id))
	end
	for _, e in ipairs(events) do
		if e.unknown then
			Log("INFO", "SIA code %s (zone %s) not handled", tostring(e.sia), tostring(e.zone))
			SetReadOnlyProperty("Last Event", os.date("%H:%M:%S ") .. "SIA " .. tostring(e.sia) .. " " .. tostring(e.zone))
		else
			-- 6 = "still present" status report, same as a new event here.
			-- Reports are not de-duplicated: a repeated report sets the same state.
			HandleEvent({ type = e.type, qualifier = (e.qualifier == 6) and 1 or e.qualifier,
				zone = e.zone, partition = e.partition })
		end
	end
	-- Supervision interval. The panel sends a link test (NULL) on its own when
	-- idle, and another right after every batch of reports. Only idle ones
	-- count (10 s or more after the previous report), and the interval is the
	-- gap between two idle link tests with nothing else in between.
	local linkTest = m.id == "NULL" or (events[1] ~= nil and events[1].type == 602)
	if linkTest and (prevRx == 0 or t - prevRx >= 10) then
		if prevRx > 0 and g.lastIdleLinkTest == prevRx then g.siaLinkInterval = t - prevRx end
		g.lastIdleLinkTest = t
	end

	if g.mode ~= "sia" then return end
	local keys = {}
	for p, v in pairs(g.systemKey) do keys[p] = v end
	PersistData.siaKeys = keys
	-- back online with nothing new: re-announce the stored state (events already did)
	if not wasOnline and #events == 0 then RefreshPartitions(true) end
	g.initMode = false
	SetConnStatus(string.format("Receive only (SIA DC-09): last report %s from %s", os.date("%H:%M:%S"), tostring(c.address)))
	UpdatePanelInfo()
end

-- Comm trouble when the panel misses its link tests; the last reported
-- state stays (it can only change through a report the panel would repeat)
function SiaSupervision()
	if g.mode ~= "sia" or not g.siaLinkInterval or g.reported.troubles[COMM_TROUBLE_ID] then return end
	local silent = Now() - g.lastSiaRx
	local limit = math.floor(g.siaLinkInterval * SIA_SUPERVISION_FACTOR) + 30
	if silent <= limit then return end
	local text = string.format("No report from the panel for %d min (link test every %d s)",
		math.floor(silent / 60), g.siaLinkInterval)
	Log("WARN", "%s", text)
	g.reported.troubles[COMM_TROUBLE_ID] = text
	Notify(PANEL_BINDING, "TROUBLE_START", { TROUBLE_TEXT = text, IDENTIFIER = COMM_TROUBLE_ID })
	UpdateDiagnostics()
	SetConnStatus(text)
	C4:FireEvent("Communication Lost")
end

---------------------------------------------------------------------------
-- Watchdog and polling
---------------------------------------------------------------------------
function Watchdog()
	local t = Now()
	UpdateControlMarker()
	SiaSupervision()
	if ActiveVerified() then
		if g.linkTimeout > 0 and t - g.lastRx > g.linkTimeout then
			CloseActive(string.format("no data from the panel for %d s", t - g.lastRx))
			return
		end
		if g.synced and not g.syncing and F.isValidCode(g.panelCode) and not g.inFlight and #g.requests == 0 then
			if g.pollInterval > 0 and t - g.lastPoll >= g.pollInterval then PollStatus() end
			if t - g.lastFaultPoll >= FAULT_POLL_S then RequestFaults() end
		end
	end
	for key, seen in pairs(g.recentEvents) do
		if t - seen > DEDUP_WINDOW_S then g.recentEvents[key] = nil end
	end
end

---------------------------------------------------------------------------
-- Proxy commands
---------------------------------------------------------------------------
function SetZoneInfo(t)
	local z = tonumber(Param(t, "ZONE_ID", "ZoneID", "ID"))
	if not z then return end
	if z < 1 or z > g.zoneCount then
		Notify(PANEL_BINDING, "PANEL_REMOVE_ZONE", { ID = z })
		return
	end
	local info = g.zoneInfo[z] or {}
	local name = Param(t, "NAME", "Name")
	if name ~= nil then
		name = Trim(name)
		-- an empty name or the panel's own name means "use the panel name"
		info.name = (name ~= "" and name ~= g.panelNames[z]) and name or nil
	end
	local typeId = Param(t, "TYPE_ID", "TypeID")
	if typeId then
		local key = tostring(typeId):upper():gsub("%s+", "_")
		info.typeId = tonumber(typeId) or ZONE_TYPES[key] or info.typeId
	end
	g.zoneInfo[z] = info
	PersistData.zoneInfo = g.zoneInfo
	SendZoneInfo(z)
	g.reported.display = {}
	RefreshPartitions(false)
end

function PanelCommand(cmd, t)
	if cmd == "GET_PANEL_SETUP" then
		SendAllPartitionsInfo()
		SendAllZonesInfo()
	elseif cmd == "GET_ALL_PARTITION_INFO" then
		SendAllPartitionsInfo()
	elseif cmd == "GET_ALL_ZONE_INFO" then
		SendAllZonesInfo()
	elseif cmd == "READ_PANEL_INFO" then
		AnnounceConfig()
	elseif cmd == "SET_ZONE_INFO" then
		SetZoneInfo(t)
	else
		Log("INFO", "Unsupported panel command %s", cmd)
	end
end

function PartitionCommand(p, cmd, t)
	if cmd == "PARTITION_ARM" then
		ArmPartition(p, t)
	elseif cmd == "PARTITION_DISARM" then
		DisarmPartition(p, t)
	elseif cmd == "ARM_CANCEL" then
		CancelArm(p)
	elseif cmd == "EXECUTE_EMERGENCY" or cmd == "EXECUTE_FUNCTION" or cmd == "KEY_PRESS" then
		ShowMessage(p, "Not supported by the PIMA interface")
	elseif cmd == "GET_STATE" then
		local state, stateType, text, total, remaining = PartitionView(p)
		if state then
			ReportPartition(p, state, stateType, true, total, remaining)
			g.reported.display[p] = nil
			ReportDisplayText(p, text)
		end
	else
		Log("INFO", "Unhandled partition %d command %s", p, cmd)
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	Log("INFO", "<- %d %s %s", idBinding, strCommand, DumpParams(tParams))
	if idBinding == PANEL_BINDING then
		PanelCommand(strCommand, tParams)
	elseif idBinding > PANEL_BINDING and idBinding <= PANEL_BINDING + MAX_PARTITIONS then
		PartitionCommand(idBinding - PANEL_BINDING, strCommand, tParams)
	elseif idBinding > ZONE_BINDING_BASE and idBinding <= ZONE_BINDING_BASE + MAX_ZONES then
		if strCommand == "GET_STATE" then
			local z = idBinding - ZONE_BINDING_BASE
			Notify(idBinding, ZoneOpen(z) and "STATE_OPENED" or "STATE_CLOSED", {})
		end
	end
end

---------------------------------------------------------------------------
-- Actions and programming commands
---------------------------------------------------------------------------
function PrintStatus()
	local lines = {
		"---- PIMA FORCE status ----",
		"Connection: " .. tostring(g.connStatus),
		"Protocol: " .. (g.mode == "sia" and "SIA DC-09, receive only" .. (g.siaLinkInterval and
			string.format(" (link test every %d s)", g.siaLinkInterval) or "") or tostring(g.mode or "unknown")),
		string.format("Online: %s, synced: %s, last data: %s", tostring(g.online), tostring(g.synced),
			g.lastRx > 0 and ((Now() - g.lastRx) .. " s ago") or "never"),
		"Panel: " .. tostring(propertyCache["Panel Info"]),
	}
	for p = 1, g.partitionCount do
		local state, stateType, text = PartitionView(p)
		lines[#lines + 1] = string.format("Partition %d: key=%s %s %s - %s", p, tostring(g.systemKey[p]),
			tostring(state), tostring(stateType), tostring(text))
	end
	for z = 1, g.zoneCount do
		local flags = {}
		if ZoneOpen(z) then flags[#flags + 1] = "open" end
		if ZoneBypassed(z) then flags[#flags + 1] = "bypassed" end
		if ZoneAlarmed(z) then flags[#flags + 1] = "ALARM" end
		lines[#lines + 1] = string.format("  Zone %d %s: %s", z, ZoneName(z), #flags > 0 and table.concat(flags, ", ") or "closed")
	end
	lines[#lines + 1] = "Troubles: " .. tostring(propertyCache["Active Troubles"])
	lines[#lines + 1] = "Sirens: " .. tostring(propertyCache["Sirens"])
	lines[#lines + 1] = string.format("Queue: %d request(s)%s", #g.requests, g.inFlight and (", waiting for " .. g.inFlight.desc) or "")
	print(table.concat(lines, "\n"))
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	if strCommand == "LUA_ACTION" then
		local action = tParams.ACTION
		if action == "ReadPanel" then
			g.syncing = false
			StartSync("manual")
		elseif action == "Resync" then
			AnnounceConfig()
		elseif action == "PrintStatus" then
			PrintStatus()
		end
	elseif strCommand == "Bypass Zone" then
		SetZoneBypass(tonumber(tParams.Zone), true)
	elseif strCommand == "Unbypass Zone" then
		SetZoneBypass(tonumber(tParams.Zone), false)
	elseif strCommand == "Activate Output" then
		SetOutput(tonumber(tParams.Output), true)
	elseif strCommand == "Deactivate Output" then
		SetOutput(tonumber(tParams.Output), false)
	end
end

---------------------------------------------------------------------------
-- Properties
---------------------------------------------------------------------------
PROPERTY_HANDLERS = {}

PROPERTY_HANDLERS["Listen Port"] = function(value)
	local port = tonumber(value) or 7780
	if port ~= g.listenPort or not g.serverPort then
		g.listenPort = port
		g.dirty.server = true
	end
end

PROPERTY_HANDLERS["Account ID"] = function(value)
	local text = Trim(value)
	g.account = text:match("^%d+$") and tonumber(text) or nil
	g.accountText = text:match("^%x+$") and text or ""
	if text ~= "" and g.accountText == "" then Log("WARN", "Account ID must be digits") end
	-- re-admit a connection that is already waiting with this account
	if g.account and not g.active and not g.initializing then
		for handle, c in pairs(g.clients) do
			if c.account == g.account then
				ActivateClient(handle)
				break
			end
		end
	end
	UpdatePanelInfo()
end

PROPERTY_HANDLERS["Panel IP Address"] = function(value)
	g.panelIp = Trim(value)
end

PROPERTY_HANDLERS["Panel User Code"] = function(value)
	g.panelCode = Trim(value)
	if g.panelCode ~= "" and not F.isValidCode(g.panelCode) then
		Log("WARN", "Panel User Code must be 4-6 digits")
	end
	if not g.initializing and ActiveVerified() and F.isValidCode(g.panelCode) then
		g.syncing = false
		StartSync("code changed")
	end
end

PROPERTY_HANDLERS["Require Code To Arm"] = function(value)
	g.requireArmCode = (value == "Yes")
	if not g.initializing then SendCodeRequired() end
end

PROPERTY_HANDLERS["Partitions In Use"] = function(value)
	g.partitionCount = math.max(1, math.min(tonumber(value) or 1, MAX_PARTITIONS))
	for p = 1, MAX_PARTITIONS do
		C4:SetPropertyAttribs("Partition " .. p .. " Zones", p <= g.partitionCount and 0 or 1)
	end
	g.dirty.announce = true
end

for p = 1, MAX_PARTITIONS do
	PROPERTY_HANDLERS["Partition " .. p .. " Zones"] = function(value)
		local set, bad = {}, {}
		local text = Trim(value)
		if text:lower() == "all" or text == "*" then
			for z = 1, MAX_ZONES do set[z] = true end
		else
			for token in text:gmatch("[^,;%s]+") do
				local a, b = token:match("^(%d+)%-(%d+)$")
				if a then
					a, b = tonumber(a), tonumber(b)
					for z = math.max(1, math.min(a, b)), math.min(MAX_ZONES, math.max(a, b)) do set[z] = true end
				elseif token:match("^%d+$") and tonumber(token) >= 1 and tonumber(token) <= MAX_ZONES then
					set[tonumber(token)] = true
				else
					bad[#bad + 1] = token
				end
			end
		end
		if #bad > 0 then Log("WARN", "Partition %d Zones: ignored '%s'", p, table.concat(bad, ", ")) end
		g.partitionZones[p] = set
		g.dirty.announce = true
	end
end

PROPERTY_HANDLERS["Zone Count"] = function(value)
	g.zoneCountOverride = math.max(0, math.min(tonumber(value) or 0, MAX_ZONES))
	ApplyZoneCount()
end

PROPERTY_HANDLERS["Reverse Zone Names"] = function(value)
	g.reverseNames = (value == "Yes")
	if g.reverseNames ~= (PersistData.namesReversed == true) then
		-- names stored from the panel were decoded with the other setting
		for z, name in pairs(g.panelNames) do g.panelNames[z] = F.utf8Reverse(name) end
		PersistData.panelNames = g.panelNames
		PersistData.namesReversed = g.reverseNames
		g.dirty.announce = true
	end
end

PROPERTY_HANDLERS["Allow Zone Bypass"] = function(value)
	g.allowBypass = (value ~= "No")
end

PROPERTY_HANDLERS["Status Poll Interval (s)"] = function(value)
	g.pollInterval = math.max(0, tonumber(value) or 60)
end

PROPERTY_HANDLERS["Link Timeout (s)"] = function(value)
	g.linkTimeout = math.max(0, tonumber(value) or 300)
end

PROPERTY_HANDLERS["Debug Mode"] = function(value)
	if value ~= "Off" then
		print("PIMA: debug mode " .. tostring(value) .. " (switches off automatically after 4 hours)")
		StartTimer("debugOff", DEBUG_AUTO_OFF_MS, function() C4:UpdateProperty("Debug Mode", "Off") end)
	else
		StopTimer("debugOff")
	end
end

function FlushDirty()
	if g.dirty.announce then
		g.dirty.announce = false
		AnnounceConfig()
	end
	if g.dirty.server then
		g.dirty.server = false
		StartServer()
	end
end

function OnPropertyChanged(strProperty)
	local handler = PROPERTY_HANDLERS[strProperty]
	if not handler then return end
	local ok, err = pcall(handler, Properties[strProperty])
	if not ok then Log("ERROR", "Property '%s' failed: %s", strProperty, tostring(err)) end
	if not g.initializing then FlushDirty() end
end

---------------------------------------------------------------------------
-- Driver lifecycle
---------------------------------------------------------------------------
local function LoadNumberKeyed(t)
	local out = {}
	if type(t) == "table" then
		for k, v in pairs(t) do
			local n = tonumber(k)
			if n then out[n] = v end
		end
	end
	return out
end

function OnDriverInit(dit)
	if type(PersistData) ~= "table" then PersistData = {} end
	g.zoneInfo = LoadNumberKeyed(PersistData.zoneInfo)
	g.panelNames = LoadNumberKeyed(PersistData.panelNames)
	PersistData.zoneInfo = g.zoneInfo
	PersistData.panelNames = g.panelNames
	if PersistData.siaMode then
		-- receive only: the last reported state is all there is
		g.mode = "sia"
		g.systemKey = LoadNumberKeyed(PersistData.siaKeys)
		g.siaTroubles = LoadNumberKeyed(PersistData.siaTroubles)
	end
	AddAgreementVariables()
	pcall(function() C4:PersistDeleteValue(OLD_SECRET_STORE) end)
end

function OnDriverLateInit(dit)
	SetReadOnlyProperty("Driver Version", DriverVersion())
	WriteAgreementVariables()
	g.initializing = true
	for _, name in ipairs(PROPERTY_ORDER) do OnPropertyChanged(name) end
	ApplyZoneCount()
	g.initializing = false
	g.dirty = {}
	AnnounceConfig()
	if g.mode == "sia" and next(g.siaTroubles) then ReportTroubles(g.siaTroubles) end
	UpdatePanelInfo()
	StartTimer("watchdog", WATCHDOG_MS, Watchdog, true)
	StartServer()
end

function OnDriverDestroyed(dit)
	for key in pairs(g.timers) do StopTimer(key) end
	StopServer()
end

-- Dynamic bindings must be restored when the script loads (DriverWorks docs);
-- Composer connections to them are then restored automatically.
if type(PersistData) == "table" then
	for z = 1, tonumber(PersistData.zoneBindings) or 0 do
		C4:AddDynamicBinding(ZoneBinding(z), "CONTROL", true, "Zone " .. z, "CONTACT_SENSOR", false, false)
	end
end
