local detour : PgraceRailDoctorDetour = {}

local MIN_EXTRA_FRACTION = 0.25
local MIN_EXTRA_METRES = 500

-- Fix the first stop's terminal, then the shortest way to each terminal of each following stop, closing the loop
-- back to the first stop; the best over every first terminal wins.
function detour.best(counts : {integer}, dist : function(integer, integer, integer) : number) : {integer}, number
	local n = #counts
	local bestTotal = math.huge
	local bestAssignment : {integer} = nil
	for first = 1, counts[1] do
		local cost : {{number}} = { {} }
		local from : {{integer}} = { {} }
		for t = 1, counts[1] do
			cost[1][t] = t == first and 0 or math.huge
		end
		for j = 2, n do
			cost[j], from[j] = {}, {}
			for t = 1, counts[j] do
				cost[j][t] = math.huge
				for s = 1, counts[j - 1] do
					local d = cost[j - 1][s] < math.huge and dist(j - 1, s, t) or nil
					if d ~= nil and cost[j - 1][s] + d < cost[j][t] then
						cost[j][t], from[j][t] = cost[j - 1][s] + d, s
					end
				end
			end
		end
		for t = 1, counts[n] do
			local back = cost[n][t] < math.huge and dist(n, t, first) or nil
			if back ~= nil and cost[n][t] + back < bestTotal then
				bestTotal = cost[n][t] + back
				local assignment : {integer} = {}
				assignment[n] = t
				for j = n, 2, -1 do
					assignment[j - 1] = from[j][assignment[j]] or first
				end
				assignment[1] = first
				bestAssignment = assignment
			end
		end
	end
	return bestAssignment, bestTotal
end

function detour.isDetour(actual : number, best : number) : boolean
	if actual == nil or best == nil then
		return false
	end
	return actual >= best * (1 + MIN_EXTRA_FRACTION) and actual - best >= MIN_EXTRA_METRES
end

function detour.farthest(route : {PgraceRailDoctorDetour.Point}, other : {PgraceRailDoctorDetour.Point}) : integer
	if #other == 0 then
		return nil
	end
	local bestIndex : integer = nil
	local bestDist = -1.0
	for i, p in ipairs(route) do
		local nearest = math.huge
		for __, q in ipairs(other) do
			local dx, dy = p.x - q.x, p.y - q.y
			local d = dx * dx + dy * dy
			if d < nearest then
				nearest = d
			end
		end
		if nearest > bestDist then
			bestDist = nearest
			bestIndex = i
		end
	end
	return bestIndex
end

return detour
