local t = ...
local detour = t.requireTl("gui/pgrace_rail_doctor/detour.tl")

-- dist from a table { ["leg:a>b"] = length }
local function distOf(map)
	return function(leg, a, b) return map[leg .. ":" .. a .. ">" .. b] end
end

t.test("best: picks the terminals with the shortest total", function()
	-- 2 stops, 2 terminals each; going 1>2 on (1,1) is short, but 2>1 back from 1 is long
	local d = distOf({ ["1:1>1"] = 1, ["2:1>1"] = 10, ["1:2>2"] = 2, ["2:2>2"] = 2, ["1:1>2"] = 5, ["2:2>1"] = 5,
		["1:2>1"] = 9, ["2:1>2"] = 9 })
	local a, total = detour.best({ 2, 2 }, d)
	t.eq(a[1] .. "," .. a[2], "2,2")
	t.eq(total, 4)
end)

t.test("best: unreachable pairs are skipped", function()
	local d = distOf({ ["1:1>2"] = 3, ["2:2>1"] = 3, ["3:1>1"] = 1 })
	local a, total = detour.best({ 1, 2 }, function(leg, x, y) return d(leg, x, y) end)
	t.eq(a[2], 2)
	t.eq(total, 6)
end)

t.test("best: a loop of three", function()
	local m = {}
	for leg = 1, 3 do
		for a = 1, 2 do
			for b = 1, 2 do m[leg .. ":" .. a .. ">" .. b] = 10 end
		end
	end
	-- terminal 2 everywhere is much shorter
	m["1:2>2"], m["2:2>2"], m["3:2>2"] = 1, 1, 1
	local a, total = detour.best({ 2, 2, 2 }, distOf(m))
	t.eq(a[1] .. a[2] .. a[3], "222")
	t.eq(total, 3)
end)

t.test("best: nothing reachable", function()
	local a, total = detour.best({ 1, 1 }, distOf({}))
	t.eq(a, nil)
	t.eq(total, math.huge)
end)

t.test("isDetour: needs both 25% and 500 m longer", function()
	t.eq(detour.isDetour(3100, 1400), true)
	t.eq(detour.isDetour(1700, 1400), false)   -- 21% longer
	t.eq(detour.isDetour(1000, 600), false)    -- 67% but only 400 m
	t.eq(detour.isDetour(1200, 600), true)
	t.eq(detour.isDetour(nil, 600), false)
	t.eq(detour.isDetour(1200, nil), false)
end)

local function pts(list)
	local out = {}
	for _, p in ipairs(list) do out[#out + 1] = { x = p[1], y = p[2] } end
	return out
end

t.test("farthest: the route point furthest from every other point", function()
	-- the long way runs out to (0, 900) and back; the short way stays on the x axis
	local long = pts({ { 0, 0 }, { 0, 500 }, { 0, 900 }, { 300, 400 }, { 600, 0 } })
	local short = pts({ { 0, 0 }, { 300, 0 }, { 600, 0 } })
	t.eq(detour.farthest(long, short), 3)
end)

t.test("farthest: nil without points", function()
	t.eq(detour.farthest({}, pts({ { 0, 0 } })), nil)
	t.eq(detour.farthest(pts({ { 0, 0 } }), {}), nil)
end)
