local t = ...
local route = t.requireTl("gui/pgrace_rail_doctor/route.tl")

-- graph: { a = { {"b", 0}, {"c", 1} }, ... }
local function graph(g)
	return function(key)
		local out = {}
		for _, e in ipairs(g[key] or {}) do out[#out + 1] = { key = e[1], cost = e[2] } end
		return out
	end
end

local function is(goal) return function(k) return k == goal end end

t.test("search: finds a free route", function()
	local r = route.search({ { key = "a", cost = 0 } }, is("c"), graph({ a = { { "b", 0 } }, b = { { "c", 0 } } }), 100)
	t.eq(r.found, true)
	t.eq(r.cost, 0)
	t.eq(table.concat(r.keys, ","), "a,b,c")
end)

t.test("search: prefers a longer free route to a short costly one", function()
	local g = graph({ a = { { "c", 1 }, { "b", 0 } }, b = { { "d", 0 } }, d = { { "c", 0 } } })
	local r = route.search({ { key = "a", cost = 0 } }, is("c"), g, 100)
	t.eq(r.cost, 0)
	t.eq(table.concat(r.keys, ","), "a,b,d,c")
end)

t.test("search: takes the fewest costly steps when it must", function()
	local g = graph({ a = { { "b", 1 }, { "x", 1 } }, b = { { "c", 0 } }, x = { { "y", 1 } }, y = { { "c", 0 } } })
	local r = route.search({ { key = "a", cost = 0 } }, is("c"), g, 100)
	t.eq(r.cost, 1)
	t.eq(table.concat(r.keys, ","), "a,b,c")
end)

t.test("search: start costs count", function()
	local g = graph({ s1 = { { "c", 0 } }, s2 = { { "c", 0 } } })
	local r = route.search({ { key = "s1", cost = 1 }, { key = "s2", cost = 0 } }, is("c"), g, 100)
	t.eq(r.cost, 0)
	t.eq(r.keys[1], "s2")
end)

t.test("search: no route", function()
	local r = route.search({ { key = "a", cost = 0 } }, is("z"), graph({ a = { { "b", 0 } }, b = { { "a", 0 } } }), 100)
	t.eq(r.found, false)
	t.eq(#r.keys, 0)
end)

t.test("search: gives up after maxExpanded", function()
	-- an endless chain
	local r = route.search({ { key = "0", cost = 0 } }, is("never"), function(k)
		return { { key = tostring(tonumber(k) + 1), cost = 0 } }
	end, 50)
	t.eq(r.found, false)
	t.eq(r.expanded, 50)
end)

t.test("search: the start can be the goal", function()
	local r = route.search({ { key = "a", cost = 0 } }, is("a"), graph({}), 100)
	t.eq(r.found, true)
	t.eq(table.concat(r.keys, ","), "a")
end)

-- weighted graph: { a = { {"b", 10}, ... } }
local function wgraph(g)
	return function(key)
		local out = {}
		for _, e in ipairs(g[key] or {}) do out[#out + 1] = { key = e[1], length = e[2] } end
		return out
	end
end

local function goals(map) return function(k) return map[k] end end

t.test("shortest: finds the shortest length to each goal", function()
	local g = wgraph({ a = { { "b", 5 }, { "c", 1 } }, c = { { "b", 1 }, { "d", 10 } }, b = { { "d", 2 } } })
	local r = route.shortest({ { key = "a", length = 0 } }, goals({ b = "B", d = "D" }), 2, g, 100)
	t.eq(r.found.B, 2)
	t.eq(r.found.D, 4)
end)

t.test("shortest: several states can be the same goal; the nearest counts", function()
	local g = wgraph({ a = { { "x1", 7 }, { "x2", 3 } } })
	local r = route.shortest({ { key = "a", length = 0 } }, goals({ x1 = "X", x2 = "X" }), 1, g, 100)
	t.eq(r.found.X, 3)
end)

t.test("shortest: start lengths count, and unreachable goals are missing", function()
	local g = wgraph({ s1 = { { "g", 1 } }, s2 = { { "g", 1 } } })
	local r = route.shortest({ { key = "s1", length = 10 }, { key = "s2", length = 2 } }, goals({ g = "G", z = "Z" }), 2, g, 100)
	t.eq(r.found.G, 3)
	t.eq(r.found.Z, nil)
end)

t.test("shortest: stops once every goal is found", function()
	local r = route.shortest({ { key = "0", length = 0 } }, goals({ ["3"] = "G" }), 1, function(k)
		return { { key = tostring(tonumber(k) + 1), length = 1 } }
	end, 1000)
	t.eq(r.found.G, 3)
	t.eq(r.expanded <= 4, true)
end)

t.test("shortest: gives up after maxExpanded", function()
	local r = route.shortest({ { key = "0", length = 0 } }, goals({}), 1, function(k)
		return { { key = tostring(tonumber(k) + 1), length = 1 } }
	end, 30)
	t.eq(r.expanded, 30)
end)

t.test("shortest: gives the path to each goal, start to goal", function()
	local g = wgraph({ a = { { "b", 5 }, { "c", 1 } }, c = { { "b", 1 }, { "d", 10 } }, b = { { "d", 2 } } })
	local r = route.shortest({ { key = "a", length = 0 } }, goals({ b = "B", d = "D" }), 2, g, 100)
	t.eq(table.concat(r.paths.B, ","), "a,c,b")
	t.eq(table.concat(r.paths.D, ","), "a,c,b,d")
end)

t.test("shortest: a start that is a goal has a one-state path", function()
	local r = route.shortest({ { key = "a", length = 0 } }, goals({ a = "A" }), 1, wgraph({}), 100)
	t.eq(table.concat(r.paths.A, ","), "a")
end)
