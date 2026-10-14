local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_eow = ug_require "::/gui/entity_window/line/line_eow.script.tl" as LineEow
local suggest = ug_require "pgrace_rail_doctor::/gui/pgrace_rail_doctor/suggest.tl" as PgraceRailDoctorSuggest

-- A line window card for rail lines with legs that have no path: which terminals would give them one.
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

local record Row
	text : string
	class : string
end

local function addRow(rows : {Row}, text : string, class? : string)
	rows[#rows + 1] = { text = text, class = class or "font-scale-body" }
end

-- Logged for comparison with our suggestions; the game's own assigner didn't move these stops off terminal 0.
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

	local calls = 0
	local reach = function(leg : integer, a : integer, b : integer) : boolean
		calls = calls + 1
		return trainPath(stops[leg].candidates[a].node, stops[leg % n + 1].candidates[b].node)
	end

	-- does the pathfinder see what the game sees on the terminals used now?
	local broken : {integer} = {}
	local blind = false
	for i = 1, n do
		local ours = reach(i, stops[i].current, stops[i % n + 1].current)
		log(string.format("leg %d %s -> %s: game %s, pathfinder %s", i, stops[i].name, stops[i % n + 1].name,
			gameBroken[i] and "NO PATH" or "ok", ours and "path" or "no path"))
		if gameBroken[i] then
			broken[#broken + 1] = i
			if ours then
				blind = true
			end
		end
	end
	logBestAssignment(lineEntity, line)

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

	if blind then
		for __, i in ipairs(broken) do
			addRow(rows, legTitle(i))
		end
		addRow(rows, _("The game's pathfinder finds a path here that trains can't use, so Rail Doctor can't suggest terminals."), "font-scale-annotation")
		return rows
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
		elseif not fix.found then
			addRow(rows, "    " .. _("No terminals work: the track or its signals block this leg"), "font-scale-annotation")
		else
			for __, change in ipairs(fix.changes) do
				anyChange = true
				local s = stops[change.stop]
				addRow(rows, "    " .. fmt(_("Use {terminal} at {station}"), {
					terminal = terminalLabel(s.candidates[change.candidate]), station = s.name,
				}), "font-scale-annotation")
			end
		end
	end
	if anyChange then
		addRow(rows, _("Untick \"Assign terminals automatically\" in Manage Line before changing terminals."), "font-scale-annotation")
	end
	log(string.format("%d broken legs, %d pathfinder calls, %.1f ms", #broken, calls, clock:getTime() / 1000))
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
		children[#children + 1] = builtin.TextView{ meta = { class = row.class }, text = row.text }
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
