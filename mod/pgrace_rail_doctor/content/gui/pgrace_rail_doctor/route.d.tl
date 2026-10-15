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

	record Weighted
		key : string
		length : number
	end

	record Distances
		-- goal id -> the shortest length to any state of that goal; unreachable goals are missing
		found : {string : number}
		-- goal id -> the states from a start to that goal, both included
		paths : {string : {string}}
		expanded : integer
	end

	-- Shortest lengths (Dijkstra) from the starts to every goal: goalOf names the goal a state belongs to, or nil.
	-- Stops once goalCount goals are found, or after maxExpanded states.
	shortest : function(starts : {Weighted}, goalOf : function(key : string) : string, goalCount : integer, next : function(key : string) : {Weighted}, maxExpanded : integer) : Distances
end
