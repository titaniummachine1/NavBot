--[[ Imported by: NavPredict ]]

local NavConstants = require("NavBot.Navigation.Prediction.NavConstants")
local NavDebug = require("NavBot.Navigation.Prediction.NavDebug")

local NavPortal = {}

local OPPOSITE_EXIT_DIR = NavConstants.OPPOSITE_EXIT_DIR
local DOOR_HALF_WIDTH = NavConstants.DOOR_HALF_WIDTH
local DOOR_SNAP_TOLERANCE = NavConstants.DOOR_SNAP_TOLERANCE

local function isAreaNode(node)
	return node and node._minX and node._maxX and node._minY and node._maxY
end

local function getConnectionId(connection)
	if type(connection) == "table" then
		return connection.node or connection.id
	end
	return connection
end

local function getFacingEdgeSpan(area, exitDir)
	local nw, ne, sw, se = area.nw, area.ne, area.sw, area.se
	if nw and ne and sw and se then
		if exitDir == 2 then
			return math.min(ne.y, se.y), math.max(ne.y, se.y)
		elseif exitDir == 4 then
			return math.min(nw.y, sw.y), math.max(nw.y, sw.y)
		elseif exitDir == 3 then
			return math.min(sw.x, se.x), math.max(sw.x, se.x)
		elseif exitDir == 1 then
			return math.min(nw.x, ne.x), math.max(nw.x, ne.x)
		end
	end

	if exitDir == 2 or exitDir == 4 then
		return area._minY, area._maxY
	end
	return area._minX, area._maxX
end

function NavPortal.GetSharedPortalSpan(currentNode, neighborNode, exitDir)
	local aMin, aMax = getFacingEdgeSpan(currentNode, exitDir)
	local oppDir = OPPOSITE_EXIT_DIR[exitDir]
	local bMin, bMax = getFacingEdgeSpan(neighborNode, oppDir)
	local portalMin = math.max(aMin, bMin)
	local portalMax = math.min(aMax, bMax)
	if portalMax <= portalMin then
		return nil, nil
	end
	return portalMin, portalMax
end

local function getSharedAxisCoord(point, exitDir)
	if exitDir == 2 or exitDir == 4 then
		return point.y
	end
	return point.x
end

local function setSharedAxisCoord(point, exitDir, coord)
	if exitDir == 2 or exitDir == 4 then
		return Vector3(point.x, coord, point.z)
	end
	return Vector3(coord, point.y, point.z)
end

local function isExitInPortal(exitPoint, exitDir, portalMin, portalMax)
	local coord = getSharedAxisCoord(exitPoint, exitDir)
	return coord >= portalMin and coord <= portalMax
end

local function distanceToSpan(coord, portalMin, portalMax)
	if coord < portalMin then
		return portalMin - coord
	end
	if coord > portalMax then
		return coord - portalMax
	end
	return 0
end

local function clampToSpan(coord, portalMin, portalMax)
	if coord < portalMin then
		return portalMin
	end
	if coord > portalMax then
		return portalMax
	end
	return coord
end

local function getDoorPortalSpan(doorNode, exitDir)
	if not doorNode or not doorNode.pos then
		return nil, nil
	end
	local center = getSharedAxisCoord(doorNode.pos, exitDir)
	return center - DOOR_HALF_WIDTH, center + DOOR_HALF_WIDTH
end

local function resolveConnectionToNeighborArea(connection, currentNodeId, nodes)
	local targetId = getConnectionId(connection)
	local target = nodes[targetId]
	if not target then
		return nil
	end

	if target.isDoor then
		if target.areaId == currentNodeId then
			return nodes[target.targetAreaId]
		end
		if target.targetAreaId == currentNodeId then
			return nodes[target.areaId]
		end
	end

	if isAreaNode(target) then
		if target.id ~= currentNodeId then
			return target
		end
		return nil
	end

	local pair = string.match(tostring(targetId), "^(%d+_%d+)_")
	if pair then
		local areaA, areaB = string.match(pair, "^(%d+)_(%d+)$")
		if areaA and areaB then
			areaA = tonumber(areaA)
			areaB = tonumber(areaB)
			if areaA == currentNodeId then
				return nodes[areaB]
			end
			if areaB == currentNodeId then
				return nodes[areaA]
			end
		end
	end

	return nil
end

local function logPortalResult(exitCoord, exitDir, neighborArea, portalMin, portalMax, doorsOnly, doorId)
	if doorsOnly and doorId then
		NavDebug.Log(
			string.format(
				"[NavPredict]   Door portal dir=%d door=%s area=%d: coord=%.1f span=[%.1f,%.1f]",
				exitDir,
				tostring(doorId),
				neighborArea.id,
				exitCoord,
				portalMin,
				portalMax
			)
		)
	else
		NavDebug.Log(
			string.format(
				"[NavPredict]   Edge portal dir=%d area=%d: coord=%.1f portal=[%.1f,%.1f]",
				exitDir,
				neighborArea.id,
				exitCoord,
				portalMin,
				portalMax
			)
		)
	end
end

local function collectDoorCandidates(currentNode, exitDir, nodes)
	local dirData = currentNode.c[exitDir]
	if not dirData or not dirData.connections then
		return {}
	end

	local candidates = {}
	for i = 1, #dirData.connections do
		local connection = dirData.connections[i]
		local connectionId = getConnectionId(connection)
		local doorNode = nodes[connectionId]
		if doorNode and doorNode.isDoor then
			local neighborArea = resolveConnectionToNeighborArea(connection, currentNode.id, nodes)
			local portalMin, portalMax = getDoorPortalSpan(doorNode, exitDir)
			if neighborArea and portalMin then
				candidates[#candidates + 1] = {
					connectionId = connectionId,
					neighborArea = neighborArea,
					portalMin = portalMin,
					portalMax = portalMax,
				}
			end
		end
	end
	return candidates
end

local function findDoorNeighbor(currentNode, exitPoint, exitDir, nodes, exitCoord)
	local candidates = collectDoorCandidates(currentNode, exitDir, nodes)
	if #candidates == 0 then
		return nil, nil
	end

	for i = 1, #candidates do
		local candidate = candidates[i]
		NavDebug.RecordPortalSpan(currentNode, exitDir, candidate.portalMin, candidate.portalMax, true)
		if isExitInPortal(exitPoint, exitDir, candidate.portalMin, candidate.portalMax) then
			logPortalResult(
				exitCoord,
				exitDir,
				candidate.neighborArea,
				candidate.portalMin,
				candidate.portalMax,
				true,
				candidate.connectionId
			)
			return candidate.neighborArea, nil
		end
	end

	local bestCandidate = nil
	local bestDistance = math.huge
	for i = 1, #candidates do
		local candidate = candidates[i]
		local distance = distanceToSpan(exitCoord, candidate.portalMin, candidate.portalMax)
		if distance < bestDistance then
			bestDistance = distance
			bestCandidate = candidate
		end
	end

	if bestCandidate and bestDistance <= DOOR_SNAP_TOLERANCE then
		local snappedCoord = clampToSpan(exitCoord, bestCandidate.portalMin, bestCandidate.portalMax)
		local snappedExit = setSharedAxisCoord(exitPoint, exitDir, snappedCoord)
		NavDebug.Log(
			string.format(
				"[NavPredict]   Door snap dir=%d door=%s area=%d: %.1f -> %.1f (dist=%.1f) span=[%.1f,%.1f]",
				exitDir,
				tostring(bestCandidate.connectionId),
				bestCandidate.neighborArea.id,
				exitCoord,
				snappedCoord,
				bestDistance,
				bestCandidate.portalMin,
				bestCandidate.portalMax
			)
		)
		return bestCandidate.neighborArea, snappedExit
	end

	for i = 1, #candidates do
		local candidate = candidates[i]
		NavDebug.Log(
			string.format(
				"[NavPredict]   Skip door=%s area=%d: coord=%.1f outside [%.1f,%.1f]",
				tostring(candidate.connectionId),
				candidate.neighborArea.id,
				exitCoord,
				candidate.portalMin,
				candidate.portalMax
			)
		)
	end
	return nil, nil
end

local function tryEdgePortal(currentNode, exitPoint, exitDir, nodes, connection, exitCoord, checkedNeighborIds)
	local neighborArea = resolveConnectionToNeighborArea(connection, currentNode.id, nodes)
	if not neighborArea or checkedNeighborIds[neighborArea.id] then
		return nil
	end
	checkedNeighborIds[neighborArea.id] = true

	local portalMin, portalMax = NavPortal.GetSharedPortalSpan(currentNode, neighborArea, exitDir)
	if not portalMin then
		return nil
	end

	NavDebug.RecordPortalSpan(currentNode, exitDir, portalMin, portalMax, false)

	if isExitInPortal(exitPoint, exitDir, portalMin, portalMax) then
		logPortalResult(exitCoord, exitDir, neighborArea, portalMin, portalMax, false, nil)
		return neighborArea
	end

	NavDebug.Log(
		string.format(
			"[NavPredict]   Skip area=%d: coord=%.1f outside [%.1f,%.1f]",
			neighborArea.id,
			exitCoord,
			portalMin,
			portalMax
		)
	)
	return nil
end

function NavPortal.FindNeighborAtExit(currentNode, exitPoint, exitDir, nodes, doorsOnly)
	local dirData = currentNode.c[exitDir]
	if not dirData or not dirData.connections then
		return nil, nil
	end

	local exitCoord = getSharedAxisCoord(exitPoint, exitDir)

	if doorsOnly then
		local neighborArea, snappedExit = findDoorNeighbor(currentNode, exitPoint, exitDir, nodes, exitCoord)
		if neighborArea then
			return neighborArea, snappedExit
		end
		NavDebug.Log(
			string.format("[NavPredict] FAIL: coord %.1f not in any door portal on dir %d (wall)", exitCoord, exitDir)
		)
		return nil, nil
	end

	local checkedNeighborIds = {}
	for i = 1, #dirData.connections do
		local connection = dirData.connections[i]
		local neighborArea =
			tryEdgePortal(currentNode, exitPoint, exitDir, nodes, connection, exitCoord, checkedNeighborIds)
		if neighborArea then
			return neighborArea, nil
		end
	end

	NavDebug.Log(string.format("[NavPredict] FAIL: coord %.1f not in any portal on dir %d (wall)", exitCoord, exitDir))
	return nil, nil
end

return NavPortal
