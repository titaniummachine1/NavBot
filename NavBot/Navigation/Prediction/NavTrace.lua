--[[ Imported by: NavPredict ]]

local G = require("NavBot.Core.Globals")
local NavConstants = require("NavBot.Navigation.Prediction.NavConstants")
local NavDebug = require("NavBot.Navigation.Prediction.NavDebug")

local NavTrace = {}

local PLAYER_HULL = NavConstants.PLAYER_HULL
local STEP_HEIGHT = NavConstants.STEP_HEIGHT
local JUMP_HEIGHT = NavConstants.JUMP_HEIGHT

local engineTraceHull = engine.TraceHull

local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

local function runTraceHull(startPos, endPos)
	if NavDebug.IsEnabled() then
		local result =
			engineTraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
		NavDebug.RecordHullTrace(startPos, result.endpos, result.fraction < 0.999)
		return result
	end
	return engineTraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

local function traceOneBigSegment(startPos, endPos, _startNormal, allowJump)
	local toTarget = endPos - startPos
	if toTarget:Length() < 0.001 then
		return true
	end

	local horizDist = math.sqrt(toTarget.x * toTarget.x + toTarget.y * toTarget.y)
	if horizDist < 0.001 then
		return math.abs(toTarget.z) <= (allowJump and JUMP_HEIGHT or STEP_HEIGHT) + 8
	end

	local stepHeights = allowJump and { STEP_HEIGHT, JUMP_HEIGHT } or { STEP_HEIGHT }
	for stepIndex = 1, #stepHeights do
		local stepVec = Vector3(0, 0, stepHeights[stepIndex])
		local trace = runTraceHull(startPos + stepVec, endPos + stepVec)
		if trace.fraction >= 0.999 then
			return true
		end
		if stepIndex < #stepHeights then
			NavDebug.Log(
				string.format("[NavPredict] Segment blocked at step %d, trying jump...", stepHeights[stepIndex])
			)
		end
	end

	return false
end

local function getWaypointNodeId(waypoint)
	if waypoint.node and waypoint.node.id then
		return waypoint.node.id
	end
	return nil
end

function NavTrace.TraceWaypoints(waypoints, allowJump)
	local traceCount = 0
	local index = 1

	while index <= #waypoints do
		local nodeId = getWaypointNodeId(waypoints[index])
		local nodeStartIndex = index
		local nodeEndIndex = index

		while nodeEndIndex < #waypoints do
			local nextNodeId = getWaypointNodeId(waypoints[nodeEndIndex + 1])
			if nextNodeId ~= nodeId then
				break
			end
			nodeEndIndex = nodeEndIndex + 1
		end

		local fromWp = waypoints[nodeStartIndex]
		local toWp = waypoints[nodeEndIndex]

		NavDebug.Log(
			string.format(
				"[NavPredict] Phase2 node trace %s -> %s (node %s)",
				tostring(nodeStartIndex),
				tostring(nodeEndIndex),
				tostring(nodeId)
			)
		)

		if not traceOneBigSegment(fromWp.pos, toWp.pos, fromWp.normal, allowJump) then
			NavDebug.Log(string.format("[NavPredict] FAIL: Phase2 node %s segment blocked", tostring(nodeId)))
			NavDebug.SaveFail(fromWp.pos, toWp.pos)
			return false
		end
		traceCount = traceCount + 1

		if nodeEndIndex < #waypoints then
			local nextWp = waypoints[nodeEndIndex + 1]
			local nextNodeId = getWaypointNodeId(nextWp)
			if nextNodeId ~= nodeId then
				NavDebug.Log(
					string.format("[NavPredict] Phase2 boundary trace %s -> %s", tostring(nodeId), tostring(nextNodeId))
				)

				if not traceOneBigSegment(toWp.pos, nextWp.pos, toWp.normal, allowJump) then
					NavDebug.Log(
						string.format(
							"[NavPredict] FAIL: Phase2 boundary %s -> %s blocked",
							tostring(nodeId),
							tostring(nextNodeId)
						)
					)
					NavDebug.SaveFail(toWp.pos, nextWp.pos)
					return false
				end
				traceCount = traceCount + 1
			end
		end

		index = nodeEndIndex + 1
	end

	NavDebug.Log(string.format("[NavPredict] Phase2 SUCCESS: %d hull traces (%d waypoints)", traceCount, #waypoints))
	return true
end

return NavTrace
