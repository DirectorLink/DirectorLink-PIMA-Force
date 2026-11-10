-- Minimal Control4 DriverWorks runtime for offline tests (stock Lua 5.1).
-- Loads src/driver.lua with Properties defaulted from src/driver.xml and
-- records everything the driver sends. Time is simulated: os.time() and
-- C4:SetTimer() only move when the test calls M.advance().
local M = {}

M.nowMs = 1000000000
M.timers = {}
M.proxy = {}        -- { binding, cmd, params }
M.sent = {}         -- { handle, data } sent to the panel
M.events = {}       -- fired driver events
M.bindings = {}     -- dynamic bindings [id] = name
M.closed = {}       -- closed server client handles
M.output = {}       -- print / DebugLog / ErrorLog lines
M.listening = nil
M.partitionState = {} -- last PARTITION_STATE(_INIT) per binding, survives clearProxy()
M.vars = {}         -- driver variables [name] = value
M.varOrder = {}     -- names in the order they were added
M.varWrites = {}    -- names, in the order they were written

local realTime = os.time
os.time = function(t)
	if t then return realTime(t) end
	return math.floor(M.nowMs / 1000)
end

print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	table.insert(M.output, table.concat(parts, " "))
	if os.getenv("VERBOSE") then io.write(table.concat(parts, " "), "\n") end
end

C4 = {}
function C4:SendToProxy(binding, cmd, params)
	local m = { binding = binding, cmd = cmd, params = params }
	table.insert(M.proxy, m)
	if cmd == "PARTITION_STATE" or cmd == "PARTITION_STATE_INIT" then M.partitionState[binding] = m end
end
function C4:UpdateProperty(name, value) Properties[name] = value end
function C4:SetPropertyAttribs() end
function C4:DebugLog(s) table.insert(M.output, s) end
function C4:ErrorLog(s) table.insert(M.output, s) end
function C4:FireEvent(name) table.insert(M.events, name) end
-- Like Director: a variable added again keeps its place; only added ones can be set
function C4:AddVariable(name, value, kind, readonly, hidden)
	if M.vars[name] == nil then table.insert(M.varOrder, name) end
	M.vars[name] = tostring(value)
	return true
end
function C4:SetVariable(name, value)
	assert(M.vars[name] ~= nil, "SetVariable before AddVariable: " .. tostring(name))
	M.vars[name] = tostring(value)
	table.insert(M.varWrites, name)
end
function C4:AddDynamicBinding(id, kind, provider, name) M.bindings[id] = name end
function C4:RemoveDynamicBinding(id) M.bindings[id] = nil end
function C4:GetDriverConfigInfo() return "1" end
function C4:CreateServer(port) M.listening = port return true end
function C4:DestroyServer() M.listening = nil end
function C4:ServerSend(handle, data) table.insert(M.sent, { handle = handle, data = data, at = M.nowMs }) end
function C4:ServerCloseClient(handle) table.insert(M.closed, handle) end
function C4:SetTimer(ms, fn, repeating)
	-- like the real controller: "repeat should be a boolean"
	assert(type(repeating) == "boolean", "repeat should be a boolean")
	local t ={ due = M.nowMs + ms, ms = ms, fn = fn, repeating = repeating }
	function t:Cancel() self.cancelled = true end
	table.insert(M.timers, t)
	return t
end

-- Runs due timers in order while moving the clock forward by ms
function M.advance(ms)
	local target = M.nowMs + ms
	while true do
		local nextTimer
		for _, t in ipairs(M.timers) do
			if not t.cancelled and t.due <= target and (not nextTimer or t.due < nextTimer.due) then nextTimer = t end
		end
		if not nextTimer then break end
		M.nowMs = nextTimer.due
		if nextTimer.repeating then nextTimer.due = nextTimer.due + nextTimer.ms else nextTimer.cancelled = true end
		nextTimer.fn(nextTimer, 0)
	end
	M.nowMs = target
	local live = {}
	for _, t in ipairs(M.timers) do
		if not t.cancelled then live[#live + 1] = t end
	end
	M.timers = live
end

-- Property defaults straight from driver.xml, so names must match the Lua
function M.loadPropertyDefaults(path)
	local xml = io.open(path):read("*a")
	local props = {}
	for block in xml:gmatch("<property>(.-)</property>") do
		local name = block:match("<name>(.-)</name>")
		props[name] = block:match("<default>(.-)</default>") or ""
	end
	return props
end

-- persist: PersistData left by a previous driver instance (simulates a restart)
function M.load(overrides, persist)
	package.path = "src/?.lua;tests/?.lua;" .. package.path
	Properties = M.loadPropertyDefaults("src/driver.xml")
	for k, v in pairs(overrides or {}) do Properties[k] = v end
	for _, t in ipairs(M.timers) do t.cancelled = true end
	M.timers = {}
	M.vars, M.varOrder, M.varWrites = {}, {}, {}
	PersistData = persist or {}
	dofile(os.getenv("DRIVER_LUA") or "src/driver.lua")
	OnDriverInit("DIT_ADDING")
	OnDriverLateInit("DIT_ADDING")
end

function M.setProperty(name, value)
	Properties[name] = value
	OnPropertyChanged(name)
end

-- Proxy notifications helpers
function M.clearProxy() M.proxy = {} end

function M.findProxy(binding, cmd, match)
	for _, m in ipairs(M.proxy) do
		if m.binding == binding and m.cmd == cmd then
			local ok = true
			for k, v in pairs(match or {}) do
				if type(m.params) ~= "table" or m.params[k] ~= v then ok = false end
			end
			if ok then return m end
		end
	end
	return nil
end

function M.lastProxy(binding, cmd)
	for i = #M.proxy, 1, -1 do
		local m = M.proxy[i]
		if m.binding == binding and (cmd == nil or m.cmd == cmd) then return m end
	end
	return nil
end

function M.allOutput() return table.concat(M.output, "\n") end

return M
