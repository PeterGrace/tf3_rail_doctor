-- Pure terminal-suggestion logic (no api.* calls), so tests/suggest_test.lua can run it in plain Lua.
-- Stops and candidates are 1-based; leg i runs from stop i to stop i % #stops + 1.
global record PgraceRailDoctorSuggest
	record Stop
		-- the candidate (terminal) the line uses now
		current : integer
		-- how many candidates the stop has
		count : integer
	end

	record Change
		stop : integer
		candidate : integer
	end

	record Fix
		leg : integer
		-- whether some terminals make this leg work
		found : boolean
		-- an earlier fix in the list already made this leg work
		alreadyFixed : boolean
		-- the stops to move, in stop order; empty when nothing was found or nothing was needed
		changes : {Change}
	end

	-- For each broken leg, in order: the fewest terminal changes that give it a path without breaking a leg that
	-- works. Each accepted change carries into the legs after it. reach is asked each (leg, from, to) at most once.
	solve : function(stops : {Stop}, broken : {integer}, reach : function(leg : integer, from : integer, to : integer) : boolean) : {Fix}
end
