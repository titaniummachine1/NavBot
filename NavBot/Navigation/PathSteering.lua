--##########################################################################
--  PathSteering.lua  ·  Portal targets + Amalgam-style pass detection
--##########################################################################

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")

local PathSteering = {}

local SMALL_AREA_EXTENT = 96
local MIN_SEGMENT_LEN = 12

local function getPassDirDotThreshold()
	return G.Misc.NodePassDirDotThreshold or 0.5
end

local function getTouchDistance()
	return G.Misc.NodeTouchDistance or 16
end

local function getOvershootTouchDistance()
	return G.Misc.NodeOvershootTouchDistance or 48
end

local function horizontalDir(from, to)
	local dx = to.x - from.x
	local dy = to.y - from.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then
		return nil, 0
	end
	return Vector3(dx / len, dy / len, 0), len
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

local function findNodeExit(startPos, dir, node)
	if not node._minX then
		return nil
	end

	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY
	local tMin = math.huge
	local exitX, exitY

	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
		end
	end

	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
		end
	end

	if tMin == math.huge then
		return nil
	end

	return Vector3(exitX, exitY, startPos.z)
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

local function applyGroundZ(point, node)
	if not point then
		return nil
	end
	return Vector3(point.x, point.y, getGroundZOnNode(point, node))
end

local function isInsideNodeAABB(pos, node)
	if Node.IsDoorNode(node) then
		return false
	end
	return AreaSpatial.IsWithinArea(pos, node)
end

--- Save horizontal intent toward the new path[1] right after a node is cleared.
function PathSteering.lockIntentTowardNode(playerPos, targetNode, nodeAfter)
	if not (targetNode and targetNode.pos) then
		G.Navigation.nodePassTrack = nil
		return
	end

	local steer = PathSteering.getSteeringPoint(playerPos, targetNode, nodeAfter)
	local dir = horizontalDir(playerPos, steer or targetNode.pos)
	if not dir then
		dir = horizontalUnit(G.BotIntendedWishDir)
	end

	G.Navigation.nodePassTrack = {
		nodeId = targetNode.id,
		dirToTarget = dir,
	}
end

local function ensureSegmentIntent(playerPos, currentNode, nextNode)
	local track = G.Navigation.nodePassTrack
	if track and track.nodeId == currentNode.id and track.dirToTarget then
		return track
	end

	local steer = PathSteering.getSteeringPoint(playerPos, currentNode, nextNode)
	local dir = horizontalDir(playerPos, steer or currentNode.pos)
	if not dir then
		dir = horizontalUnit(G.BotIntendedWishDir)
	end

	track = {
		nodeId = currentNode.id,
		dirToTarget = dir,
	}
	G.Navigation.nodePassTrack = track
	return track
end

function PathSteering.getSteeringPoint(playerPos, currentNode, nextNode)
	if not currentNode or not currentNode.pos then
		return nil
	end

	if Node.IsDoorNode(currentNode) or not nextNode or not nextNode.pos then
		return currentNode.pos
	end

	local dir = horizontalDir(playerPos, nextNode.pos)
	if not dir then
		dir = horizontalDir(currentNode.pos, nextNode.pos)
	end
	if not dir then
		return currentNode.pos
	end

	local extent = math.max(currentNode._extentX or 0, currentNode._extentY or 0)
	local exitPt = findNodeExit(playerPos, dir, currentNode)

	if extent < SMALL_AREA_EXTENT or not exitPt then
		return currentNode.pos
	end

	return applyGroundZ(exitPt, currentNode) or currentNode.pos
end

function PathSteering.getReachDistance2D(_currentNode, _nextNode)
	return getTouchDistance()
end

--- Door node: only passed after crossing into the neighbor area (not while standing before the doorway).
local function hasPassedDoorNode(playerPos, doorNode, nextNode)
	if not Node.IsDoorNode(doorNode) then
		return false, nil
	end

	local neighborArea = nextNode
	if Node.IsDoorNode(nextNode) then
		local nodes = G.Navigation.nodes
		local targetId = doorNode.targetAreaId
		if nodes and targetId then
			neighborArea = nodes[targetId]
		end
	end

	if not neighborArea or not neighborArea._minX then
		return false, nil
	end

	if AreaSpatial.IsWithinArea(playerPos, neighborArea) then
		return true, "door_entered_neighbor"
	end

	local dir, segLen = horizontalDir(doorNode.pos, neighborArea.pos)
	if not dir or segLen < 4 then
		return false, nil
	end

	local along = (playerPos.x - doorNode.pos.x) * dir.x + (playerPos.y - doorNode.pos.y) * dir.y
	local boundarySlack = math.min(32, segLen * 0.4)
	if along < boundarySlack then
		return false, nil
	end

	if Common.Distance2D(playerPos, neighborArea.pos) > getOvershootTouchDistance() * 2.5 then
		return false, nil
	end

	return true, "door_past_boundary"
end

function PathSteering.hasPassedNode(playerPos, currentNode, nextNode)
	if not (currentNode and currentNode.pos and nextNode and nextNode.pos) then
		return false, nil
	end

	if Node.IsDoorNode(currentNode) then
		return hasPassedDoorNode(playerPos, currentNode, nextNode)
	end

	local steer = PathSteering.getSteeringPoint(playerPos, currentNode, nextNode)
	local targetPos = steer or currentNode.pos
	local dist2D = Common.Distance2D(playerPos, targetPos)
	local touch = getTouchDistance()

	local track = ensureSegmentIntent(playerPos, currentNode, nextNode)
	local dirNow = horizontalDir(playerPos, targetPos)
	if not dirNow then
		dirNow = horizontalUnit(G.BotIntendedWishDir)
	end

	-- Normal reach: 16u at portal/center, inside current area AABB
	if dist2D <= touch and isInsideNodeAABB(playerPos, currentNode) then
		return true, "touch"
	end

	-- Amalgam-style overshoot: intent dir flipped (dot < 0.5), 48u, still inside this area's AABB
	if track.dirToTarget and dirNow then
		local dirDot = track.dirToTarget:Dot(dirNow)
		if dirDot < getPassDirDotThreshold() and dist2D <= getOvershootTouchDistance() then
			if isInsideNodeAABB(playerPos, currentNode) then
				return true, "overshoot"
			end
		end
	end

	return false, nil
end

return PathSteering
