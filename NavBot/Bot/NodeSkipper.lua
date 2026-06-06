--[[
Node advance:
  1. Feet in path[2] (strict nav id / area bounds)
  2. Portal edge: crossed shared-axis plane (PathStringPull.HasPassedSegment)
  3. Open/center segment only: Skip_Nodes + feet in path[1] + velocity toward target + CanSkip
]]

local G = require("NavBot.Core.Globals")
local GroundMovement = require("NavBot.Bot.GroundMovement")
local NavMath = require("NavBot.Utils.NavMath")
local NavPredict = require("NavBot.Navigation.Prediction.NavPredict")
local Node = require("NavBot.Navigation.Node")
local PathStringPull = require("NavBot.Navigation.PathStringPull")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")

local NodeSkipper = {}

local SKIP_VEL_MIN_DOT = 0.92
local SKIP_MIN_SPEED = 80

local EDGE_PASS_REASONS = {
	portal_plane = true,
	inside_next = true,
	drop_landed = true,
	drop_airborne = true,
}

local function isFeetInNode(playerPos, node)
	if not node then
		return false
	end
	local playerArea = Node.GetAreaAtPosition(playerPos)
	if playerArea and playerArea.id == node.id then
		return true
	end
	return AreaSpatial.IsWithinArea(playerPos, node)
end

local function canWalkToNextNode(playerPos, goalPos, fromAreaNode, allowJump)
	if not fromAreaNode or not goalPos then
		return false
	end
	local success, canSkip = pcall(NavPredict.CanSkip, playerPos, goalPos, fromAreaNode, false, allowJump)
	return success and canSkip == true
end

local function isVelocityTowardTarget(playerPos, targetPos, player)
	if not (player and targetPos) then
		return false
	end

	local vel = player:EstimateAbsVelocity()
	local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	if speed < SKIP_MIN_SPEED then
		return false
	end

	local targetDir = NavMath.horizontalDir2D(playerPos, targetPos)
	if not targetDir then
		return false
	end

	local dot = (vel.x / speed) * targetDir.x + (vel.y / speed) * targetDir.y
	return dot >= SKIP_VEL_MIN_DOT
end

local function getSkipTargetPos(playerPos)
	if G.Navigation.currentTargetPos then
		return G.Navigation.currentTargetPos
	end
	return PathStringPull.GetMovementTarget(playerPos)
end

--- True when path[1] is claimed.
function NodeSkipper.CanAdvanceToNext(playerPos, currentNode, nextNode)
	if not (playerPos and currentNode and nextNode and nextNode.pos) then
		return false, nil
	end

	if PathStringPull.HasEnteredNextArea(playerPos, nextNode) then
		return true, "in_next_area"
	end

	if PathStringPull.IsEdgeSegment(currentNode, nextNode) then
		local passed, passReason = PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
		if passed and EDGE_PASS_REASONS[passReason] then
			return true, passReason
		end
		return false, "edge_not_crossed"
	end

	if not (G.Menu.Navigation and G.Menu.Navigation.Skip_Nodes) then
		return false, "skip_disabled"
	end

	if not isFeetInNode(playerPos, currentNode) then
		return false, "not_on_current"
	end

	local pLocal = G.pLocal and G.pLocal.entity
	if not pLocal or not GroundMovement.isOnGround(pLocal) then
		return false, "airborne"
	end

	local targetPos = getSkipTargetPos(playerPos)
	if not isVelocityTowardTarget(playerPos, targetPos, pLocal) then
		return false, "bad_velocity"
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	if canWalkToNextNode(playerPos, nextNode.pos, currentNode, allowJump) then
		return true, "navigable_to_next"
	end

	return false, "not_walkable_to_next"
end

function NodeSkipper.NoteAdvance(_playerPos, _reason) end

function NodeSkipper.Reset()
	G.Navigation.nodePassTrack = nil
	G.Navigation.lastAdvancePos = nil
	G.Navigation.lastStuckTargetDist2D = nil
	G.Navigation.skipBlockedUntilTick = nil
end

function NodeSkipper.BlockSkippingAfterPathSet() end

function NodeSkipper.BlockSkippingForTicks(_ticks)
	G.Navigation.skipBlockedUntilTick = nil
	G.Navigation.lastAdvancePos = nil
end

return NodeSkipper
