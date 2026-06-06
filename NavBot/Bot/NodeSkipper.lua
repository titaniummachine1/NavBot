--[[
Node advance — simple rules:
  1. Entered path[2] (nav id or area bounds — no XY touch padding on next area)
  2. Edge/door pass on portal segments only (shared-axis span + crossed plane)
  3. Skip_Nodes + on path[1] + CanSkip to path[2] (doorsOnly=false)
]]

local G = require("NavBot.Core.Globals")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local NavPredict = require("NavBot.Navigation.Prediction.NavPredict")
local PathStringPull = require("NavBot.Navigation.PathStringPull")

local NodeSkipper = {}

local EDGE_PASS_REASONS = {
	portal_plane = true,
	portal_touch = true,
	inside_next = true,
	drop_landed = true,
	drop_airborne = true,
}

local function getTouchDist()
	return (G.Misc and G.Misc.NodeTouchDistance) or 16
end

--- 16 XY + 82 Z touch on a node (current node only — not used for next-area claim).
local function hasNodeTouch(playerPos, node)
	if not node then
		return false
	end
	if AreaSpatial.IsWithinArea(playerPos, node) then
		return true
	end
	local touchDist = getTouchDist()
	return AreaSpatial.DistSqPointToAABB(playerPos, node) <= touchDist * touchDist
end

local function isEdgeSegment(currentNode, nextNode)
	return PathStringPull.GetSegmentPortalPos(currentNode, nextNode) ~= nil
end

local function isOnCurrentNode(playerPos, currentNode, nextNode)
	if hasNodeTouch(playerPos, currentNode) then
		return true
	end
	return PathStringPull.IsNearSegmentPortal(playerPos, currentNode, nextNode)
end

local function canWalkToNextNode(playerPos, goalPos, fromAreaNode, allowJump)
	if not fromAreaNode or not goalPos then
		return false
	end
	local success, canSkip = pcall(NavPredict.CanSkip, playerPos, goalPos, fromAreaNode, false, allowJump)
	return success and canSkip == true
end

--- True when path[1] is claimed — entered next area, passed portal edge, or CanSkip to path[2].
function NodeSkipper.CanAdvanceToNext(playerPos, currentNode, nextNode)
	if not (playerPos and currentNode and nextNode and nextNode.pos) then
		return false, nil
	end

	if PathStringPull.HasEnteredNextArea(playerPos, nextNode) then
		return true, "in_next_area"
	end

	if isEdgeSegment(currentNode, nextNode) then
		local passed, passReason = PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
		if passed and EDGE_PASS_REASONS[passReason] then
			return true, passReason
		end
	end

	if not (G.Menu.Navigation and G.Menu.Navigation.Skip_Nodes) then
		return false, "skip_disabled"
	end

	if not isOnCurrentNode(playerPos, currentNode, nextNode) then
		return false, "not_on_current"
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	if canWalkToNextNode(playerPos, nextNode.pos, currentNode, allowJump) then
		return true, "navigable_to_next"
	end

	return false, "not_walkable_to_next"
end

function NodeSkipper.NoteAdvance(_playerPos, _reason)
end

function NodeSkipper.Reset()
	G.Navigation.nodePassTrack = nil
	G.Navigation.lastAdvancePos = nil
	G.Navigation.lastStuckTargetDist2D = nil
	G.Navigation.skipBlockedUntilTick = nil
end

function NodeSkipper.BlockSkippingAfterPathSet()
end

function NodeSkipper.BlockSkippingForTicks(_ticks)
	G.Navigation.skipBlockedUntilTick = nil
	G.Navigation.lastAdvancePos = nil
end

return NodeSkipper
