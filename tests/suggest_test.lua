local t = ...
local suggest = t.requireTl("gui/pgrace_rail_doctor/suggest.tl")

-- reach from a set of "leg:from>to" strings that work
local function reachOf(works)
	local set = {}
	for _, k in ipairs(works) do set[k] = true end
	local calls = 0
	local fn = function(leg, from, to)
		calls = calls + 1
		return set[leg .. ":" .. from .. ">" .. to] == true
	end
	return fn, function() return calls end
end

local function stops(...)
	local out = {}
	for _, c in ipairs({ ... }) do out[#out + 1] = { current = 1, count = c } end
	return out
end

local function changesText(fix)
	local parts = {}
	for _, c in ipairs(fix.changes) do parts[#parts + 1] = c.stop .. "=" .. c.candidate end
	return table.concat(parts, ",")
end

t.test("solve: changes the destination when that is enough", function()
	-- 3 stops in a loop; leg 1 (1->2) works only into stop 2's terminal 2, and 2->3 works from there too
	local reach = reachOf({ "1:1>2", "2:2>1", "2:1>1", "3:1>1" })
	local fixes = suggest.solve(stops(2, 2, 2), { 1 }, reach)
	t.eq(#fixes, 1)
	t.eq(fixes[1].leg, 1)
	t.eq(fixes[1].found, true)
	t.eq(changesText(fixes[1]), "2=2")
end)

t.test("solve: keeps a working neighbour leg working", function()
	-- moving stop 2 to terminal 2 would break leg 2, so the origin (stop 1) has to move instead
	local reach = reachOf({ "1:1>2", "1:2>1", "2:1>1", "3:1>1", "3:1>2" })
	local fixes = suggest.solve(stops(2, 2, 2), { 1 }, reach)
	t.eq(fixes[1].found, true)
	t.eq(changesText(fixes[1]), "1=2")
end)

t.test("solve: changes both ends when no single change works", function()
	local reach = reachOf({ "1:2>2", "2:2>1", "3:1>2" })
	local fixes = suggest.solve(stops(2, 2, 2), { 1 }, reach)
	t.eq(fixes[1].found, true)
	t.eq(changesText(fixes[1]), "1=2,2=2")
end)

t.test("solve: reports a leg nothing fixes", function()
	local reach = reachOf({ "2:1>1", "3:1>1" })
	local fixes = suggest.solve(stops(3, 3, 3), { 1 }, reach)
	t.eq(fixes[1].found, false)
	t.eq(#fixes[1].changes, 0)
end)

t.test("solve: a later leg can be fixed by an earlier change", function()
	-- legs 1 and 2 both broken; moving stop 2 to terminal 2 fixes both
	local reach = reachOf({ "1:1>2", "2:2>1", "3:1>1" })
	local fixes = suggest.solve(stops(2, 2, 2), { 1, 2 }, reach)
	t.eq(changesText(fixes[1]), "2=2")
	t.eq(fixes[2].found, true)
	t.eq(fixes[2].alreadyFixed, true)
	t.eq(#fixes[2].changes, 0)
end)

t.test("solve: a broken neighbour doesn't block a change", function()
	-- legs 1 and 2 broken; stop 2 terminal 2 fixes leg 1 only, leg 2 then needs stop 3 moved
	local reach = reachOf({ "1:1>2", "2:2>2", "3:2>1" })
	local fixes = suggest.solve(stops(2, 2, 2), { 1, 2 }, reach)
	t.eq(changesText(fixes[1]), "2=2")
	t.eq(changesText(fixes[2]), "3=2")
end)

t.test("solve: two-stop line", function()
	-- leg 1 = 1->2, leg 2 = 2->1; leg 2 works now and must keep working
	local reach = reachOf({ "2:1>1", "1:1>2", "2:2>1" })
	local fixes = suggest.solve(stops(2, 2), { 1 }, reach)
	t.eq(changesText(fixes[1]), "2=2")
end)

t.test("solve: asks each pair once", function()
	local reach, calls = reachOf({})
	suggest.solve(stops(3, 3, 3), { 1, 2, 3 }, reach)
	t.eq(calls() <= 3 * 9, true, "at most every pair of every leg")
end)

t.test("solve: no broken legs, no fixes", function()
	local reach = reachOf({})
	t.eq(#suggest.solve(stops(2, 2), {}, reach), 0)
end)
