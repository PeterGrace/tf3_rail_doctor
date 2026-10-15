-- Pure route search (no api.* calls), so tests/route_test.lua can run it in plain Lua.
-- States are opaque string keys; each step costs 0 or more (Rail Doctor: 1 per signal passed the wrong way).
global record PgraceRailDoctorRoute
	record Step
		key : string
		cost : integer
	end

	record Result
		found : boolean
		-- total cost of the route found (the fewest possible)
		cost : integer
		-- the states from a start to the goal, both included
		keys : {string}
		-- states taken off the queue (the search gives up after maxExpanded)
		expanded : integer
	end

	-- Cheapest route from any start to a state where isGoal is true. Ties go to the fewest steps.
	search : function(starts : {Step}, isGoal : function(key : string) : boolean, next : function(key : string) : {Step}, maxExpanded : integer) : Result
end
