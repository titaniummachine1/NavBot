--##########################################################################
--  PathSteering.lua  ·  Pass detection + intent (movement via PathStringPull)
--##########################################################################

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local PathStringPull = require("NavBot.Navigation.PathStringPull")

local PathSteering = {}

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

local function isInsideNodeAABB(pos, node)
	if Node.IsDoorNode(node) then
		return false
	end
	return AreaSpatial.IsWithinArea(pos, node)
end

function PathSteering.lockIntentTowardNode(playerPos, targetNode, nodeAfter)
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

local function ensureSegmentIntent(playerPos, currentNode, nextNode)
	local track = G.Navigation.nodePassTrack
	if track and track.nodeId == currentNode.id and track.dirToTarget then
		return track
	end

	local steer = PathStringPull.GetMovementTarget(playerPos)
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

function PathSteering.getMovementTarget(playerPos, _path, _goalPos)
	return PathStringPull.GetMovementTarget(playerPos)
end

function PathSteering.getReachDistance2D(_currentNode, _nextNode)
	return getTouchDistance()
end

function PathSteering.hasPassedNode(playerPos, currentNode, nextNode)
	return PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
end

return PathSteering
