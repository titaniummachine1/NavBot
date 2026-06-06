--[[ Imported by: NavPortal, NavTrace, NavPredict, isNavigable ]]

local Common = require("NavBot.Core.Common")

local NavDebug = {}

local enabled = false
local hullTraces = {}
local portalSpans = {}
local debugWaypoints = nil
local debugLastResult = nil
local debugFailLine = nil

local function isLogMuted()
	return engine.Con_IsVisible() or engine.IsGameUIVisible()
end

function NavDebug.IsEnabled()
	return enabled
end

function NavDebug.SetEnabled(value)
	enabled = value == true
	if not enabled then
		hullTraces = {}
		portalSpans = {}
		debugWaypoints = nil
		debugLastResult = nil
		debugFailLine = nil
	end
end

function NavDebug.Log(message)
	if not enabled or isLogMuted() then
		return
	end
	print(message)
end

function NavDebug.BeginRun()
	if not enabled then
		return
	end
	hullTraces = {}
	portalSpans = {}
	debugFailLine = nil
end

function NavDebug.SavePath(waypoints)
	if not enabled then
		return
	end
	local snapshot = {}
	for i = 1, #waypoints do
		local wp = waypoints[i]
		snapshot[i] = {
			pos = wp.pos,
			nodeId = wp.node and wp.node.id or nil,
		}
	end
	debugWaypoints = snapshot
end

function NavDebug.SetResult(isNavigable)
	if enabled then
		debugLastResult = isNavigable == true
	end
end

function NavDebug.SaveFail(fromPos, toPos)
	if not enabled or not fromPos or not toPos then
		return
	end
	debugFailLine = { from = fromPos, to = toPos }
end

function NavDebug.RecordPortalSpan(currentNode, exitDir, portalMin, portalMax, isDoorPortal)
	if not enabled or not currentNode then
		return
	end
	table.insert(portalSpans, {
		node = currentNode,
		exitDir = exitDir,
		portalMin = portalMin,
		portalMax = portalMax,
		isDoorPortal = isDoorPortal == true,
	})
end

function NavDebug.RecordHullTrace(startPos, endPos, blocked)
	if not enabled then
		return
	end
	table.insert(hullTraces, {
		startPos = startPos,
		endPos = endPos,
		blocked = blocked,
	})
end

function NavDebug.GetWaypoints()
	return debugWaypoints
end

function NavDebug.GetHullTraceCount()
	return #hullTraces
end

local function drawWorldLine(a, b, r, g, b, a)
	draw.Color(r, g, b, a)
	local w2sA = client.WorldToScreen(a)
	local w2sB = client.WorldToScreen(b)
	if w2sA and w2sB then
		draw.Line(w2sA[1], w2sA[2], w2sB[1], w2sB[2])
	end
end

local function getPathDrawColor(isNavigable)
	if isNavigable then
		return 0, 255, 0, 255
	end
	return 255, 0, 0, 255
end

function NavDebug.Draw()
	if not enabled then
		return
	end

	if debugWaypoints and #debugWaypoints >= 1 and debugLastResult ~= nil then
		local pathR, pathG, pathB, pathA = getPathDrawColor(debugLastResult)

		for i = 1, #debugWaypoints - 1 do
			local a = debugWaypoints[i].pos
			local b = debugWaypoints[i + 1].pos
			if a and b then
				Common.DrawArrowLine(a, b, 8, 14, false, pathR, pathG, pathB, pathA)
			end
		end

		for i = 1, #debugWaypoints do
			local wp = debugWaypoints[i]
			if wp.pos then
				drawWorldLine(wp.pos, wp.pos + Vector3(0, 0, 20), pathR, pathG, pathB, pathA)
			end
		end
	end

	if debugFailLine and debugFailLine.from and debugFailLine.to then
		Common.DrawArrowLine(debugFailLine.from, debugFailLine.to, 12, 22, false, 255, 0, 0, 255)
		drawWorldLine(debugFailLine.to, debugFailLine.to + Vector3(0, 0, 32), 255, 0, 0, 255)
	end

	for _, portal in ipairs(portalSpans) do
		local node = portal.node
		local z = node.pos and node.pos.z or 0
		local wallPos
		if portal.exitDir == 2 then
			wallPos = node._maxX
		elseif portal.exitDir == 4 then
			wallPos = node._minX
		elseif portal.exitDir == 3 then
			wallPos = node._maxY
		else
			wallPos = node._minY
		end

		local portalR, portalG, portalB, portalA
		if portal.isDoorPortal then
			portalR, portalG, portalB, portalA = 255, 200, 0, 255
		else
			portalR, portalG, portalB, portalA = 0, 200, 255, 255
		end

		local a
		local b
		if portal.exitDir == 2 or portal.exitDir == 4 then
			a = Vector3(wallPos, portal.portalMin, z)
			b = Vector3(wallPos, portal.portalMax, z)
		else
			a = Vector3(portal.portalMin, wallPos, z)
			b = Vector3(portal.portalMax, wallPos, z)
		end
		drawWorldLine(a, b, portalR, portalG, portalB, portalA)
	end

	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			local traceR, traceG, traceB, traceA
			if trace.blocked then
				traceR, traceG, traceB, traceA = 255, 0, 0, 255
			else
				traceR, traceG, traceB, traceA = 0, 80, 255, 255
			end
			Common.DrawArrowLine(
				trace.startPos,
				trace.endPos - Vector3(0, 0, 0.5),
				10,
				20,
				false,
				traceR,
				traceG,
				traceB,
				traceA
			)
		end
	end
end

return NavDebug
