--[[
    PathStringPull — process A* area path once after search (Unity-style string pull)
    Built once from player position at path-find time; runtime only walks cached apexes.
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local ConnectionUtils = require("NavBot.Navigation.ConnectionUtils")
local NavGeometry = require("NavBot.Navigation.Prediction.NavGeometry")
local NavPortal = require("NavBot.Navigation.Prediction.NavPortal")
local Node = require("NavBot.Navigation.Node")

local PathStringPull = {}

local WALL_BAND = 32
local APEX_TOUCH = 16
local PORTAL_PLANE_MARGIN = 8

local function horizontalDir(from, to)
	local dx = to.x - from.x
	local dy = to.y - from.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then
		return nil
	end
	return Vector3(dx / len, dy / len, 0)
end

local function horizontalUnit(vec)
	if not vec then
		return nil
	end
	local flat = Vector3(vec.x, vec.y, 0)
	local len = flat:Length2D()
	if len < 0.001 then
		return nil
	end
	return flat / len
end

local function getPassDirDotThreshold()
	return G.Misc.NodePassDirDotThreshold or 0.5
end

local function getTouchDistance()
	return G.Misc.NodeTouchDistance or APEX_TOUCH
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

local function getExitDirBetween(area, nextArea)
	local dir = horizontalDir(area.pos, nextArea.pos)
	if not dir then
		return nil
	end
	local _exitPt, _dist, exitDir = NavGeometry.FindNodeExit(area.pos, dir, area)
	return exitDir
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
		local idStr = tostring(targetId)
		if string.find(idStr, "_left") or string.find(idStr, "_middle") or string.find(idStr, "_right") then
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

local function needsCenterBeforePortal(fromPoint, area, exitDir)
	if not hasDoorOnExitEdge(area, exitDir) then
		return false
	end
	return isOnExitWall(fromPoint, area, exitDir)
end

local function getPortalPoint(area, nextArea, exitDir)
	if not exitDir then
		return withGroundZ(nextArea.pos, area)
	end

	local portalMin, portalMax = NavPortal.GetSharedPortalSpan(area, nextArea, exitDir)
	if not portalMin then
		return withGroundZ(nextArea.pos, area)
	end

	local mid = (portalMin + portalMax) * 0.5
	local x
	local y
	local z = area.pos.z

	if exitDir == 2 then
		x = area._maxX
		y = mid
	elseif exitDir == 4 then
		x = area._minX
		y = mid
	elseif exitDir == 3 then
		x = mid
		y = area._maxY
	else
		x = mid
		y = area._minY
	end

	return withGroundZ(Vector3(x, y, z), area)
end

local function pushApex(apexes, pos, kind, areaId, nextAreaId, passDir)
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
	}
end

local function findSegmentPortalApex(currentId, nextId)
	local apexes = G.Navigation.apexPath
	if not apexes then
		return nil
	end

	for i = 1, #apexes do
		local apex = apexes[i]
		if apex.kind == "portal" and apex.areaId == currentId and apex.nextAreaId == nextId then
			return apex, i
		end
	end

	return nil
end

local function hasCrossedPortalPlane(playerPos, portalPos, passDir, margin)
	if not (playerPos and portalPos and passDir) then
		return false
	end

	local dx = playerPos.x - portalPos.x
	local dy = playerPos.y - portalPos.y
	return (dx * passDir.x + dy * passDir.y) >= (margin or PORTAL_PLANE_MARGIN)
end

local function hasPortalTouch(playerPos, portalPos, currentNode)
	if not (playerPos and portalPos and currentNode) then
		return false
	end

	local touch = getTouchDistance()
	if Common.Distance2D(playerPos, portalPos) > touch then
		return false
	end

	return AreaSpatial.IsWithinArea(playerPos, currentNode)
end

local function hasPortalOvershoot(playerPos, portalPos, currentNode)
	if not (playerPos and portalPos and currentNode) then
		return false
	end

	local dist2D = Common.Distance2D(playerPos, portalPos)
	if dist2D > getOvershootTouchDistance() then
		return false
	end

	local track = G.Navigation.nodePassTrack
	if not (track and track.nodeId == currentNode.id and track.dirToTarget) then
		return false
	end

	local dirNow = horizontalDir(playerPos, portalPos)
	if not dirNow then
		dirNow = horizontalUnit(G.BotIntendedWishDir)
	end
	if not dirNow then
		return false
	end

	local dirDot = track.dirToTarget:Dot(dirNow)
	if dirDot >= getPassDirDotThreshold() then
		return false
	end

	return AreaSpatial.IsWithinArea(playerPos, currentNode)
end

local function hasPassedPortalApex(playerPos, apex, currentNode)
	if not (apex and apex.pos) then
		return false
	end

	if apex.kind ~= "portal" then
		return Common.Distance2D(playerPos, apex.pos) <= getTouchDistance()
	end

	if hasPortalTouch(playerPos, apex.pos, currentNode) then
		return true
	end
	if apex.passDir and hasCrossedPortalPlane(playerPos, apex.pos, apex.passDir) then
		return true
	end
	if hasPortalOvershoot(playerPos, apex.pos, currentNode) then
		return true
	end

	return false
end

--- Run once after A* — startPos is player position at path-find time.
function PathStringPull.ProcessAreaPath(areaPath, goalPos, startPos)
	local apexes = {}

	if not areaPath or #areaPath == 0 then
		if goalPos then
			pushApex(apexes, goalPos, "goal", nil, nil, nil)
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

		local exitDir = getExitDirBetween(area, nextArea)
		local portalPos = getPortalPoint(area, nextArea, exitDir)
		local passDir = horizontalDir(portalPos, withGroundZ(nextArea.pos, nextArea))

		if needsCenterBeforePortal(lastPos, area, exitDir) then
			pushApex(apexes, withGroundZ(area.pos, area), "center", area.id, nextArea.id, nil)
			lastPos = area.pos
		end

		pushApex(apexes, portalPos, "portal", area.id, nextArea.id, passDir)
		lastPos = portalPos

		::continue_segment::
	end

	if goalPos then
		pushApex(apexes, goalPos, "goal", nil, nil, nil)
	end

	return apexes
end

function PathStringPull.GetMovementTarget(playerPos)
	local apexes = G.Navigation.apexPath
	if not apexes or #apexes == 0 then
		return G.Navigation.goalPos
	end

	local path = G.Navigation.path
	local currentNode = path and path[1]
	local idx = G.Navigation.apexIndex or 1

	while idx <= #apexes do
		local apex = apexes[idx]
		if not hasPassedPortalApex(playerPos, apex, currentNode) then
			break
		end
		idx = idx + 1
	end

	if idx > #apexes then
		idx = #apexes
	end

	G.Navigation.apexIndex = idx
	return apexes[idx].pos
end

function PathStringPull.HasEnteredNextArea(playerPos, nextArea)
	if not nextArea then
		return false
	end
	local playerArea = Node.GetAreaAtPosition(playerPos)
	return playerArea ~= nil and playerArea.id == nextArea.id
end

--- True when we effectively walked through the segment portal (plane, touch, or overshoot dot).
function PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
	if not (currentNode and nextNode) then
		return false, nil
	end

	local portalApex = findSegmentPortalApex(currentNode.id, nextNode.id)
	local portalPos = portalApex and portalApex.pos
	local passDir = portalApex and portalApex.passDir

	local crossedPlane = portalPos and passDir and hasCrossedPortalPlane(playerPos, portalPos, passDir)
	local portalTouch = portalPos and hasPortalTouch(playerPos, portalPos, currentNode)
	local portalOvershoot = portalPos and hasPortalOvershoot(playerPos, portalPos, currentNode)
	local portalPassed = crossedPlane or portalTouch or portalOvershoot

	if portalPassed then
		if crossedPlane then
			return true, "portal_plane"
		end
		if portalTouch then
			return true, "portal_touch"
		end
		return true, "portal_overshoot"
	end

	local insideNext = PathStringPull.HasEnteredNextArea(playerPos, nextNode)
	if insideNext then
		if not portalApex then
			return true, "inside_next"
		end
		if portalPassed then
			return true, "inside_next"
		end
		-- Overlap: only advance when we've left the current area bbox
		if not AreaSpatial.IsWithinArea(playerPos, currentNode) then
			return true, "inside_next"
		end
	end

	return false, nil
end

return PathStringPull
