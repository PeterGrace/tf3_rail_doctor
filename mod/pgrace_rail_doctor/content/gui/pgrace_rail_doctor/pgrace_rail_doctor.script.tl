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

local loggedPathError = false

-- The game's pathfinder. Kept for comparison: on one line it found paths the game rejects.
local function trainPath(from : NodeId, to : NodeId) : boolean
	local ok, path = pcall(function() : {{EdgeId, boolean}}
		return api.engine.util.pathfinding.findPathNodeToNode({ from }, { to }, { api.type.enum.TransportMode.TRAIN })
	end)
	if not ok then
		if not loggedPathError then
			loggedPathError = true
			log("findPathNodeToNode failed: " .. tostring(path))
		end
		return false
	end
	return path ~= nil and #(path as {any}) > 0
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
end

local record SignalAt
	list : Engine.Entity
	index : integer
	oneWay : boolean
	typeText : string
end

-- How a signal blocks a train, until a probe settles it: whether getSignal(edge, false) is the signal for trains
-- running node0 -> node1 (not swapped) or the other way (swapped), and whether only one-way signals block from behind.
local record Variant
	name : string
	swap : boolean
	oneWayOnly : boolean
end

local VARIANTS : {Variant} = {
	{ name = "A-oneway", swap = false, oneWayOnly = true },
	{ name = "B-oneway", swap = true, oneWayOnly = true },
	{ name = "A-any", swap = false, oneWayOnly = false },
	{ name = "B-any", swap = true, oneWayOnly = false },
}

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
			return {
				node0 = be.node0, node1 = be.node1, t0 = be.tangent0, t1 = be.tangent1,
				length = geom.length, mid = api.engine.util.transport.calcPosition(geom, 0.5),
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

local function isOneWay(t : any) : boolean
	local ok, yes = pcall(function() : boolean
		return t == api.type.enum.SignalType.ONE_WAY_PATH_SIGNAL
	end)
	if ok and yes then
		return true
	end
	return tostring(t):find("ONE_WAY") ~= nil
end

local function signalOn(track : Track, edge : Engine.Entity, reversed : boolean) : SignalAt
	local key = tostring(edge) .. (reversed and "R" or "F")
	if track.noSignal[key] then
		return nil
	end
	local s = track.signals[key]
	if s == nil then
		local ok, result = pcall(function() : SignalAt
			local id = api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(edge, 0), reversed)
			if id == nil or id.entity == nil or id.entity < 0 then
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

local function searchLeg(track : Track, from : Engine.Entity, to : Engine.Entity, v : Variant, walls : boolean) : PgraceRailDoctorRoute.Result
	local function arrivalNode(key : string) : Engine.Entity
		local e, forward = parseKey(key)
		local p = piece(track, e)
		return p and (forward and p.node1 or p.node0)
	end
	return route.search(
		stepsFrom(track, from, nil, nil, v, walls),
		function(key : string) : boolean
			return arrivalNode(key) == to
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

---------------------------------------------------------------------------------------------------------------------
-- The card

local record Row
	text : string
	class : string
	pos : Vec3f   -- set: the row is a button that moves the camera here
end

local function addRow(rows : {Row}, text : string, class? : string, pos? : Vec3f)
	rows[#rows + 1] = { text = text, class = class or "font-scale-body", pos = pos }
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

local function diagnose(lineEntity : Engine.Entity) : {Row}
	local rows : {Row} = {}
	local clock = api.type.Clock.new()
	local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE) as Engine.Component.Line
	if line == nil then
		return rows
	end
	local n = #line.stops
	log("==== " .. entityName(lineEntity) .. " (" .. tostring(lineEntity) .. "), " .. n .. " stops")

	-- the game's verdict per leg; leg i runs from stop i to stop i % n + 1
	local gameBroken : {boolean} = {}
	local entries = 0
	for __, segment in ipairs(api.engine.util.line.getDetailedLineProblems(lineEntity) or {}) do
		for __, st in ipairs(segment) do
			entries = entries + 1
			gameBroken[entries] = st.noPath == true
		end
	end
	if entries ~= n then
		log("problem entries " .. entries .. " vs stops " .. n)
		addRow(rows, _("Rail Doctor can't read this line's problems yet (waypoints?)."))
		return rows
	end

	local stops : {StopInfo} = {}
	for i, stop in ipairs(line.stops) do
		stops[i] = stopInfo(stop)
		if stops[i].current == nil then
			log("stop " .. i .. " " .. stops[i].name .. ": its terminal wasn't found")
			addRow(rows, fmt(_("Can't find the terminal {station} uses."), { station = stops[i].name }))
			return rows
		end
	end
	local function nodeOf(stop : integer, candidate : integer) : NodeId
		return stops[stop].candidates[candidate].node
	end

	local broken : {integer} = {}
	for i = 1, n do
		if gameBroken[i] then
			broken[#broken + 1] = i
		end
	end
	logBestAssignment(lineEntity, line)

	-- Which reading of the signals makes our search agree with the game on every leg?
	local track = newTrack()
	local chosen : Variant = nil
	for __, v in ipairs(VARIANTS) do
		local parts : {string} = {}
		local agree = true
		for i = 1, n do
			local r = searchLeg(track, nodeOf(i, stops[i].current).entity, nodeOf(i % n + 1, stops[i % n + 1].current).entity, v, true)
			local pf = trainPath(nodeOf(i, stops[i].current), nodeOf(i % n + 1, stops[i % n + 1].current))
			parts[#parts + 1] = string.format("leg %d game=%s ours=%s(%d) pathfinder=%s", i, gameBroken[i] and "NO" or "ok",
				r.found and "ok" or "NO", r.expanded, pf and "ok" or "NO")
			if r.found == gameBroken[i] then
				agree = false
			end
		end
		log("variant " .. v.name .. (agree and " AGREES: " or " differs: ") .. table.concat(parts, "; "))
		if agree and chosen == nil then
			chosen = v
		end
	end
	local typeList : {string} = {}
	for t in pairs(track.typeTexts) do
		typeList[#typeList + 1] = t
	end
	log("signal types seen: " .. table.concat(typeList, ", ") .. "; chosen variant: " .. (chosen and chosen.name or "none"))
	if track.timedOut then
		log(string.format("out of time after %.0f ms", clock:getTime() / 1000))
		if #broken > 0 then
			addRow(rows, _("This network is too big for Rail Doctor to check quickly."), "font-scale-annotation")
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

	if chosen == nil then
		for __, i in ipairs(broken) do
			addRow(rows, legTitle(i))
		end
		addRow(rows, _("Rail Doctor's track search doesn't agree with the game on this line, so it can't suggest anything."), "font-scale-annotation")
		log(string.format("%.1f ms", clock:getTime() / 1000))
		return rows
	end

	local searches = 0
	local reach = function(leg : integer, a : integer, b : integer) : boolean
		searches = searches + 1
		return searchLeg(track, nodeOf(leg, a).entity, nodeOf(leg % n + 1, b).entity, chosen, true).found
	end

	local solverStops : {PgraceRailDoctorSuggest.Stop} = {}
	for i, s in ipairs(stops) do
		solverStops[i] = { current = s.current, count = #s.candidates }
	end
	local fixes = suggest.solve(solverStops, broken, reach)
	local anyChange = false
	for __, fix in ipairs(fixes) do
		addRow(rows, legTitle(fix.leg))
		if fix.alreadyFixed then
			addRow(rows, "    " .. _("Fixed by the change above"), "font-scale-annotation")
		elseif fix.found then
			for __, change in ipairs(fix.changes) do
				anyChange = true
				local s = stops[change.stop]
				addRow(rows, "    " .. fmt(_("Use {terminal} at {station}"), {
					terminal = terminalLabel(s.candidates[change.candidate]), station = s.name,
				}), "font-scale-annotation")
			end
		else
			local i = fix.leg
			local from = stops[i]
			local r = searchLeg(track, nodeOf(i, from.current).entity, nodeOf(i % n + 1, stops[i % n + 1].current).entity, chosen, false)
			local blockers = r.found and blockersOn(track, r, chosen) or {}
			log(string.format("leg %d: cheapest route passes %d signal(s) the wrong way (%d states)", i, #blockers, r.expanded))
			if #blockers == 0 then
				addRow(rows, "    " .. _("No terminals work, and no track leads there"), "font-scale-annotation")
			end
			for __, b in ipairs(blockers) do
				log(string.format("  blocker: list %s[%d] %s at %.0f m, pos (%.0f, %.0f)", tostring(b.signal.list), b.signal.index,
					b.signal.typeText, b.distance, b.pos.x, b.pos.y))
				addRow(rows, "    " .. fmt(_("One-way signal facing the wrong way, {distance} after {station}"), {
					distance = formatLength(b.distance), station = from.name,
				}), "font-scale-annotation", b.pos)
			end
		end
	end
	if track.timedOut then
		addRow(rows, _("Rail Doctor ran out of time; some legs weren't checked fully."), "font-scale-annotation")
	end
	if anyChange then
		addRow(rows, _("Untick \"Assign terminals automatically\" in Manage Line before changing terminals."), "font-scale-annotation")
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
		return { { text = _("Error (see log)"), class = "font-scale-body" } }
	end)
	local children : {TreeNodeId} = {}
	for __, row in ipairs(state:old()) do
		local text = builtin.TextView{ meta = { class = row.class }, text = row.text }
		if row.pos ~= nil then
			local pos = row.pos
			children[#children + 1] = builtin.Button{
				meta = { tooltip = _("Show on the map") },
				content = builtin.BoxLayout{ children = { text } },
				onClick = function()
					api.gui.camera.focusPosition(pos, 200)
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
