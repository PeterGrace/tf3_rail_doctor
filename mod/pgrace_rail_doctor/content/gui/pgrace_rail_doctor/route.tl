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

-- A binary heap of {key, length}, smallest length on top.
local record Entry
	key : string
	length : number
end

local function heapPush(heap : {Entry}, e : Entry)
	heap[#heap + 1] = e
	local i = #heap
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].length <= heap[i].length then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function heapPop(heap : {Entry}) : Entry
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, smallest = 2 * i, 2 * i + 1, i
			if l <= #heap and heap[l].length < heap[smallest].length then
				smallest = l
			end
			if r <= #heap and heap[r].length < heap[smallest].length then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[smallest], heap[i] = heap[i], heap[smallest]
			i = smallest
		end
	end
	return top
end

function route.shortest(starts : {PgraceRailDoctorRoute.Weighted}, goalOf : function(string) : string, goalCount : integer, next : function(string) : {PgraceRailDoctorRoute.Weighted}, maxExpanded : integer) : PgraceRailDoctorRoute.Distances
	local best : {string : number} = {}
	local parent : {string : string} = {}
	local done : {string : boolean} = {}
	local heap : {Entry} = {}
	for __, s in ipairs(starts) do
		if best[s.key] == nil or s.length < best[s.key] then
			best[s.key] = s.length
			heapPush(heap, { key = s.key, length = s.length })
		end
	end
	local found : {string : number} = {}
	local paths : {string : {string}} = {}
	local count, expanded = 0, 0
	while #heap > 0 and count < goalCount and expanded < maxExpanded do
		local e = heapPop(heap)
		if not done[e.key] and e.length == best[e.key] then
			done[e.key] = true
			expanded = expanded + 1
			local goal = goalOf(e.key)
			if goal ~= nil and found[goal] == nil then
				found[goal] = e.length
				local keys : {string} = {}
				local k = e.key
				while k ~= nil do
					table.insert(keys, 1, k)
					k = parent[k]
				end
				paths[goal] = keys
				count = count + 1
			end
			for __, step in ipairs(next(e.key) or {}) do
				local length = e.length + step.length
				if not done[step.key] and (best[step.key] == nil or length < best[step.key]) then
					best[step.key] = length
					parent[step.key] = e.key
					heapPush(heap, { key = step.key, length = length })
				end
			end
		end
	end
	return { found = found, paths = paths, expanded = expanded }
end

return route
