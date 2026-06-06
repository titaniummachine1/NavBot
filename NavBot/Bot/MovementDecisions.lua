--[[
Movement Decision System - Composition-based bot behavior
Handles all movement decisions while ensuring walkTo is always called
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Navigation = require("NavBot.Navigation")
local PathSteering = require("NavBot.Navigation.PathSteering")
local PathStringPull = require("NavBot.Navigation.PathStringPull")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local Node = require("NavBot.Navigation.Node")
local MovementController = require("NavBot.Bot.MovementController")
local NodeSkipper = require("NavBot.Bot.NodeSkipper")
local SmartJump = require("NavBot.Bot.SmartJump")
local WorkManager = require("NavBot.WorkManager")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs
local WALKABILITY_CHECK_COOLDOWN = 5 -- ticks (~83ms) between expensive walkability checks
local STUCK_SPEED_RATIO = 0.8
local STUCK_GRACE_TICKS = 33
local STUCK_SAME_NODE_TICKS = 200
local STUCK_SLOW_REPATH_TICKS = 132

local function getPlayerSpeed2D(pLocal)
	local velocity = pLocal:EstimateAbsVelocity()
	if not velocity or type(velocity.x) ~= "number" or type(velocity.y) ~= "number" then
		return 0
	end
	return math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
end

local function isBelowStuckSpeedThreshold(speed2D, maxSpeed)
	if not maxSpeed or maxSpeed <= 0 then
		maxSpeed = 450
	end
	return speed2D < (maxSpeed * STUCK_SPEED_RATIO)
end

local function triggerStuckRepath(reason)
	local StateHandler = require("NavBot.Bot.StateHandler")
	WorkManager.setWorkCooldown("node_skipping", STUCK_SLOW_REPATH_TICKS)
	StateHandler.addStuckPenalties()
	StateHandler.forceRepath(reason)
	G.Navigation.slowSpeedTicks = 0
	G.Navigation.currentNodeTicks = 0
end

-- Decision: Check if we've reached the target and advance waypoints/nodes
function MovementDecisions.checkDistanceAndAdvance(userCmd)
	local result = { shouldContinue = true }
	local LocalOrigin = G.pLocal.Origin

	-- Throttled distance calculation for reaching nodes
	if not WorkManager.attemptWork(DISTANCE_CHECK_COOLDOWN, "distance_check") then
		return result -- Skip this frame's distance check
	end

	-- In FOLLOWING state we don't advance nodes based on reach distance
	if G.currentState == G.States.FOLLOWING then
		return result
	end

	if MovementDecisions.tryAdvancePathNode(LocalOrigin) then
		return result
	end

	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		result.shouldContinue = false
		return result
	end

	local horizontalDist = Common.Distance2D(LocalOrigin, targetPos)
	local verticalDist = math.abs(LocalOrigin.z - targetPos.z)

	local path = G.Navigation.path
	if path and #path == 1 and G.Navigation.goalPos then
		local goalDist = Common.Distance2D(LocalOrigin, G.Navigation.goalPos)
		if goalDist < (G.Misc.NodeTouchDistance or 16) then
			Navigation.ClearPath()
			Log:Info("Reached final goal")
			result.shouldContinue = false
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
		end
	end

	return result
end

function MovementDecisions.tryAdvancePathNode(playerPos)
	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]
	if not (currentNode and nextNode and currentNode.pos and nextNode.pos) then
		return false
	end

	local passed, passReason = PathStringPull.HasPassedSegment(playerPos, currentNode, nextNode)
	if not passed then
		return false
	end

	Log:Debug("Advancing path: left node %s (%s)", tostring(currentNode.id), passReason or "?")
	return MovementDecisions.advanceNode()
end

-- Helper: Get current target position
function MovementDecisions.getCurrentTarget()
	local origin = G.pLocal and G.pLocal.Origin
	local path = G.Navigation.path
	if origin and path and #path > 0 then
		return PathSteering.getMovementTarget(origin, path, G.Navigation.goalPos)
	end
	return G.Navigation.goalPos
end

-- Helper: Check if we've reached the target
function MovementDecisions.hasReachedTarget(origin, targetPos, horizontalDist, verticalDist)
	local reachDist = G.Misc.NodeTouchDistance or 16
	local touchHeight = G.Misc.NodeTouchHeight or 82
	if G.Navigation.path and #G.Navigation.path > 1 then
		local currentNode = G.Navigation.path[1]
		local nextNode = G.Navigation.path[2]
		reachDist = PathSteering.getReachDistance2D(currentNode, nextNode)
	end

	-- Mid-air: origin high but still inside nav area vertical band
	local currentNode = G.Navigation.path and G.Navigation.path[1]
	if currentNode and not Node.IsDoorNode(currentNode) then
		if horizontalDist < reachDist and AreaSpatial.IsWithinArea(origin, currentNode) then
			return true
		end
	end

	return (horizontalDist < reachDist) and (verticalDist <= touchHeight)
end

-- Reset distance tracking (call when path changes)
function MovementDecisions.resetDistanceTracking()
	previousDistance = nil
end

-- Decision: Handle node advancement
function MovementDecisions.advanceNode()
	previousDistance = nil
	G.Navigation.slowSpeedTicks = 0
	G.Navigation.currentNodeTicks = 0
	Navigation.RemoveCurrentNode()
	Navigation.ResetTickTimer()
	Navigation.ResetNodeSkipping()

	local path = G.Navigation.path
	if path and path[1] and G.pLocal and G.pLocal.Origin then
		PathSteering.lockIntentTowardNode(G.pLocal.Origin, path[1], path[2])
	end

	if #G.Navigation.path == 0 then
		Navigation.ClearPath()
		Log:Info("Reached end of path")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		return false
	end

	return true -- Continue moving
end

-- Only start stuck checks after speed stays below 80% max for STUCK_GRACE_TICKS.
-- Never switch to STUCK state (that stops walkTo); repath while still moving.
function MovementDecisions.checkStuckState()
	if not G.Menu.Main.EnableWalking then
		return
	end

	local pLocal = G.pLocal.entity
	if not pLocal then
		return
	end

	local maxSpeed = Common.Dynamic.GetMaxSpeed()
	local speed2D = getPlayerSpeed2D(pLocal)

	if not isBelowStuckSpeedThreshold(speed2D, maxSpeed) then
		G.Navigation.slowSpeedTicks = 0
		return
	end

	G.Navigation.slowSpeedTicks = (G.Navigation.slowSpeedTicks or 0) + 1
	if G.Navigation.slowSpeedTicks <= STUCK_GRACE_TICKS then
		return
	end

	local currentNodeId = G.Navigation.path and G.Navigation.path[1] and G.Navigation.path[1].id
	if currentNodeId then
		if currentNodeId ~= G.Navigation.lastNodeId then
			G.Navigation.lastNodeId = currentNodeId
			G.Navigation.currentNodeTicks = 0
		else
			G.Navigation.currentNodeTicks = (G.Navigation.currentNodeTicks or 0) + 1
		end

		if G.Navigation.currentNodeTicks > STUCK_SAME_NODE_TICKS then
			Log:Warn(
				"STUCK: Same node %s for %d ticks below %.0f%% speed, repathing",
				tostring(currentNodeId),
				G.Navigation.currentNodeTicks,
				STUCK_SPEED_RATIO * 100
			)
			triggerStuckRepath("Same node too long while slow")
			return
		end
	end

	if G.Navigation.slowSpeedTicks > STUCK_GRACE_TICKS + STUCK_SLOW_REPATH_TICKS then
		Log:Warn(
			"STUCK: Speed %.1f below %.0f%% max for %d ticks, repathing",
			speed2D,
			STUCK_SPEED_RATIO * 100,
			G.Navigation.slowSpeedTicks
		)
		triggerStuckRepath("Slow for extended period")
	end
end

-- Decision: Handle debug logging (throttled)
function MovementDecisions.handleDebugLogging()
	-- Throttled debug logging
	G.__lastMoveDebugTick = G.__lastMoveDebugTick or 0
	local now = globals.TickCount()

	if now - G.__lastMoveDebugTick > DEBUG_LOG_COOLDOWN then
		local targetPos = MovementDecisions.getCurrentTarget()
		if targetPos then
			local pathLen = G.Navigation.path and #G.Navigation.path or 0
			Log:Debug("MOVING: pathLen=%d", pathLen)
		end
		G.__lastMoveDebugTick = now
	end
end

-- Decision: Handle SmartJump execution
function MovementDecisions.handleSmartJump(userCmd)
	SmartJump.Main(userCmd)
end

-- Movement Execution: Always called at the end
function MovementDecisions.executeMovement(userCmd)
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		Log:Warn("No target position available for movement")
		return
	end

	-- Always execute movement regardless of decision cooldowns
	if G.Menu.Main.EnableWalking then
		MovementController.walkTo(userCmd, G.pLocal.entity, targetPos)
	else
		userCmd:SetForwardMove(0)
		userCmd:SetSideMove(0)
	end
end

-- Main composition function: Run all decisions then always execute movement
function MovementDecisions.handleMovingState(userCmd)
	-- Early validation
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Update movement direction for SmartJump
	local targetPos = MovementDecisions.getCurrentTarget()
	if targetPos then
		local LocalOrigin = G.pLocal.Origin
		local direction = targetPos - LocalOrigin
		G.BotMovementDirection = direction:Length() > 0 and Common.Normalize(direction) or Vector3(0, 0, 0)
		G.BotIsMoving = true
		G.Navigation.currentTargetPos = targetPos
	end

	-- Handle camera rotation
	MovementController.handleCameraRotation(userCmd, targetPos)

	-- Run all decision components (these don't affect movement execution)
	MovementDecisions.handleDebugLogging()
	NodeSkipper.Tick(G.pLocal.Origin)
	MovementDecisions.checkDistanceAndAdvance(userCmd)
	MovementDecisions.checkStuckState()

	-- ALWAYS execute movement at the end, regardless of decision outcomes
	MovementDecisions.executeMovement(userCmd)

	-- Handle SmartJump after walkTo
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions
