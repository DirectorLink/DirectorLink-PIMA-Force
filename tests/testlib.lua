-- Minimal test helper for stock Lua 5.1 (no external dependencies)
local T = { passed = 0, failed = 0, current = "" }

-- io.write, not print: the Control4 mock captures print() output
local function out(s) io.write(s, "\n") end
T.out = out

local function fmt(v)
	if type(v) == "string" then return string.format("%q", v) end
	return tostring(v)
end

function T.test(name, fn)
	T.current = name
	local ok, err = pcall(fn)
	if ok then
		T.passed = T.passed + 1
		out("  ok   " .. name)
	else
		T.failed = T.failed + 1
		out("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

function T.eq(actual, expected, msg)
	if actual ~= expected then
		error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

function T.truthy(v, msg)
	if not v then error(msg or "expected truthy value", 2) end
end

function T.done()
	out(string.format("\n%d passed, %d failed", T.passed, T.failed))
	if T.failed > 0 then os.exit(1) end
end

return T
