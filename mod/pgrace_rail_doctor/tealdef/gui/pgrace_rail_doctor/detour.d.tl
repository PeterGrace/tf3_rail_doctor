-- Pure detour logic (no api.* calls), so tests/detour_test.lua can run it in plain Lua.
-- Stops and terminals are 1-based; leg i runs from stop i to stop i % #counts + 1.
global record PgraceRailDoctorDetour
	-- The terminals (one per stop, an index up to counts[i]) that make the whole line shortest, and its length.
	-- dist(leg, a, b) is the leg's length from terminal a to terminal b, or nil if there's no route.
	-- Returns nil and math.huge when no assignment connects every leg.
	best : function(counts : {integer}, dist : function(leg : integer, a : integer, b : integer) : number) : {integer}, number

	-- Whether a leg of this length, against its best, is a detour worth reporting: at least 25% and 500 m longer.
	isDetour : function(actual : number, best : number) : boolean

	record Point
		x : number
		y : number
	end

	-- The index of the point on route that lies furthest from all of other (on the map, ignoring height): where a long
	-- way round strays furthest from the short way. nil when either list is empty.
	farthest : function(route : {Point}, other : {Point}) : integer
end
