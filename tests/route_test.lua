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
