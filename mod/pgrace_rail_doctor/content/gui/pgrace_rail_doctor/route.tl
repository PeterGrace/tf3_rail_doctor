local route : PgraceRailDoctorRoute = {}

-- Dijkstra with a bucket per cost (costs are small whole numbers), first in first out inside a bucket.
function route.search(starts : {PgraceRailDoctorRoute.Step}, isGoal : function(string) : boolean, next : function(string) : {PgraceRailDoctorRoute.Step}, maxExpanded : integer) : PgraceRailDoctorRoute.Result
	local best : {string : integer} = {}
	local parent : {string : string} = {}
	local buckets : {integer : {string}} = {}
	local heads : {integer : integer} = {}
	local lowest, highest = math.huge as integer, -1

	local function push(key : string, cost : integer, from : string)
		if best[key] ~= nil and best[key] <= cost then
			return
		end
		best[key] = cost
		parent[key] = from
		local b = buckets[cost]
		if b == nil then
			b = {}
			buckets[cost] = b
			heads[cost] = 1
		end
		b[#b + 1] = key
		if cost < lowest then
			lowest = cost
		end
		if cost > highest then
			highest = cost
		end
	end

	for __, s in ipairs(starts) do
		push(s.key, s.cost, nil)
	end

	local expanded = 0
	local c = lowest
	while c <= highest and expanded < maxExpanded do
		local b = buckets[c]
		if b == nil or heads[c] > #b then
			c = c + 1
		else
			local key = b[heads[c]]
			heads[c] = heads[c] + 1
			if best[key] == c then   -- skip entries a cheaper push made stale
				expanded = expanded + 1
				if isGoal(key) then
					local keys : {string} = {}
					local k = key
					while k ~= nil do
						table.insert(keys, 1, k)
						k = parent[k]
					end
					return { found = true, cost = c, keys = keys, expanded = expanded }
				end
				-- steps cost 0 or more, so they land in this bucket or a later one
				for __, step in ipairs(next(key) or {}) do
					push(step.key, c + step.cost, key)
				end
			end
		end
	end
	return { found = false, cost = -1, keys = {}, expanded = expanded }
end

return route
