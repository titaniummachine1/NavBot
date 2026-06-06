--[[
    NavPredict — straight-line nav-area path prediction
    Phase 1: portal march (full edge overlap, or door hitbox when doorsOnly)
    Phase 2: hull traces after Phase 1 succeeds
    Imported by: isNavigable, Navigation, StateHandler, NodeSkipper, IsNavigableTest
]]

local G = require("NavBot.Core.Globals")
local Common = require("NavBot.Core.Common")
local NavConstants = require("NavBot.Navigation.Prediction.NavConstants")
local NavDebug = require("NavBot.Navigation.Prediction.NavDebug")
local NavGeometry = require("NavBot.Navigation.Prediction.NavGeometry")
local NavPortal = require("NavBot.Navigation.Prediction.NavPortal")
local NavTrace = require("NavBot.Navigation.Prediction.NavTrace")

local NavPredict = {}

local MAX_ITERATIONS = NavConstants.MAX_ITERATIONS
local SLOPE_WAYPOINT_Z_DIFF = NavConstants.SLOPE_WAYPOINT_Z_DIFF

local DIR_NAMES = { [1] = "N", [2] = "E", [3] = "S", [4] = "W" }

function NavPredict.CanSkip(startPos, goalPos, startNode, doorsOnly, allowJump)
	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	NavDebug.BeginRun()

	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {}

	local startZ, startNormal = NavGeometry.GetGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	local pathLineOrigin = Vector3(currentPos.x, currentPos.y, 0)
	local pathLineDelta = Vector3(goalPos.x - pathLineOrigin.x, goalPos.y - pathLineOrigin.y, 0)
	if pathLineDelta:Length() < 0.001 then
		NavDebug.SetResult(false)
		return false
	end
	local pathLineDir = Common.Normalize(pathLineDelta)

	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = startNormal,
	})

	local visitedNodes = {}

	for _iteration = 1, MAX_ITERATIONS do
		if visitedNodes[currentNode.id] then
			NavDebug.Log(string.format("[NavPredict] FAIL: Cycle detected at node %d", currentNode.id))
			NavDebug.SavePath(waypoints)
			NavDebug.SetResult(false)
			return false
		end
		visitedNodes[currentNode.id] = true

		if NavGeometry.IsPointInNodeBounds(goalPos, currentNode) then
			local goalZ, goalNormal = NavGeometry.GetGroundZFromQuad(goalPos, currentNode)
			local goalWpPos = goalZ and Vector3(goalPos.x, goalPos.y, goalZ) or goalPos
			table.insert(waypoints, { pos = goalWpPos, node = currentNode, normal = goalNormal })
			NavDebug.Log(
				string.format(
					"[NavPredict] Phase1 SUCCESS: goal in node %d (%d waypoints) — starting Phase2",
					currentNode.id,
					#waypoints
				)
			)
			NavDebug.SavePath(waypoints)
			local navigable = NavTrace.TraceWaypoints(waypoints, allowJump)
			NavDebug.SetResult(navigable)
			return navigable
		end

		local snappedX, snappedY =
			NavGeometry.ProjectXYOntoGoalLine(currentPos.x, currentPos.y, pathLineOrigin, pathLineDir)
		local groundZ, _groundNormal =
			NavGeometry.GetGroundZFromQuad(Vector3(snappedX, snappedY, currentPos.z), currentNode)
		if groundZ then
			currentPos = Vector3(snappedX, snappedY, groundZ)
		else
			currentPos = Vector3(snappedX, snappedY, currentPos.z)
		end

		local exitPoint, _exitDist, exitDir = NavGeometry.FindNodeExit(currentPos, pathLineDir, currentNode)
		if exitPoint then
			local exitZ = NavGeometry.GetGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				exitPoint = Vector3(exitPoint.x, exitPoint.y, exitZ)
			end
		end

		if not exitPoint or not exitDir then
			NavDebug.Log(string.format("[NavPredict] FAIL: No exit found from node %d", currentNode.id))
			NavDebug.SavePath(waypoints)
			NavDebug.SaveFail(currentPos, currentPos + pathLineDir * 50)
			NavDebug.SetResult(false)
			return false
		end

		NavDebug.Log(
			string.format(
				"[NavPredict] Exit via %s at (%.1f, %.1f)",
				DIR_NAMES[exitDir] or "?",
				exitPoint.x,
				exitPoint.y
			)
		)

		local neighborNode, snappedExit =
			NavPortal.FindNeighborAtExit(currentNode, exitPoint, exitDir, nodes, doorsOnly == true)
		if snappedExit then
			exitPoint = snappedExit
			local exitZ = NavGeometry.GetGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				exitPoint = Vector3(exitPoint.x, exitPoint.y, exitZ)
			end
		end
		if not neighborNode then
			NavDebug.SavePath(waypoints)
			NavDebug.SaveFail(currentPos, exitPoint)
			NavDebug.SetResult(false)
			return false
		end

		local entryX, entryY = NavGeometry.ProjectXYOntoGoalLine(exitPoint.x, exitPoint.y, pathLineOrigin, pathLineDir)
		local entryZ, entryNormal = NavGeometry.GetGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)
		if not entryZ then
			NavDebug.Log(string.format("[NavPredict] FAIL: No ground geometry at entry to node %d", neighborNode.id))
			NavDebug.SavePath(waypoints)
			NavDebug.SaveFail(currentPos, exitPoint)
			NavDebug.SetResult(false)
			return false
		end

		local entryPos = Vector3(entryX, entryY, entryZ)
		local zDiff = math.abs(entryZ - currentPos.z)
		if zDiff > SLOPE_WAYPOINT_Z_DIFF then
			local exitZ = NavGeometry.GetGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				local exitPos = Vector3(exitPoint.x, exitPoint.y, exitZ)
				local _, exitNormal = NavGeometry.GetGroundZFromQuad(exitPoint, currentNode)
				table.insert(waypoints, { pos = exitPos, node = currentNode, normal = exitNormal })
				NavDebug.Log(string.format("[NavPredict] Added slope waypoint at exit (Z=%.1f)", exitZ))
			end
		end

		table.insert(waypoints, { pos = entryPos, node = neighborNode, normal = entryNormal })
		NavDebug.Log(string.format("[NavPredict] Crossed to node %d (Z=%.1f)", neighborNode.id, entryZ))

		currentPos = entryPos
		currentNode = neighborNode
	end

	NavDebug.Log(string.format("[NavPredict] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	NavDebug.SavePath(waypoints)
	NavDebug.SetResult(false)
	return false
end

function NavPredict.GetDebugWaypoints()
	return NavDebug.GetWaypoints()
end

function NavPredict.GetDebugHullTraceCount()
	return NavDebug.GetHullTraceCount()
end

function NavPredict.SetDebugResult(isNavigable)
	NavDebug.SetResult(isNavigable)
end

function NavPredict.DrawDebugTraces()
	NavDebug.Draw()
end

function NavPredict.SetDebug(enabled)
	NavDebug.SetEnabled(enabled)
end

return NavPredict
