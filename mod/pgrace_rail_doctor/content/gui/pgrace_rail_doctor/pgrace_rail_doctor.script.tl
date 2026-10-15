local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_eow = ug_require "::/gui/entity_window/line/line_eow.script.tl" as LineEow
local suggest = ug_require "pgrace_rail_doctor::/gui/pgrace_rail_doctor/suggest.tl" as PgraceRailDoctorSuggest
local route = ug_require "pgrace_rail_doctor::/gui/pgrace_rail_doctor/route.tl" as PgraceRailDoctorRoute

-- A line window card for rail lines with legs that have no path: which terminals would give them one, and which
-- one-way signals block a leg that no terminal fixes.
-- See docs/superpowers/specs/2026-10-14-terminal-suggestions-design.md.

local function log(s : string)
	debugPrint("[rail_doctor] " .. s)
end

local function fmt(text : string, values : {string : string}) : string
	return (text:gsub("{(%w+)}", function(k : string) : string
		return values[k] or ("{" .. k .. "}")
	end))
end

local function entityName(e : Engine.Entity) : string
	local ok, n = pcall(function() : string
		return api.engine.util.getEntityName(e)
	end)
	return ok and tostring(n) or "?"
end

-- One terminal a stop could use.
local record Candidate
	station : integer   -- zero-based, within the station group
	terminal : integer  -- zero-based, within the station
	node : NodeId
	number : integer    -- as the game shows it: counted across the group, from 1
end

local record StopInfo
	name : string
	candidates : {Candidate}
	current : integer   -- index into candidates
end

local function terminalLabel(c : Candidate) : string
	return fmt(_("Terminal {n}"), { n = tostring(c.number) })
end

-- Every terminal in the stop's station group that loads what the stop's terminal loads now.
local function stopInfo(stop : Engine.Component.Line.Stop) : StopInfo
	local info : StopInfo = { name = entityName(stop.stationGroup), candidates = {}, current = nil }
	local group = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP) as Engine.Component.StationGroup
	if group == nil then
		return info
	end
	local stations : {Station} = {}
	for si, stationEntity in ipairs(group.stations) do
		stations[si] = api.engine.getComponent(stationEntity, api.type.ComponentType.STATION) as Station
	end
	local now = stations[stop.station + 1] and stations[stop.station + 1].terminals[stop.terminal + 1]
	local number = 0
	for si, station in ipairs(stations) do
		for ti, terminal in ipairs(station and station.terminals or {}) do
			number = number + 1
			local isCurrent = si - 1 == stop.station and ti - 1 == stop.terminal
			local sameKind = now == nil
				or (now.passengersLoad and terminal.passengersLoad)
				or ((now.cargoLoad or now.cargoUnload) and (terminal.cargoLoad or terminal.cargoUnload))
			if terminal.vehicleNodeId ~= nil and (isCurrent or sameKind) then
				info.candidates[#info.candidates + 1] = { station = si - 1, terminal = ti - 1, node = terminal.vehicleNodeId, number = number }
				if isCurrent then
					info.current = #info.candidates
				end
			end
		end
	end
	return info
end

---------------------------------------------------------------------------------------------------------------------
-- Track as a train sees it. Each piece of track is a BASE_EDGE entity between two base-node entities, with one
-- transport-network edge (index 0). A search state is "<edge>+" (running node0 -> node1) or "<edge>-", standing at
-- the far end. A train carries on only into track heading the same way (tangents), and reverses only at the start.

local record Piece
	node0 : Engine.Entity
	node1 : Engine.Entity
	t0 : Vec3f
	t1 : Vec3f
	length : number
	mid : Vec3f
	p0 : Vec3f
	p1 : Vec3f
	edgeCount : integer   -- transport-network edges in the piece (a signal may split it)
end

local record SignalAt
	list : Engine.Entity
	index : integer
	oneWay : boolean
	typeText : string
end

-- How a signal blocks a train: whether getSignal(edge, false) is the signal for trains running node0 -> node1 (not
-- swapped) or the other way (swapped), and whether only one-way signals block from behind. Settled in-game on the
-- test map (scenario E): swapped, one-way only. The others are kept for the self-check's log only.
local record Variant
	name : string
	swap : boolean
	oneWayOnly : boolean
end

local VERIFIED : Variant = { name = "B-oneway", swap = true, oneWayOnly = true }

local MAX_EXPANDED = 50000
local BUDGET_US = 1000000   -- the whole check stops after 1 s (it runs on the main thread when the window opens)

local record Track
	pieces : {Engine.Entity : Piece}
	missing : {Engine.Entity : boolean}
	nodeEdges : {Engine.Entity : {Engine.Entity}}
	signals : {string : SignalAt}
	noSignal : {string : boolean}
	typeTexts : {string : boolean}
	clock : Clock
	timedOut : boolean
end

local function newTrack() : Track
	return { pieces = {}, missing = {}, nodeEdges = {}, signals = {}, noSignal = {}, typeTexts = {},
		clock = api.type.Clock.new(), timedOut = false }
end

local function piece(track : Track, e : Engine.Entity) : Piece
	if track.missing[e] then
		return nil
	end
	local p = track.pieces[e]
	if p == nil then
		local ok, result = pcall(function() : Piece
			local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			local tn = api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			if be == nil or tn == nil or tn.edges[1] == nil then
				return nil
			end
			local geom = tn.edges[1].geometry
			local length = 0.0
			for __, edge in ipairs(tn.edges) do
				length = length + edge.geometry.length
			end
			return {
				node0 = be.node0, node1 = be.node1, t0 = be.tangent0, t1 = be.tangent1, p0 = be.position0, p1 = be.position1,
				length = length, mid = api.engine.util.transport.calcPosition(geom, 0.5),
				edgeCount = #tn.edges,
			}
		end)
		p = ok and result as Piece or nil
		if p == nil then
			track.missing[e] = true
			return nil
		end
		track.pieces[e] = p
	end
	return p
end

local function edgesAt(track : Track, node : Engine.Entity) : {Engine.Entity}
	local list = track.nodeEdges[node]
	if list == nil then
		local ok, result = pcall(function() : {Engine.Entity}
			return api.engine.system.streetSystem.getNodeTrackSegments(node)
		end)
		list = ok and result as {Engine.Entity} or {}
		track.nodeEdges[node] = list
	end
	return list
end

-- Signal types come back as plain numbers; 1 is ONE_WAY_SIGNAL in the tealdef's order (SIGNAL, ONE_WAY_SIGNAL,
-- WAYPOINT). Every signal Express & Local and the test map's wrong-way signals put down read 1.
local function isOneWay(t : any) : boolean
	if t == 1 then
		return true
	end
	local ok, yes = pcall(function() : boolean
		return t == api.type.enum.SignalType.ONE_WAY_PATH_SIGNAL
	end)
	return (ok and yes) or tostring(t):find("ONE_WAY") ~= nil
end

local function signalOn(track : Track, edge : Engine.Entity, reversed : boolean) : SignalAt
	local key = tostring(edge) .. (reversed and "R" or "F")
	if track.noSignal[key] then
		return nil
	end
	local s = track.signals[key]
	if s == nil then
		local ok, result = pcall(function() : SignalAt
			-- a signal partway along a piece may sit on any of its edges
			local p = piece(track, edge)
			local id : SignalId = nil
			for k = 0, (p and p.edgeCount or 1) - 1 do
				local candidate = api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(edge, k), reversed)
				if id == nil and candidate ~= nil and candidate.entity ~= nil and candidate.entity >= 0 then
					id = candidate
				end
			end
			if id == nil then
				return nil
			end
			local list = api.engine.getComponent(id.entity, api.type.ComponentType.SIGNAL_LIST) as Engine.Component.SignalList
			local t : any = list and list.signals[id.index + 1] and list.signals[id.index + 1].type
			local text = tostring(t)
			track.typeTexts[text] = true
			return { list = id.entity, index = id.index, oneWay = isOneWay(t), typeText = text }
		end)
		s = ok and result as SignalAt or nil
		if s == nil then
			track.noSignal[key] = true
			return nil
		end
		track.signals[key] = s
	end
	return s
end

-- The signal that blocks a train running over the edge in this direction: one facing the other way.
local function blocker(track : Track, edge : Engine.Entity, forward : boolean, v : Variant) : SignalAt
	local againstReversed = forward
	if v.swap then
		againstReversed = not forward
	end
	local s = signalOn(track, edge, againstReversed)
	if s ~= nil and (s.oneWay or not v.oneWayOnly) then
		return s
	end
	return nil
end

local function stateKey(edge : Engine.Entity, forward : boolean) : string
	return tostring(edge) .. (forward and "+" or "-")
end

local function parseKey(key : string) : Engine.Entity, boolean
	return math.floor(tonumber(key:sub(1, -2))) as Engine.Entity, key:sub(-1) == "+"
end

local function dot2(a : Vec3f, b : Vec3f) : number
	return a.x * b.x + a.y * b.y
end

-- Steps out of a node: every piece of track at it, in the direction leading away from it. arriving is the travel
-- direction at the node (nil at the start, where the train may leave either way).
local function stepsFrom(track : Track, node : Engine.Entity, fromEdge : Engine.Entity, arriving : Vec3f, v : Variant, walls : boolean) : {PgraceRailDoctorRoute.Step}
	local out : {PgraceRailDoctorRoute.Step} = {}
	for __, e in ipairs(edgesAt(track, node)) do
		local p = e ~= fromEdge and piece(track, e) or nil
		if p ~= nil then
			for __, forward in ipairs({ true, false }) do
				local starts = (forward and p.node0 or p.node1) == node
				if starts then
					local leaving = forward and p.t0 or api.type.Vec3f.new(-p.t1.x, -p.t1.y, -p.t1.z)
					if arriving == nil or dot2(arriving, leaving) > 0 then
						local cost = blocker(track, e, forward, v) ~= nil and 1 or 0
						if not (walls and cost > 0) then
							out[#out + 1] = { key = stateKey(e, forward), cost = walls and 0 or cost }
						end
					end
				end
			end
		end
	end
	return out
end

-- Where a stretch of a line starts or ends: a terminal's node, or a waypoint (a piece of track a train passes in one
-- of dirs).
local record End
	node : Engine.Entity
	piece : Engine.Entity
	dirs : {boolean}
	name : string
	pos : Vec3f   -- waypoints: where it is
end

local function arrivalNode(track : Track, key : string) : Engine.Entity
	local e, forward = parseKey(key)
	local p = piece(track, e)
	return p and (forward and p.node1 or p.node0)
end

local function atEnd(track : Track, key : string, to : End) : boolean
	if to.node ~= nil then
		return arrivalNode(track, key) == to.node
	end
	local e, forward = parseKey(key)
	if e ~= to.piece then
		return false
	end
	for __, d in ipairs(to.dirs) do
		if d == forward then
			return true
		end
	end
	return false
end

-- A train starts at a terminal facing either way; from a waypoint it carries on the way it passed it.
-- visit, if given, sees every state the search takes off its queue; isGoal, if given, replaces "arrived at to".
local function searchBetween(track : Track, from : End, to : End, v : Variant, walls : boolean,
		visit? : function(key : string), isGoal? : function(key : string) : boolean) : PgraceRailDoctorRoute.Result
	local starts : {PgraceRailDoctorRoute.Step} = {}
	if from.node ~= nil then
		starts = stepsFrom(track, from.node, nil, nil, v, walls)
	else
		for __, d in ipairs(from.dirs) do
			starts[#starts + 1] = { key = stateKey(from.piece, d), cost = 0 }
		end
	end
	return route.search(
		starts,
		function(key : string) : boolean
			if visit ~= nil then
				visit(key)
			end
			if isGoal ~= nil then
				return isGoal(key)
			end
			return atEnd(track, key, to)
		end,
		function(key : string) : {PgraceRailDoctorRoute.Step}
			if track.timedOut or track.clock:getTime() > BUDGET_US then
				track.timedOut = true
				return {}
			end
			local e, forward = parseKey(key)
			local p = piece(track, e)
			if p == nil then
				return {}
			end
			local arriving = forward and p.t1 or api.type.Vec3f.new(-p.t0.x, -p.t0.y, -p.t0.z)
			return stepsFrom(track, forward and p.node1 or p.node0, e, arriving, v, walls)
		end,
		MAX_EXPANDED)
end

local function routeLength(track : Track, result : PgraceRailDoctorRoute.Result) : number
	local total = 0.0
	for __, key in ipairs(result.keys) do
		local p = piece(track, (parseKey(key)))
		if p ~= nil then
			total = total + p.length
		end
	end
	return total
end

local function nodePosition(node : Engine.Entity) : Vec3f
	local ok, pos = pcall(function() : Vec3f
		local bn = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		return bn and bn.position
	end)
	return ok and pos as Vec3f or nil
end

local function endPosition(track : Track, e : End) : Vec3f
	if e.node ~= nil then
		return nodePosition(e.node)
	end
	if e.pos ~= nil then
		return e.pos
	end
	local p = piece(track, e.piece)
	return p and p.mid
end

-- A line's waypoint is only a spot on the track (Waypoint.edgePos): nothing is attached to the track there and it has
-- no direction, so a train may pass it either way (verified on the test map, scenario J).
local function waypointEnd(track : Track, edgePos : EdgePos, name : string) : End
	local e = edgePos.edgeId.entity
	local ok, pos = pcall(function() : Vec3f
		local tn = api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		return api.engine.util.transport.calcPosition(tn.edges[edgePos.edgeId.index + 1].geometry, edgePos.param)
	end)
	local p = piece(track, e)
	return { piece = e, dirs = { true, false }, name = name, pos = (ok and pos ~= nil) and pos as Vec3f or (p and p.mid) }
end

local record Frontier
	pos : Vec3f
	distance : number   -- metres along the track from the stretch's start
end

-- How far towards the destination a train gets, obeying the signals: of everywhere it can reach, the track end
-- nearest the destination (straight line). That's where to look for a gap.
local function frontierOf(track : Track, from : End, to : End, v : Variant) : Frontier
	local target = endPosition(track, to)
	if target == nil then
		return nil
	end
	local bestKey : string = nil
	local bestPos : Vec3f = nil
	local bestDist = math.huge
	searchBetween(track, from, to, v, true, function(key : string)
		local e, forward = parseKey(key)
		local p = piece(track, e)
		local pos = p and (forward and p.p1 or p.p0)
		if pos ~= nil then
			local dx, dy = pos.x - target.x, pos.y - target.y
			local d = dx * dx + dy * dy
			if d < bestDist then
				bestDist, bestKey, bestPos = d, key, pos
			end
		end
	end)
	if bestKey == nil then
		return nil
	end
	local r = searchBetween(track, from, to, v, true, nil, function(key : string) : boolean
		return key == bestKey
	end)
	return { pos = bestPos, distance = r.found and routeLength(track, r) or 0 }
end

-- With more wrong-way signals than this on the cheapest route, the route is running against the traffic on the
-- other track (a gap, say), and the place trains get stuck says more than the list of signals.
local MAX_SIGNALS_LISTED = 2

local record Blocker
	signal : SignalAt
	pos : Vec3f
	distance : number   -- metres along the route from the leg's start
end

-- The one-way signals a train would have to pass the wrong way on the cheapest route.
local function blockersOn(track : Track, result : PgraceRailDoctorRoute.Result, v : Variant) : {Blocker}
	local out : {Blocker} = {}
	local distance = 0.0
	for __, key in ipairs(result.keys) do
		local e, forward = parseKey(key)
		local p = piece(track, e)
		if p ~= nil then
			local s = blocker(track, e, forward, v)
			if s ~= nil then
				out[#out + 1] = { signal = s, pos = p.mid, distance = distance + p.length / 2 }
			end
			distance = distance + p.length
		end
	end
	return out
end

-- PROBE (remove before release): the route the search took, piece by piece, with every edge's signals.
local function dumpRoute(track : Track, label : string, result : PgraceRailDoctorRoute.Result)
	log("route " .. label .. ": " .. #result.keys .. " pieces")
	for n, key in ipairs(result.keys) do
		local e, forward = parseKey(key)
		local p = piece(track, e)
		local parts : {string} = {}
		local ok, err = pcall(function() : boolean
			local tn = api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			for k, edge in ipairs(tn.edges) do
				local sigs : {string} = {}
				for __, r in ipairs({ false, true }) do
					local id = api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(e, k - 1), r)
					if id ~= nil and id.entity ~= nil and id.entity >= 0 then
						sigs[#sigs + 1] = (r and "R=" or "F=") .. tostring(id.entity) .. "[" .. tostring(id.index) .. "]"
					end
				end
				parts[#parts + 1] = string.format("e%d %s.%s>%s.%s {%s}", k - 1, tostring(edge.conns[1].entity),
					tostring(edge.conns[1].index), tostring(edge.conns[2].entity), tostring(edge.conns[2].index),
					table.concat(sigs, " "))
			end
			return true
		end)
		log(string.format("  %d %s node0=%s node1=%s len=%.0f %s", n, key, tostring(p and p.node0), tostring(p and p.node1),
			p and p.length or 0, ok and table.concat(parts, "; ") or ("<" .. tostring(err) .. ">")))
	end
end

---------------------------------------------------------------------------------------------------------------------
-- The card

local record Row
	level : integer   -- indent: 0 titles, 1 details, 2 details of a detail
	text : string
	class : string
	pos : Vec3f   -- set: the row is a button that moves the camera here
end

local function addRow(rows : {Row}, level : integer, text : string, class? : string, pos? : Vec3f)
	rows[#rows + 1] = { level = level, text = text, class = class or "font-scale-body", pos = pos }
end

-- Where a signal stands: its own bounding box if it has one, else the middle of its piece of track.
local function signalPosition(list : Engine.Entity, fallback : Vec3f) : Vec3f
	local ok, pos = pcall(function() : Vec3f
		local bv = api.engine.getComponent(list, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
		if bv == nil then
			return nil
		end
		return api.type.Vec3f.new(0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y), 0.5 * (bv.bbox.min.z + bv.bbox.max.z))
	end)
	return (ok and pos ~= nil) and pos as Vec3f or fallback
end

-- Logged for comparison with our suggestions.
local function logBestAssignment(lineEntity : Engine.Entity, line : Engine.Component.Line)
	local ok, err = pcall(function() : boolean
		local copy = api.type.Line.new(line)
		local best = api.engine.system.lineSystem.getBestLineAssignment(lineEntity, copy, true)
		local parts : {string} = {}
		for i, st in ipairs(best or {}) do
			parts[#parts + 1] = string.format("%d:%d/%d", i, st.station, st.terminal)
		end
		log("game's best assignment (stop:station/terminal): " .. table.concat(parts, " "))
		return true
	end)
	if not ok then
		log("getBestLineAssignment failed: " .. tostring(err))
	end
end

local function formatLength(m : number) : string
	local ok, s = pcall(function() : string
		return api.util.formatLength(m)
	end)
	return ok and s as string or string.format("%.0f m", m)
end

-- What's in the way on one stretch (the current terminals): one or two wrong-way signals, or the place trains get
-- stuck.
-- level: the indent of its rows. orChange: the card has already named a likelier cause, so the signals are only the
-- other way to fix it.
local function reportStretch(rows : {Row}, track : Track, from : End, to : End, v : Variant, label : string, level : integer,
		orChange : boolean)
	local r = searchBetween(track, from, to, v, false)
	local blockers = r.found and blockersOn(track, r, v) or {}
	log(string.format("%s: cheapest route passes %d signal(s) the wrong way (%d states)", label, #blockers, r.expanded))
	local function orHeading(text : string)
		addRow(rows, level, " ", "font-scale-annotation")   -- a small gap between the two ways to fix it
		addRow(rows, level, text, "font-scale-headline")
		level = level + 1
	end
	if #blockers == 0 or #blockers > MAX_SIGNALS_LISTED then
		if orChange then
			orHeading(_("Or check the track:"))
		end
		local f = frontierOf(track, from, to, v)
		if f ~= nil then
			log(string.format("  stuck at %.0f m, pos (%.0f, %.0f)", f.distance, f.pos.x, f.pos.y))
			addRow(rows, level, fmt(_("Trains get no closer to {to} than here, {distance} after {station}. Is the track connected?"), {
				to = to.name, distance = formatLength(f.distance), station = from.name,
			}), "font-scale-annotation", f.pos)
		else
			addRow(rows, level, _("No terminals work, and no track leads there"), "font-scale-annotation")
		end
		if #blockers > 0 then
			addRow(rows, level, fmt(_("(The only other way runs against {count} one-way signals.)"), {
				count = tostring(#blockers),
			}), "font-scale-annotation")
		end
		return
	end
	if orChange then
		orHeading(_("Or change these one-way signals:"))
	end
	for __, b in ipairs(blockers) do
		log(string.format("  blocker: list %s[%d] %s at %.0f m, pos (%.0f, %.0f)", tostring(b.signal.list), b.signal.index,
			b.signal.typeText, b.distance, b.pos.x, b.pos.y))
		-- the name the game gives the signal ("Signal #4"), as in its window
		local name = entityName(b.signal.list)
		local text = (name ~= "?" and name ~= "")
			and fmt(_("One-way signal ({name}) facing the wrong way, {distance} after {station}"), {
				name = name, distance = formatLength(b.distance), station = from.name })
			or fmt(_("One-way signal facing the wrong way, {distance} after {station}"), {
				distance = formatLength(b.distance), station = from.name })
		addRow(rows, level, text, "font-scale-annotation", signalPosition(b.signal.list, b.pos))
	end
end

local function diagnose(lineEntity : Engine.Entity) : {Row}
	local rows : {Row} = {}
	local clock = api.type.Clock.new()
	local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE) as Engine.Component.Line
	if line == nil then
		return rows
	end
	local n = #line.stops
	log("==== " .. entityName(lineEntity) .. " (" .. tostring(lineEntity) .. "), " .. n .. " stops")

	-- The game's verdict: one list per stop. Entry 1 runs from stop i to its first waypoint (or the next stop),
	-- entry k from waypoint k - 1 on.
	local problems = api.engine.util.line.getDetailedLineProblems(lineEntity) or {}
	local shapeOk = #problems == n
	for i = 1, n do
		shapeOk = shapeOk and problems[i] ~= nil and #problems[i] == 1 + #line.stops[i].waypoints
	end
	if not shapeOk then
		log("problem lists don't match the stops and waypoints")
		addRow(rows, 0, _("Rail Doctor can't read this line's problems."))
		return rows
	end

	local stops : {StopInfo} = {}
	for i, stop in ipairs(line.stops) do
		stops[i] = stopInfo(stop)
		if stops[i].current == nil then
			log("stop " .. i .. " " .. stops[i].name .. ": its terminal wasn't found")
			addRow(rows, 0, fmt(_("Can't find the terminal {station} uses."), { station = stops[i].name }))
			return rows
		end
	end

	local track = newTrack()
	local waypoints : {{End}} = {}
	local numbered = 0
	for i, stop in ipairs(line.stops) do
		waypoints[i] = {}
		for __, wp in ipairs(stop.waypoints) do
			numbered = numbered + 1
			waypoints[i][#waypoints[i] + 1] = waypointEnd(track, wp.edgePos, fmt(_("Waypoint {n}"), { n = tostring(numbered) }))
		end
	end

	-- the ends of leg i's stretches: stop i (terminal a), its waypoints, stop i + 1 (terminal b)
	local function legEnds(i : integer, a : integer, b : integer) : {End}
		local j = i % n + 1
		local ends : {End} = { { node = stops[i].candidates[a].node.entity, name = stops[i].name } }
		for __, wp in ipairs(waypoints[i]) do
			ends[#ends + 1] = wp
		end
		ends[#ends + 1] = { node = stops[j].candidates[b].node.entity, name = stops[j].name }
		return ends
	end
	local function currentEnds(i : integer) : {End}
		return legEnds(i, stops[i].current, stops[i % n + 1].current)
	end

	local broken : {integer} = {}
	for i = 1, n do
		for __, st in ipairs(problems[i]) do
			if st.noPath then
				broken[#broken + 1] = i
				break
			end
		end
	end
	logBestAssignment(lineEntity, line)

	-- Self-check: does our search agree with the game on every stretch?
	local v = VERIFIED
	local agree = true
	local parts : {string} = {}
	for i = 1, n do
		local ends = currentEnds(i)
		for k = 1, #ends - 1 do
			local r = searchBetween(track, ends[k], ends[k + 1], v, true)
			local gameNo = problems[i][k].noPath == true
			parts[#parts + 1] = string.format("%d.%d game=%s ours=%s(%d)", i, k, gameNo and "NO" or "ok", r.found and "ok" or "NO", r.expanded)
			if r.found == gameNo then
				agree = false
				if r.found then
					dumpRoute(track, string.format("stretch %d.%d (game says no path)", i, k), r)   -- PROBE
				end
			end
		end
	end
	local typeList : {string} = {}
	for t in pairs(track.typeTexts) do
		typeList[#typeList + 1] = t
	end
	log((agree and "AGREES: " or "differs: ") .. table.concat(parts, "; ") .. "; signal types seen: " .. table.concat(typeList, ", "))
	if track.timedOut then
		log(string.format("out of time after %.0f ms", clock:getTime() / 1000))
		if #broken > 0 then
			addRow(rows, 0, _("This network is too big for Rail Doctor to check quickly."), "font-scale-annotation")
		end
		return rows
	end

	if #broken == 0 then
		return rows
	end

	local function legTitle(i : integer) : string
		local from, to = stops[i], stops[i % n + 1]
		return fmt(_("Leg {leg}: {from} [{fromTerminal}] → {to} [{toTerminal}]"), {
			leg = tostring(i),
			from = from.name, fromTerminal = terminalLabel(from.candidates[from.current]),
			to = to.name, toTerminal = terminalLabel(to.candidates[to.current]),
		})
	end

	if not agree then
		for __, i in ipairs(broken) do
			addRow(rows, 0, legTitle(i))
		end
		addRow(rows, 0, _("Rail Doctor's track search doesn't agree with the game on this line, so it can't suggest anything."), "font-scale-annotation")
		log(string.format("%.1f ms", clock:getTime() / 1000))
		return rows
	end

	-- A leg works with terminals a and b if every stretch, waypoints included, has a path.
	local searches = 0
	local reach = function(leg : integer, a : integer, b : integer) : boolean
		local ends = legEnds(leg, a, b)
		for k = 1, #ends - 1 do
			searches = searches + 1
			if not searchBetween(track, ends[k], ends[k + 1], v, true).found then
				return false
			end
		end
		return true
	end

	local solverStops : {PgraceRailDoctorSuggest.Stop} = {}
	for i, s in ipairs(stops) do
		solverStops[i] = { current = s.current, count = #s.candidates }
	end
	local fixes = suggest.solve(solverStops, broken, reach)
	local anyChange = false
	for __, fix in ipairs(fixes) do
		addRow(rows, 0, legTitle(fix.leg))
		if fix.alreadyFixed then
			addRow(rows, 1, _("Fixed by the change above"), "font-scale-annotation")
		elseif fix.found then
			for __, change in ipairs(fix.changes) do
				anyChange = true
				local s = stops[change.stop]
				addRow(rows, 1, fmt(_("Use {terminal} at {station}"), {
					terminal = terminalLabel(s.candidates[change.candidate]), station = s.name,
				}), "font-scale-annotation")
			end
		else
			local i = fix.leg
			local ends = currentEnds(i)
			local asked : {End : boolean} = {}
			for k = 1, #ends - 1 do
				if problems[i][k].noPath then
					-- a waypoint on the wrong track is the likeliest cause: ask about it first, once
					local wp = ends[k + 1].piece ~= nil and ends[k + 1] or (ends[k].piece ~= nil and ends[k] or nil)
					local level, orChange = 1, false
					if wp ~= nil and not asked[wp] then
						asked[wp] = true
						orChange = true
						addRow(rows, 1, _("Either move the waypoint:"), "font-scale-headline")
						addRow(rows, 2, fmt(_("Trains can't get from {from} to {to}. Is {waypoint} on the track for this direction? (Waypoints only show in Manage Line.)"), {
							from = ends[k].name, to = ends[k + 1].name, waypoint = wp.name,
						}), "font-scale-annotation", endPosition(track, wp))
					elseif #ends > 2 then
						addRow(rows, 1, fmt(_("{from} → {to}:"), { from = ends[k].name, to = ends[k + 1].name }), "font-scale-annotation")
						level = 2
					end
					reportStretch(rows, track, ends[k], ends[k + 1], v, string.format("stretch %d.%d", i, k), level, orChange)
				end
			end
		end
	end
	if track.timedOut then
		addRow(rows, 0, _("Rail Doctor ran out of time; some legs weren't checked fully."), "font-scale-annotation")
	end
	if anyChange then
		addRow(rows, 0, _("Change terminals in Manage Line. If a mod assigns terminals automatically, turn that off for this line first."), "font-scale-annotation")
	end
	log(string.format("%d broken legs, %d searches, %.1f ms", #broken, searches, clock:getTime() / 1000))
	return rows
end

local record BodyParams
	entityId : Engine.Entity
end

local Body = react.RegisterRecipe("PgraceRailDoctorBody", function(params : BodyParams) : TreeNodeId
	local state = react.useStateLazy(function() : {Row}
		local ok, rowsOrError = pcall(function() : {Row}
			return diagnose(params.entityId)
		end)
		if ok then
			return rowsOrError as {Row}
		end
		log("error: " .. tostring(rowsOrError))
		return { { level = 0, text = _("Error (see log)"), class = "font-scale-body" } }
	end)
	local children : {TreeNodeId} = {}
	for __, row in ipairs(state:old()) do
		local indent = string.rep("    ", row.level) .. ((row.pos == nil and row.level > 0) and "  " or "")
		local text = builtin.TextView{ meta = { class = row.class }, text = indent .. row.text }
		if row.pos ~= nil then
			local pos = row.pos
			children[#children + 1] = builtin.Button{
				meta = { tooltip = _("Show on the map") },
				content = builtin.BoxLayout{ children = { text } },
				onClick = function()
					-- as close as the camera goes: it clamps to its own minimum distance
					api.gui.camera.focusPosition(pos, 10)
				end,
			}
		else
			children[#children + 1] = text
		end
	end
	return builtin.BoxLayout{ children = children }
end)

local LinePlugin = react.RegisterPluginRecipe(line_eow.LineEowExtensionPoint, "PgraceRailDoctorLinePlugin", function(params : LineEow.LineWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Rail Doctor"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(Body, { entityId = params.entityId } as BodyParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

-- Shown on rail lines with a leg that has no path. True on error, so the card can report the problem.
local function hasBrokenRailLeg(params : LineEow.LineWidgetPluginParams) : boolean
	local ok, result = pcall(function() : boolean
		if not api.engine.util.line.isLineCompatibleWithCarrier(params.entityId, api.type.enum.Carrier.RAIL, false) then
			return false
		end
		for __, segment in ipairs(api.engine.util.line.getDetailedLineProblems(params.entityId) or {}) do
			for __, st in ipairs(segment) do
				if st.noPath then
					return true
				end
			end
		end
		return false
	end)
	if not ok then
		log("condition error: " .. tostring(result))
		return true
	end
	return result as boolean
end

return {
	LinePlugin = LinePlugin,
	hasBrokenRailLeg = hasBrokenRailLeg,
}
