local suggest : PgraceRailDoctorSuggest = {}

function suggest.solve(stops : {PgraceRailDoctorSuggest.Stop}, broken : {integer}, reach : function(integer, integer, integer) : boolean) : {PgraceRailDoctorSuggest.Fix}
	local n = #stops
	local function nextStop(i : integer) : integer
		return i % n + 1
	end
	local function prevStop(i : integer) : integer
		return (i - 2) % n + 1
	end

	local cache : {string : boolean} = {}
	local function reaches(leg : integer, from : integer, to : integer) : boolean
		local key = leg .. ":" .. from .. ">" .. to
		local hit = cache[key]
		if hit == nil then
			hit = reach(leg, from, to) == true
			cache[key] = hit
		end
		return hit
	end

	local cur : {integer} = {}
	for i, s in ipairs(stops) do
		cur[i] = s.current
	end
	local function works(leg : integer) : boolean
		return reaches(leg, cur[leg], cur[nextStop(leg)])
	end

	-- Tries origin terminal a and destination terminal b for leg i, keeping its neighbours working if they work now.
	local function tryPair(i : integer, a : integer, b : integer) : boolean
		local j = nextStop(i)
		local before : {integer : boolean} = {}
		for _, leg in ipairs({ prevStop(i), j }) do
			if leg ~= i then
				before[leg] = works(leg)
			end
		end
		local oldA, oldB = cur[i], cur[j]
		cur[i], cur[j] = a, b
		local ok = works(i)
		if ok then
			for leg, worked in pairs(before) do
				if worked and not works(leg) then
					ok = false
					break
				end
			end
		end
		if not ok then
			cur[i], cur[j] = oldA, oldB
		end
		return ok
	end

	local fixes : {PgraceRailDoctorSuggest.Fix} = {}
	for _, i in ipairs(broken) do
		local fix : PgraceRailDoctorSuggest.Fix = { leg = i, found = false, alreadyFixed = false, changes = {} }
		fixes[#fixes + 1] = fix
		local j = nextStop(i)
		if works(i) then
			fix.found, fix.alreadyFixed = true, true
		else
			local a0, b0 = cur[i], cur[j]
			-- the destination alone, then the origin alone, then both
			for b = 1, stops[j].count do
				if not fix.found and b ~= b0 and tryPair(i, a0, b) then
					fix.found = true
				end
			end
			for a = 1, stops[i].count do
				if not fix.found and a ~= a0 and tryPair(i, a, b0) then
					fix.found = true
				end
			end
			for a = 1, stops[i].count do
				for b = 1, stops[j].count do
					if not fix.found and a ~= a0 and b ~= b0 and tryPair(i, a, b) then
						fix.found = true
					end
				end
			end
			if fix.found then
				if cur[i] ~= a0 then
					fix.changes[#fix.changes + 1] = { stop = i, candidate = cur[i] }
				end
				if cur[j] ~= b0 then
					fix.changes[#fix.changes + 1] = { stop = j, candidate = cur[j] }
				end
				table.sort(fix.changes, function(x : PgraceRailDoctorSuggest.Change, y : PgraceRailDoctorSuggest.Change) : boolean
					return x.stop < y.stop
				end)
			end
		end
	end
	return fixes
end

return suggest
