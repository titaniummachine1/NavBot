--[[
    PathStringPull — process A* area path once after search (Unity-style string pull)
    Built once from player position at path-find time; runtime only walks cached apexes.
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local NavMath = require("NavBot.Utils.NavMath")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local ConnectionUtils = require("NavBot.Navigation.ConnectionUtils")
local GroundMovement = require("NavBot.Bot.GroundMovement")
local NavConstants = require("NavBot.Navigation.Prediction.NavConstants")
local NavGeometry = require("NavBot.Navigation.Prediction.NavGeometry")
local NavPortal = require("NavBot.Navigation.Prediction.NavPortal")
local Node = require("NavBot.Navigation.Node")

local OPPOSITE_EXIT_DIR = NavConstants.OPPOSITE_EXIT_DIR
local DROP_Z_THRESHOLD = NavConstants.STEP_HEIGHT

local PathStringPull = {}

-- String-pull uses door hitbox portals (same as NavPredict doorsOnly mode)
local STRING_PULL_DOORS_ONLY = true

local WALL_BAND = 32
local APEX_TOUCH = 16
local PORTAL_PLANE_MARGIN = 8
-- One tolerance for portal shared-axis checks (walk, skip, pass) — avoids per-case drift
local PORTAL_SPAN_TOLERANCE = 24
local APPROACH_STEP = 16
local MAX_APPROACH_BACK = 400
local DROP_WALK_OFF = 64

local apexAdvanceTick = -1

local horizontalDir = NavMath.horizontalDir2D
local horizontalUnit = NavMath.horizontalUnit2D
local getSharedAxisCoord = NavMath.sharedAxisCoord

local function getPassDirDotThreshold()
	return G.Misc.NodePassDirDotThreshold or 0.5
end

local function getTouchDistance()
	return G.Misc.NodeTouchDistance or APEX_TOUCH
end

local function getNodeTouchHeight()
	return G.Misc.NodeTouchHeight or 82
end

local function getOvershootTouchDistance()
	return G.Misc.NodeOvershootTouchDistance or 48
end

local function getGroundZOnNode(pos, node)
	if not node.nw or not node.ne or not node.sw then
		return node._floorZ or node.pos.z
	end

	local nw, ne, sw, se = node.nw, node.ne, node.sw, node.se
	local dx = pos.x - nw.x
	local dy = pos.y - nw.y
	local dxNe = ne.x - nw.x
	local dySe = se.y - nw.y
	local inTri1 = (dxNe ~= 0 or dySe ~= 0) and (dx / dxNe + dy / dySe) <= 1.0

	local v0, v1, v2 = nw, ne, se
	if not inTri1 then
		v0, v1, v2 = nw, se, sw
	end

	local denom = (v1.y - v2.y) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.y - v2.y)
	if math.abs(denom) < 0.0001 then
		return v0.z
	end

	local w0 = ((v1.y - v2.y) * (pos.x - v2.x) + (v2.x - v1.x) * (pos.y - v2.y)) / denom
	local w1 = ((v2.y - v0.y) * (pos.x - v2.x) + (v0.x - v2.x) * (pos.y - v2.y)) / denom
	local w2 = 1.0 - w0 - w1
	return w0 * v0.z + w1 * v1.z + w2 * v2.z
end

local function withGroundZ(point, node)
	if not point or not node then
		return point
	end
	return Vector3(point.x, point.y, getGroundZOnNode(point, node))
end

local function getClosestWallDir(area, point)
	if not area or not point or not area._minX then
		return nil
	end

	local bestDir = nil
	local bestDist = math.huge
	local walls = {
		[1] = math.abs(point.y - area._minY),
		[3] = math.abs(point.y - area._maxY),
		[2] = math.abs(point.x - area._maxX),
		[4] = math.abs(point.x - area._minX),
	}

	for dir, dist in pairs(walls) do
		if dist < bestDist then
			bestDist = dist
			bestDir = dir
		end
	end

	return bestDir
end

local function getEntryDirIntoArea(prevArea, area, entryPoint)
	if prevArea then
		local connDir = NavPortal.GetExitDirToNeighbor(prevArea, area)
		if connDir then
			return OPPOSITE_EXIT_DIR[connDir]
		end
	end

	if entryPoint and area then
		return getClosestWallDir(area, entryPoint)
	end

	return nil
end

local function needsCenterForSameSideEntry(entryDir, exitDir)
	return entryDir and exitDir and entryDir == exitDir
end

local function getExitDirBetween(area, nextArea)
	local exitDir = NavPortal.GetExitDirToNeighbor(area, nextArea)
	if exitDir then
		return exitDir
	end

	-- Fallback only when graph lookup fails (should not happen on a valid A* segment)
	local dir = horizontalDir(area.pos, nextArea.pos)
	if not dir then
		return nil
	end
	local _exitPt, _dist, fallbackDir = NavGeometry.FindNodeExit(area.pos, dir, area)
	return fallbackDir
end

local function hasDoorOnExitEdge(area, exitDir)
	if not exitDir or not area.c then
		return false
	end

	local nodes = G.Navigation and G.Navigation.nodes
	if not nodes then
		return false
	end

	local dirData = area.c[exitDir]
	if not dirData or not dirData.connections then
		return false
	end

	for i = 1, #dirData.connections do
		local targetId = ConnectionUtils.GetNodeId(dirData.connections[i])
		local target = nodes[targetId]
		if target and target.isDoor then
			return true
		end
	end

	return false
end

local function isOnExitWall(point, area, exitDir)
	if not point or not area._minX or not exitDir then
		return false
	end

	if exitDir == 3 then
		return point.y >= area._maxY - WALL_BAND
	end
	if exitDir == 1 then
		return point.y <= area._minY + WALL_BAND
	end
	if exitDir == 2 then
		return point.x >= area._maxX - WALL_BAND
	end
	if exitDir == 4 then
		return point.x <= area._minX + WALL_BAND
	end

	return false
end

local function clampPortalCoord(coord, portalMin, portalMax)
	if coord < portalMin then
		return portalMin
	end
	if coord > portalMax then
		return portalMax
	end
	return coord
end

local function buildPortalPosFromSpan(area, exitDir, portalMin, portalMax, biasPointOrCoord)
	if not exitDir or not portalMin or not portalMax then
		return nil
	end

	local coord = (portalMin + portalMax) * 0.5
	if type(biasPointOrCoord) == "number" then
		coord = biasPointOrCoord
	elseif biasPointOrCoord then
		coord = clampPortalCoord(getSharedAxisCoord(biasPointOrCoord, exitDir), portalMin, portalMax)
	end
	local x
	local y
	local z = area.pos.z

	if exitDir == 2 then
		x = area._maxX
		y = coord
	elseif exitDir == 4 then
		x = area._minX
		y = coord
	elseif exitDir == 3 then
		x = coord
		y = area._maxY
	else
		x = coord
		y = area._minY
	end

	return withGroundZ(Vector3(x, y, z), area)
end

local function getNearestPortalPosOnSpan(playerPos, area, exitDir, portalMin, portalMax)
	if not (playerPos and area and exitDir and portalMin and portalMax) then
		return nil
	end

	local coord = clampPortalCoord(getSharedAxisCoord(playerPos, exitDir), portalMin, portalMax)
	return buildPortalPosFromSpan(area, exitDir, portalMin, portalMax, coord)
end

local function isSmartJumpActive()
	local jumpState = G.SmartJump and G.SmartJump.jumpState
	local idleState = G.SmartJump and G.SmartJump.Constants and G.SmartJump.Constants.STATE_IDLE
	if jumpState and idleState and jumpState ~= idleState then
		return true
	end
	return false
end

local function getPathNodeById(nodeId)
	local nodes = G.Navigation and G.Navigation.nodes
	if not nodes or not nodeId then
		return nil
	end
	return nodes[nodeId]
end

local function getSegmentDropHeight(area, nextArea, portalPos)
	if not (area and nextArea and portalPos) then
		return 0
	end

	local fromZ = getGroundZOnNode(portalPos, area)
	local toZ = getGroundZOnNode(nextArea.pos, nextArea) or nextArea._floorZ or nextArea.pos.z
	if not fromZ or not toZ then
		return 0
	end

	return fromZ - toZ
end

local function wouldExitOutsideDoorPortal(fromPoint, area, portalPos, exitDir, portalMin, portalMax)
	if not (portalMin and portalMax and portalPos and exitDir) then
		return false
	end

	local dir = horizontalDir(fromPoint, portalPos)
	if not dir then
		return false
	end

	local exitPt, _exitDist, foundExitDir = NavGeometry.FindNodeExit(fromPoint, dir, area)
	if not exitPt or foundExitDir ~= exitDir then
		return true
	end

	local coord = getSharedAxisCoord(exitPt, exitDir)
	return coord < portalMin or coord > portalMax
end

--- Need an in-area approach point before portal when a straight walk would miss the opening.
local function needsApproachBeforePortal(fromPoint, area, _nextArea, exitDir, portalMin, portalMax, portalPos)
	if not (portalMin and portalMax and portalPos and exitDir) then
		return false
	end
	if wouldExitOutsideDoorPortal(fromPoint, area, portalPos, exitDir, portalMin, portalMax) then
		return true
	end
	if hasDoorOnExitEdge(area, exitDir) and isOnExitWall(fromPoint, area, exitDir) then
		return true
	end
	return false
end

--- Build-time approach point along the portal line (never area geometric center).
local function computeApproachPoint(fromPoint, area, portalPos, exitDir, portalMin, portalMax)
	local dir = horizontalDir(fromPoint, portalPos)
	if not dir then
		return nil
	end

	local bestOnWall = nil
	for back = APPROACH_STEP, MAX_APPROACH_BACK, APPROACH_STEP do
		local candidate = Vector3(
			portalPos.x - dir.x * back,
			portalPos.y - dir.y * back,
			portalPos.z
		)
		if not AreaSpatial.IsWithinArea(candidate, area) then
			break
		end

		if wouldExitOutsideDoorPortal(candidate, area, portalPos, exitDir, portalMin, portalMax) then
			break
		end

		local grounded = withGroundZ(candidate, area)
		local onWall = hasDoorOnExitEdge(area, exitDir) and isOnExitWall(grounded, area, exitDir)
		if not onWall then
			return grounded
		end
		bestOnWall = grounded
	end

	return bestOnWall
end

local function isApproachKind(kind)
	return kind == "approach" or kind == "center" or kind == "same_side_center"
end

local function isTransitionKind(kind)
	return kind == "portal" or kind == "drop"
end

local function findSegmentTransitionApex(currentId, nextId)
	local apexes = G.Navigation.apexPath
	if not apexes then
		return nil
	end

	for i = 1, #apexes do
		local apex = apexes[i]
		if isTransitionKind(apex.kind) and apex.areaId == currentId and apex.nextAreaId == nextId then
			return apex, i
		end
	end

	return nil
end

local function hasPassedApproachApex(playerPos, apex)
	if not (apex and apex.pos) then
		return false
	end

	return Common.Distance2D(playerPos, apex.pos) <= getTouchDistance()
end

local function apexIsForCurrentSegment(apex, path)
	if not apex or not path or not path[1] then
		return false
	end

	if apex.kind == "goal" then
		return #path <= 1
	end

	if not path[2] then
		return apex.areaId == path[1].id
	end

	if apex.areaId ~= path[1].id then
		return false
	end

	if apex.nextAreaId and apex.nextAreaId ~= path[2].id then
		return false
	end

	return true
end

local function getApexIndexForCurrentSegment(apexes, path)
	if not apexes or #apexes == 0 or not path or not path[1] then
		return 1
	end

	if not path[2] then
		for i = 1, #apexes do
			if apexes[i].kind == "goal" then
				return i
			end
		end
		return #apexes
	end

	for i = 1, #apexes do
		if apexIsForCurrentSegment(apexes[i], path) then
			return i
		end
	end

	return 1
end

local function getPortalPoint(area, nextArea, exitDir)
	if not exitDir then
		return withGroundZ(nextArea.pos, area)
	end

	local portalMin, portalMax =
		NavPortal.GetPortalSpanForNeighbor(area, nextArea, exitDir, STRING_PULL_DOORS_ONLY)
	if not portalMin then
		return withGroundZ(nextArea.pos, area)
	end

	return buildPortalPosFromSpan(area, exitDir, portalMin, portalMax, nextArea.pos)
end

local function isCoordInPortalSpan(coord, portalMin, portalMax, tolerance)
	return NavMath.isCoordInSpan(coord, portalMin, portalMax, tolerance or PORTAL_SPAN_TOLERANCE)
end

local function isWithinPortalSpan(playerPos, exitDir, portalMin, portalMax, tolerance)
	if not exitDir or not portalMin or not portalMax then
		return false
	end
	return isCoordInPortalSpan(getSharedAxisCoord(playerPos, exitDir), portalMin, portalMax, tolerance)
end

local function isDropLikeSegment(apex, currentNode)
	if not apex then
		return false
	end
	if apex.kind == "drop" then
		return true
	end
	if not (currentNode and apex.nextAreaId and apex.pos) then
		return false
	end
	local nextNode = getPathNodeById(apex.nextAreaId)
	if not nextNode then
		return false
	end
	return getSegmentDropHeight(currentNode, nextNode, apex.pos) > DROP_Z_THRESHOLD
end

local function getSteerPosForApex(playerPos, apex, currentNode)
	if not (apex and apex.pos) then
		return nil
	end

	if not isDropLikeSegment(apex, currentNode) or not (apex.portalMin and apex.portalMax and apex.exitDir and currentNode) then
		return apex.pos
	end

	local nearest = getNearestPortalPosOnSpan(playerPos, currentNode, apex.exitDir, apex.portalMin, apex.portalMax)
	if not nearest then
		return apex.pos
	end

	local nearEdge = Common.Distance2D(playerPos, nearest) <= getOvershootTouchDistance()
		and isWithinPortalSpan(playerPos, apex.exitDir, apex.portalMin, apex.portalMax, PORTAL_SPAN_TOLERANCE)

	if nearEdge and apex.passDir then
		return Vector3(
			nearest.x + apex.passDir.x * DROP_WALK_OFF,
			nearest.y + apex.passDir.y * DROP_WALK_OFF,
			nearest.z
		)
	end

	return nearest
end

local function getSegmentPortalData(currentNode, nextNode)
	local exitDir = getExitDirBetween(currentNode, nextNode)
	if not exitDir then
		return nil
	end
	local portalMin, portalMax =
		NavPortal.GetPortalSpanForNeighbor(currentNode, nextNode, exitDir, STRING_PULL_DOORS_ONLY)
	local portalPos = getPortalPoint(currentNode, nextNode, exitDir)
	return {
		exitDir = exitDir,
		portalMin = portalMin,
		portalMax = portalMax,
		portalPos = portalPos,
	}
end

local function resolvePortalSpan(portalApex, currentNode, nextNode)
	local exitDir = portalApex.exitDir or getExitDirBetween(currentNode, nextNode)
	local portalMin = portalApex.portalMin
	local portalMax = portalApex.portalMax
	if not portalMin and exitDir then
		portalMin, portalMax = NavPortal.GetPortalSpanForNeighbor(
			currentNode,
			nextNode,
			exitDir,
			STRING_PULL_DOORS_ONLY
		)
	end
	return exitDir, portalMin, portalMax
end

local function pushApex(apexes, pos, kind, areaId, nextAreaId, passDir, exitDir, portalMin, portalMax)
	if not pos then
		return
	end

	local last = apexes[#apexes]
	if last and Common.Distance2D(last.pos, pos) < 4 then
		return
	end

	apexes[#apexes + 1] = {
		pos = pos,
		kind = kind,
		areaId = areaId,
		nextAreaId = nextAreaId,
		passDir = passDir,
		exitDir = exitDir,
		portalMin = portalMin,
		portalMax = portalMax,
	}
end


local function hasCrossedPortalPlane(playerPos, portalPos, passDir, margin)
	if not (playerPos and portalPos and passDir) then
		return false
	end

	local dx = playerPos.x - portalPos.x
	local dy = playerPos.y - portalPos.y
	return (dx * passDir.x + dy * passDir.y) >= (margin or PORTAL_PLANE_MARGIN)
end

local function evaluatePortalPass(
	playerPos,
	portalPos,
	passDir,
	exitDir,
	portalMin,
	portalMax,
	currentNode,
	nextNode,
	apexKind
)
	local isDrop = apexKind == "drop" or (currentNode and portalPos and nextNode and getSegmentDropHeight(currentNode, nextNode, portalPos) > DROP_Z_THRESHOLD)

	if isDrop then
		if nextNode and PathStringPull.HasEnteredNextArea(playerPos, nextNode) then
			return true, "drop_landed"
		end

		local pLocal = G.pLocal and G.pLocal.entity
		if pLocal and not GroundMovement.isOnGround(pLocal) then
			if isWithinPortalSpan(playerPos, exitDir, portalMin, portalMax, PORTAL_SPAN_TOLERANCE) then
				return true, "drop_airborne"
			end
			if passDir and hasCrossedPortalPlane(playerPos, portalPos, passDir, -16) then
				return true, "drop_airborne"
			end
		end
	end

	local inNext = nextNode and PathStringPull.HasEnteredNextArea(playerPos, nextNode)
	local inCurrent = currentNode and AreaSpatial.IsWithinArea(playerPos, currentNode)

	-- Entered next area: must be near this segment's portal (stops corner overlap false-advance)
	if inNext and not inCurrent and portalPos and nextNode then
		local dist2D = Common.Distance2D(playerPos, portalPos)
		local inPortalSpan =
			isWithinPortalSpan(playerPos, exitDir, portalMin, portalMax, PORTAL_SPAN_TOLERANCE)
		if dist2D <= getOvershootTouchDistance() and inPortalSpan then
			return true, "inside_next"
		end
	end

	if not isWithinPortalSpan(playerPos, exitDir, portalMin, portalMax, PORTAL_SPAN_TOLERANCE) then
		return false, nil
	end

	local pLocal = G.pLocal and G.pLocal.entity
	local onGround = pLocal and GroundMovement.isOnGround(pLocal)
	local jumping = isSmartJumpActive()

	-- Portal plane cross claims the node while moving through at speed (ground only).
	if passDir and onGround and not jumping then
		if hasCrossedPortalPlane(playerPos, portalPos, passDir, -12) then
			return true, "portal_plane"
		end
	end

	return false, nil
end

local function hasPassedThroughPortal(playerPos, apex, currentNode)
	if not (apex and apex.pos) then
		return false
	end

	local nextNode = getPathNodeById(apex.nextAreaId)
	local passed, _reason = evaluatePortalPass(
		playerPos,
		apex.pos,
		apex.passDir,
		apex.exitDir,
		apex.portalMin,
		apex.portalMax,
		currentNode,
		nextNode,
		apex.kind
	)
	return passed
end

local function hasPassedPortalApex(playerPos, apex, currentNode)
	if not (apex and apex.pos) then
		return false
	end

	if isApproachKind(apex.kind) or apex.kind == "goal" then
		return hasPassedApproachApex(playerPos, apex)
	end

	if isTransitionKind(apex.kind) then
		return hasPassedThroughPortal(playerPos, apex, currentNode)
	end

	return false
end

function PathStringPull.IsEdgeSegment(currentNode, nextNode)
	return PathStringPull.GetSegmentPortalPos(currentNode, nextNode) ~= nil
end

function PathStringPull.GetSegmentPortalPos(area, nextArea)
	local data = getSegmentPortalData(area, nextArea)
	return data and data.portalPos or nil
end

--- Player→portal line must leave current area through the shared portal opening.
function PathStringPull.CanWalkToSegmentPortal(playerPos, currentNode, nextNode)
	if not (playerPos and currentNode and nextNode) then
		return false, nil
	end

	local data = getSegmentPortalData(currentNode, nextNode)
	if not data or not data.portalMin or not data.portalMax or not data.portalPos then
		return false, nil
	end

	local dir = horizontalDir(playerPos, data.portalPos)
	if not dir then
		return false, nil
	end

	local exitPt, _exitDist, foundExitDir = NavGeometry.FindNodeExit(playerPos, dir, currentNode)
	if not exitPt or foundExitDir ~= data.exitDir then
		return false, nil
	end

	local coord = getSharedAxisCoord(exitPt, data.exitDir)
	if not isCoordInPortalSpan(coord, data.portalMin, data.portalMax, PORTAL_SPAN_TOLERANCE) then
		return false, nil
	end

	return true, data.portalPos
end

function PathStringPull.ResetApexAdvanceTick()
	apexAdvanceTick = -1
end

--- Drop apexes for a consumed path node (runtime trim — never rebuild ProcessAreaPath).
function PathStringPull.ConsumeNodeApexes(consumedNodeId)
	local apexes = G.Navigation.apexPath
	if not apexes or not consumedNodeId then
		return
	end

	local i = 1
	while i <= #apexes do
		if apexes[i].areaId == consumedNodeId then
			table.remove(apexes, i)
		else
			break
		end
	end

	G.Navigation.apexIndex = 1
	PathStringPull.ResetApexAdvanceTick()
end

--- Drop path[1] only when feet are firmly in path[2] (one node per call — no multi-pop).
function PathStringPull.SyncPathPrefixToPlayer(playerPos)
	local path = G.Navigation.path
	if not path or #path < 2 or not playerPos then
		return false
	end

	local pLocal = G.pLocal and G.pLocal.entity
	if pLocal and not GroundMovement.isOnGround(pLocal) then
		return false
	end

	local nextNode = path[2]
	local inNextArea = false

	local playerArea = Node.GetAreaAtPosition(playerPos)
	if playerArea and playerArea.id == nextNode.id then
		inNextArea = true
	elseif AreaSpatial.IsWithinArea(playerPos, nextNode) then
		local currentNode = path[1]
		if not currentNode or not AreaSpatial.IsWithinArea(playerPos, currentNode) then
			inNextArea = true
		end
	end

	if not inNextArea then
		return false
	end

	local floorZ = getGroundZOnNode(playerPos, nextNode)
	if floorZ and math.abs(playerPos.z - floorZ) > getNodeTouchHeight() then
		return false
	end

	local removed = table.remove(path, 1)
	if removed and removed.id then
		PathStringPull.ConsumeNodeApexes(removed.id)
	end

	G.Navigation.currentNodeIndex = 1
	return removed ~= nil
end

--- Follow / goal nudge: update last goal apex only (no full string-pull rebuild).
function PathStringPull.UpdateGoalApex(goalPos)
	local apexes = G.Navigation.apexPath
	if not apexes or #apexes == 0 or not goalPos then
		return
	end

	local apex = apexes[#apexes]
	if not apex or apex.kind ~= "goal" then
		return
	end

	local path = G.Navigation.path
	local lastArea = path and path[#path]
	apex.pos = lastArea and withGroundZ(goalPos, lastArea) or goalPos
end

function PathStringPull.lockIntentTowardNode(playerPos, targetNode, _nodeAfter)
	if not (targetNode and targetNode.pos) then
		G.Navigation.nodePassTrack = nil
		return
	end

	local steer = PathStringPull.GetMovementTarget(playerPos)
	local dir = horizontalDir(playerPos, steer or targetNode.pos)
	if not dir then
		dir = horizontalUnit(G.BotIntendedWishDir)
	end

	G.Navigation.nodePassTrack = {
		nodeId = targetNode.id,
		dirToTarget = dir,
	}
end

function PathStringPull.getReachDistance2D(_currentNode, _nextNode)
	return getTouchDistance()
end

--- On current path segment: in area, or in portal band (shared axis + Z within 82 of local floor).
function PathStringPull.IsNearSegmentPortal(playerPos, currentNode, nextNode)
	if AreaSpatial.IsWithinArea(playerPos, currentNode) then
		return true
	end

	local data = getSegmentPortalData(currentNode, nextNode)
	if not data or not data.portalMin or not data.portalMax then
		return false
	end
	if not isWithinPortalSpan(playerPos, data.exitDir, data.portalMin, data.portalMax, PORTAL_SPAN_TOLERANCE) then
		return false
	end

	local floorZ = getGroundZOnNode(playerPos, currentNode)
	if not floorZ then
		return true
	end
	return math.abs(playerPos.z - floorZ) <= getNodeTouchHeight()
end

--- Run once after A* — startPos is player position at path-find time.
function PathStringPull.ProcessAreaPath(areaPath, goalPos, startPos)
	local apexes = {}

	if not areaPath or #areaPath == 0 then
		if goalPos then
			pushApex(apexes, goalPos, "goal", nil, nil, nil, nil, nil, nil)
		end
		return apexes
	end

	local lastPos = startPos or areaPath[1].pos

	for i = 1, #areaPath - 1 do
		local area = areaPath[i]
		local nextArea = areaPath[i + 1]
		if not (area and nextArea and area.pos and nextArea.pos) then
			goto continue_segment
		end

		local prevArea = i > 1 and areaPath[i - 1] or nil
		local exitDir = getExitDirBetween(area, nextArea)
		local entryDir = getEntryDirIntoArea(prevArea, area, lastPos)
		local portalMin, portalMax =
			NavPortal.GetPortalSpanForNeighbor(area, nextArea, exitDir, STRING_PULL_DOORS_ONLY)
		local portalPos = getPortalPoint(area, nextArea, exitDir)
		local passDir = horizontalDir(portalPos, withGroundZ(nextArea.pos, nextArea))

		if needsCenterForSameSideEntry(entryDir, exitDir) then
			local centerPos = withGroundZ(area.pos, area)
			pushApex(apexes, centerPos, "same_side_center", area.id, nextArea.id, nil, nil, nil, nil)
			lastPos = centerPos
		end

		if needsApproachBeforePortal(lastPos, area, nextArea, exitDir, portalMin, portalMax, portalPos) then
			local approachPos =
				computeApproachPoint(lastPos, area, portalPos, exitDir, portalMin, portalMax)
			if approachPos then
				pushApex(apexes, approachPos, "approach", area.id, nextArea.id, nil, nil, nil, nil)
				lastPos = approachPos
			end
		end

		local dropHeight = getSegmentDropHeight(area, nextArea, portalPos)
		local transitionKind = dropHeight > DROP_Z_THRESHOLD and "drop" or "portal"
		pushApex(apexes, portalPos, transitionKind, area.id, nextArea.id, passDir, exitDir, portalMin, portalMax)
		lastPos = portalPos

		::continue_segment::
	end

	if goalPos then
		local lastArea = areaPath[#areaPath]
		local groundedGoal = lastArea and withGroundZ(goalPos, lastArea) or goalPos
		pushApex(apexes, groundedGoal, "goal", nil, nil, nil, nil, nil, nil)
	end

	return apexes
end

--- Read-only peek for debug draw — never advances apexIndex.
function PathStringPull.GetCachedApexTarget()
	local apexes = G.Navigation.apexPath
	local idx = G.Navigation.apexIndex or 1
	if apexes and apexes[idx] and apexes[idx].pos then
		return apexes[idx].pos
	end
	return G.Navigation.goalPos
end

local function advanceApexIndexOncePerTick(playerPos)
	local tick = globals.TickCount()
	if apexAdvanceTick == tick then
		return
	end
	apexAdvanceTick = tick

	local apexes = G.Navigation.apexPath
	if not apexes or #apexes == 0 then
		return
	end

	local path = G.Navigation.path
	local currentNode = path and path[1]
	local segmentStart = getApexIndexForCurrentSegment(apexes, path)
	local idx = G.Navigation.apexIndex or 1
	if idx < segmentStart then
		idx = segmentStart
	end

	while idx <= #apexes do
		local apex = apexes[idx]
		if not apexIsForCurrentSegment(apex, path) then
			break
		end
		if not hasPassedPortalApex(playerPos, apex, currentNode) then
			break
		end
		idx = idx + 1
	end

	if idx > #apexes then
		idx = #apexes
	end

	if not apexIsForCurrentSegment(apexes[idx], path) then
		idx = segmentStart
	end

	G.Navigation.apexIndex = idx
end

function PathStringPull.GetMovementTarget(playerPos)
	local apexes = G.Navigation.apexPath
	if not apexes or #apexes == 0 then
		return G.Navigation.goalPos
	end

	advanceApexIndexOncePerTick(playerPos)

	local idx = G.Navigation.apexIndex or 1
	if idx < 1 then
		idx = 1
	end
	if idx > #apexes then
		idx = #apexes
	end

	local apex = apexes[idx]
	local path = G.Navigation.path
	local currentNode = path and path[1]
	return getSteerPosForApex(playerPos, apex, currentNode) or apex.pos
end

function PathStringPull.IsApproachApexPending(playerPos, currentNode, nextNode)
	if not (currentNode and nextNode) then
		return false
	end

	local apexes = G.Navigation.apexPath
	if not apexes then
		return false
	end

	local centerIdx = nil
	local centerApex = nil
	for i = 1, #apexes do
		local apex = apexes[i]
		if isApproachKind(apex.kind) and apex.areaId == currentNode.id and apex.nextAreaId == nextNode.id then
			centerIdx = i
			centerApex = apex
			break
		end
	end

	if not centerApex then
		return false
	end

	local idx = G.Navigation.apexIndex or 1
	if idx > centerIdx then
		return false
	end

	return not hasPassedApproachApex(playerPos, centerApex)
end

PathStringPull.IsCenterApexPending = PathStringPull.IsApproachApexPending

--- Claim next area: nav id under feet; airborne only uses bounds (no ground overlap).
function PathStringPull.HasEnteredNextArea(playerPos, nextArea)
	if not nextArea then
		return false
	end
	local playerArea = Node.GetAreaAtPosition(playerPos)
	if playerArea then
		return playerArea.id == nextArea.id
	end
	local pLocal = G.pLocal and G.pLocal.entity
	if pLocal and not GroundMovement.isOnGround(pLocal) then
		return AreaSpatial.IsWithinArea(playerPos, nextArea)
	end
	return false
end

--- True when we walked through the portal opening (shared-axis span + plane/touch/overshoot).
function PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
	if not (currentNode and nextNode) then
		return false, nil
	end

	local transitionApex = findSegmentTransitionApex(currentNode.id, nextNode.id)
	if not transitionApex then
		if PathStringPull.HasEnteredNextArea(playerPos, nextNode) then
			return true, "inside_next"
		end
		return false, nil
	end

	local exitDir, portalMin, portalMax = resolvePortalSpan(transitionApex, currentNode, nextNode)
	if not portalMin then
		return false, nil
	end

	return evaluatePortalPass(
		playerPos,
		transitionApex.pos,
		transitionApex.passDir,
		exitDir,
		portalMin,
		portalMax,
		currentNode,
		nextNode,
		transitionApex.kind
	)
end

return PathStringPull
