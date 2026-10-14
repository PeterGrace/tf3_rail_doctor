local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_eow = ug_require "::/gui/entity_window/line/line_eow.script.tl" as LineEow

-- PROBE (remove before release): everything in this file is a first look at what the engine reports for a
-- line with no path. It logs with the "[rail_doctor] probe" prefix and shows the spots it found in the card.

local TAG = "[rail_doctor] probe "
local NEAREST_SIGNALS = 6

local function log(s : string)
	debugPrint(TAG .. s)
end

local function fmtPos(p : Vec3f) : string
	if p == nil then
		return "nil"
	end
	return string.format("(%.0f, %.0f, %.0f)", p.x, p.y, p.z)
end

local function dist2d(a : Vec3f, b : Vec3f) : number
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local function modeKeys(modes : {TransportMode : boolean}) : string
	if modes == nil then
		return "nil"
	end
	local ok, s = pcall(function() : string
		local keys : {string} = {}
		for k, v in pairs(modes as {any : any}) do
			keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
		end
		table.sort(keys)
		return "{" .. table.concat(keys, ", ") .. "}"
	end)
	return ok and s as string or ("<" .. tostring(s) .. ">")
end

local function entityName(e : Engine.Entity) : string
	local ok, n = pcall(function() : string
		return api.engine.util.getEntityName(e)
	end)
	return ok and tostring(n) or "?"
end

local record SignalInfo
	listEntity : Engine.Entity
	index : integer
	kind : integer
	edgeEntity : Engine.Entity
	edgeIndex : integer
	dir : string
	pos : Vec3f
	posSource : string
end

local record Spot
	label : string
	pos : Vec3f
	nearest : {SignalInfo}
end

local record Report
	lines : {string}
	spots : {Spot}
end

local function centreOf(entity : Engine.Entity) : Vec3f
	local bv = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
	if bv == nil then
		return nil
	end
	return api.type.Vec3f.new(0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y), 0.5 * (bv.bbox.min.z + bv.bbox.max.z))
end

-- The tealdef says edgePr is {EdgeId, boolean}; other pairs turned out to be userdata with named fields at
-- runtime, so try both.
local function readEdgePr(pr : any) : EdgeId, string
	local okIdx, first = pcall(function() : any
		return (pr as {any})[1]
	end)
	if okIdx and first ~= nil then
		local okDir, second = pcall(function() : any
			return (pr as {any})[2]
		end)
		return first as EdgeId, tostring(okDir and second or "?")
	end
	local okNamed, edgeId = pcall(function() : any
		return (pr as {string : any}).edgeId
	end)
	if okNamed and edgeId ~= nil then
		local okDir, dir = pcall(function() : any
			return (pr as {string : any}).dir
		end)
		return edgeId as EdgeId, tostring(okDir and dir or "?")
	end
	return nil, "?"
end

local function collectSignals(report : Report) : {SignalInfo}
	local clock = api.type.Clock.new()
	local entities : {Engine.Entity} = {}
	local okLoop, loopErr = pcall(function() : boolean
		api.engine.forEachEntityWithComponent(function(e : Engine.Entity)
			entities[#entities + 1] = e
		end, api.type.ComponentType.SIGNAL_LIST)
		return true
	end)
	if not okLoop then
		log("SIGNAL_LIST loop failed: " .. tostring(loopErr))
		report.lines[#report.lines + 1] = "Signals: can't loop SIGNAL_LIST (see log)"
		return {}
	end

	local networks : {Engine.Entity : Engine.Component.TransportNetwork} = {}
	local signals : {SignalInfo} = {}
	local kinds : {integer : integer} = {}
	local loggedShape = false
	local listsWithMany = 0
	for _, e in ipairs(entities) do
		local list = api.engine.getComponent(e, api.type.ComponentType.SIGNAL_LIST) as Engine.Component.SignalList
		if list ~= nil then
			if #list.signals > 1 then
				listsWithMany = listsWithMany + 1
			end
			for i, sig in ipairs(list.signals) do
				local kind = math.tointeger(sig.type as any as number) or -1
				kinds[kind] = (kinds[kind] or 0) + 1
				local edgeId, dir = readEdgePr(sig.edgePr)
				if not loggedShape then
					loggedShape = true
					log("first signal: list=" .. tostring(e) .. " type=" .. tostring(sig.type)
						.. " edgePr type=" .. type(sig.edgePr) .. " tostring=" .. tostring(sig.edgePr)
						.. " edgeId=" .. tostring(edgeId) .. " dir=" .. dir)
				end
				local info : SignalInfo = { listEntity = e, index = i - 1, kind = kind, dir = dir }
				if edgeId ~= nil then
					info.edgeEntity = edgeId.entity
					info.edgeIndex = edgeId.index
					local okGeom, pos = pcall(function() : Vec3f
						local network = networks[edgeId.entity]
						if network == nil then
							network = api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
							networks[edgeId.entity] = network
						end
						local edge = network and network.edges[edgeId.index + 1]
						if edge == nil then
							return nil
						end
						return api.engine.util.transport.calcPosition(edge.geometry, 0.5)
					end)
					if okGeom and pos ~= nil then
						info.pos = pos as Vec3f
						info.posSource = "edge"
					end
				end
				if info.pos == nil then
					info.pos = centreOf(e)
					info.posSource = info.pos and "bbox" or "none"
				end
				signals[#signals + 1] = info
			end
		end
	end

	local kindText : {string} = {}
	for k, n in pairs(kinds) do
		kindText[#kindText + 1] = tostring(k) .. ":" .. tostring(n)
	end
	table.sort(kindText)
	local ms = clock:getTime() / 1000
	log(string.format("signals: %d lists, %d signals, by type {%s}, %d lists hold >1 signal, %.1f ms",
		#entities, #signals, table.concat(kindText, ", "), listsWithMany, ms))
	report.lines[#report.lines + 1] = string.format("Signals: %d (types %s), %.0f ms", #signals, table.concat(kindText, " "), ms)
	return signals
end

local function nearestTo(pos : Vec3f, signals : {SignalInfo}) : {SignalInfo}
	local withPos : {SignalInfo} = {}
	for _, s in ipairs(signals) do
		if s.pos ~= nil then
			withPos[#withPos + 1] = s
		end
	end
	table.sort(withPos, function(a : SignalInfo, b : SignalInfo) : boolean
		return dist2d(a.pos, pos) < dist2d(b.pos, pos)
	end)
	local out : {SignalInfo} = {}
	for i = 1, math.min(NEAREST_SIGNALS, #withPos) do
		out[i] = withPos[i]
	end
	return out
end

-- What touches the node where the game's search stopped: its track segments and any signal on their edges.
local function logNode(label : string, node : NodeId)
	local ok, err = pcall(function() : boolean
		local segs = api.engine.system.streetSystem.getNodeTrackSegments(node.entity)
		log(label .. " node entity=" .. tostring(node.entity) .. " index=" .. tostring(node.index)
			.. " trackSegments=" .. tostring(segs and #segs or "nil"))
		for _, seg in ipairs(segs or {}) do
			local network = api.engine.getComponent(seg, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			local edgeCount = network and #network.edges or 0
			local found : {string} = {}
			for i = 0, edgeCount - 1 do
				for _, reversed in ipairs({ false, true }) do
					local okSig, sigId = pcall(function() : SignalId
						return api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(seg, i), reversed)
					end)
					if okSig and sigId ~= nil and (sigId as SignalId).entity ~= nil and (sigId as SignalId).entity >= 0 then
						found[#found + 1] = string.format("edge%d%s->list %s[%s]", i, reversed and "R" or "F",
							tostring((sigId as SignalId).entity), tostring((sigId as SignalId).index))
					end
				end
			end
			log(label .. "   segment " .. tostring(seg) .. " edges=" .. tostring(edgeCount)
				.. " signals={" .. table.concat(found, ", ") .. "}")
		end
		return true
	end)
	if not ok then
		log(label .. " node lookup failed: " .. tostring(err))
	end
end

local function probe(lineEntity : Engine.Entity) : Report
	local report : Report = { lines = {}, spots = {} }
	log("==== line " .. tostring(lineEntity) .. " '" .. entityName(lineEntity) .. "'")

	local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE) as Engine.Component.Line
	if line == nil then
		report.lines[#report.lines + 1] = "Not a line"
		return report
	end
	for i, stop in ipairs(line.stops) do
		log(string.format("stop %d: %s station=%d terminal=%d alternatives=%d", i, entityName(stop.stationGroup),
			stop.station, stop.terminal, stop.alternativeTerminals and #stop.alternativeTerminals or 0))
	end

	local problems = api.engine.util.line.getDetailedLineProblems(lineEntity)
	log("detailed problems: " .. tostring(problems and #problems or "nil") .. " segment(s)")
	local n = 0
	for si, segment in ipairs(problems or {}) do
		for k, st in ipairs(segment) do
			n = n + 1
			log(string.format("seg %d entry %d (#%d): empty=%s noPath=%s fromAlt=%s toAlt=%s duplicate=%s incompatible=%s",
				si, k, n, tostring(st.empty), tostring(st.noPath), tostring(st.noPathFromAlternative ~= nil),
				tostring(st.noPathToAlternative ~= nil), tostring(st.duplicateStop), tostring(st.incompatibleStop)))
			local locs : {{string, UtilLine.PathProblemLocation}} = {}
			if st.noPathLocation ~= nil then
				locs[#locs + 1] = { "noPath", st.noPathLocation }
			end
			if st.noPathFromAlternative ~= nil then
				locs[#locs + 1] = { "fromAlt T" .. tostring(st.noPathFromAlternative[1]), st.noPathFromAlternative[2] }
			end
			if st.noPathToAlternative ~= nil then
				locs[#locs + 1] = { "toAlt T" .. tostring(st.noPathToAlternative[1]), st.noPathToAlternative[2] }
			end
			for _, pair in ipairs(locs) do
				local kind, loc = pair[1] as string, pair[2] as UtilLine.PathProblemLocation
				if loc ~= nil then
					local label = string.format("Leg %d %s", n, kind)
					log(string.format("  %s: pos=%s edgeIndex=%s ok=%s relaxed=%s allowed=%s", label,
						fmtPos(loc.nodePosition), tostring(loc.edgeIndex), modeKeys(loc.okModes),
						modeKeys(loc.relaxedModes), modeKeys(loc.allowedModes)))
					if loc.node ~= nil then
						logNode("  " .. label, loc.node)
					end
					if loc.nodePosition ~= nil then
						report.spots[#report.spots + 1] = { label = label, pos = loc.nodePosition }
					end
				end
			end
			if st.noPath and #locs == 0 then
				report.lines[#report.lines + 1] = string.format("Leg %d: no path, no location given", n)
			end
		end
	end

	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineEntity)
	log("vehicles: " .. tostring(vehicles and #vehicles or "nil"))
	if vehicles ~= nil and #vehicles > 0 then
		local okFail, fail = pcall(function() : Failure
			return api.engine.util.line.getFailedPathReason(vehicles[1], lineEntity, true)
		end)
		if okFail and fail ~= nil then
			local f = fail as Failure
			log("failed path reason (vehicle " .. tostring(vehicles[1]) .. "): reason=" .. tostring(f.reason) .. " pos=" .. fmtPos(f.pos))
			report.lines[#report.lines + 1] = "Failed path reason: " .. tostring(f.reason)
			if f.pos ~= nil then
				report.spots[#report.spots + 1] = { label = "Vehicle fail pos", pos = f.pos }
			end
		else
			log("getFailedPathReason failed: " .. tostring(fail))
		end
	end

	if #report.spots == 0 then
		report.lines[#report.lines + 1] = "No problem locations reported"
	else
		local signals = collectSignals(report)
		for _, spot in ipairs(report.spots) do
			spot.nearest = nearestTo(spot.pos, signals)
			for _, s in ipairs(spot.nearest) do
				log(string.format("  near %s: %.0f m list=%s[%d] type=%d dir=%s edge=%s:%s pos=%s (%s)", spot.label,
					dist2d(s.pos, spot.pos), tostring(s.listEntity), s.index, s.kind, s.dir, tostring(s.edgeEntity),
					tostring(s.edgeIndex), fmtPos(s.pos), s.posSource))
			end
		end
	end
	log("==== done")
	return report
end

local function focus(pos : Vec3f)
	api.gui.camera.focusPosition(pos, 250)
end

local function showButton(text : string, pos : Vec3f) : TreeNodeId
	return builtin.Button{
		content = builtin.BoxLayout{
			children = { builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text } },
		},
		onClick = function()
			focus(pos)
		end,
	}
end

local record BodyParams
	entityId : Engine.Entity
end

local Body = react.RegisterRecipe("PgraceRailDoctorBody", function(params : BodyParams) : TreeNodeId
	local state = react.useStateLazy(function() : Report
		local ok, reportOrError = pcall(function() : Report
			return probe(params.entityId)
		end)
		if ok then
			return reportOrError as Report
		end
		log("error: " .. tostring(reportOrError))
		return { lines = { "Error (see log)" }, spots = {} }
	end)
	local report = state:old()

	local children : {TreeNodeId} = {}
	for _, line in ipairs(report.lines) do
		children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-body" }, text = line }
	end
	for _, spot in ipairs(report.spots) do
		children[#children + 1] = showButton(spot.label .. " " .. fmtPos(spot.pos), spot.pos)
		for _, s in ipairs(spot.nearest or {}) do
			children[#children + 1] = showButton(string.format("    sig type %d, %.0f m", s.kind, dist2d(s.pos, spot.pos)), s.pos)
		end
	end
	return builtin.BoxLayout{ children = children }
end)

local LinePlugin = react.RegisterPluginRecipe(line_eow.LineEowExtensionPoint, "PgraceRailDoctorLinePlugin", function(params : LineEow.LineWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = "Rail Doctor (probe)",
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(Body, { entityId = params.entityId } as BodyParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

debugPrint("[rail_doctor] script loaded")

return {
	LinePlugin = LinePlugin,
}
