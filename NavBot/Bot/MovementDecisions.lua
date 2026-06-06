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
local SmartJump = require("NavBot.Bot.SmartJump")
local WorkManager = require("NavBot.WorkManager")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs
local WALKABILITY_CHECK_COOLDOWN = 5 -- ticks (~83ms) between expensive walkability checks

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

-- Decision: Check stuck state: Simple walkability check with cooldown
function MovementDecisions.checkStuckState()
	-- Velocity/timeout checks ONLY when bot is walking autonomously
	if G.Menu.Main.EnableWalking then
		local pLocal = G.pLocal.entity
		if pLocal then
			-- Track how long we've been on the same node
			local currentNodeId = G.Navigation.path and G.Navigation.path[1] and G.Navigation.path[1].id
			if currentNodeId then
				if currentNodeId ~= G.Navigation.lastNodeId then
					G.Navigation.lastNodeId = currentNodeId
					G.Navigation.currentNodeTicks = 0
				else
					G.Navigation.currentNodeTicks = (G.Navigation.currentNodeTicks or 0) + 1
				end

				-- Stuck detection: If on same node for > 200 ticks (3 seconds), force repath
				if G.Navigation.currentNodeTicks > 200 then
					Log:Warn("STUCK: Same node for %d ticks, switching to STUCK state", G.Navigation.currentNodeTicks)
					G.currentState = G.States.STUCK
					G.Navigation.currentNodeTicks = 0
					return
				end
			end

			-- Velocity-based stuck detection
			local velocity = pLocal:EstimateAbsVelocity()
			if velocity and type(velocity.x) == "number" and type(velocity.y) == "number" then
				local speed2D = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

				-- Critical velocity threshold: < 50 = stuck
				if speed2D < 50 then
					G.Navigation.lowVelocityTicks = (G.Navigation.lowVelocityTicks or 0) + 1

					-- If velocity too low for 66 ticks (1 second), switch to STUCK state
					if G.Navigation.lowVelocityTicks > 66 then
						Log:Warn(
							"STUCK: Low velocity (%.1f) for %d ticks, entering STUCK state",
							speed2D,
							G.Navigation.lowVelocityTicks
						)
						G.currentState = G.States.STUCK
						G.Navigation.lowVelocityTicks = 0
					end
				else
					G.Navigation.lowVelocityTicks = 0
				end
			end
		end
	end

	-- Simple walkability check for ALL modes (with 33 tick cooldown)
	-- Only when NOT walking autonomously (walking mode has velocity checks)
	if not G.Menu.Main.EnableWalking then
		-- TEMPORARILY DISABLED to debug NodeSkipper traces (this was interfering with visualization)
		-- if WorkManager.attemptWork(33, "stuck_walkability_check") then
		-- 	local targetPos = MovementDecisions.getCurrentTarget()
		-- 	if targetPos then
		-- 		if not PathValidator.Path(G.pLocal.Origin, targetPos) then
		-- 			Log:Warn("STUCK: Path to current target not walkable, repathing")
		-- 			G.currentState = G.States.STUCK
		-- 		end
		-- 	end
		-- end
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
	MovementDecisions.checkDistanceAndAdvance(userCmd)
	MovementDecisions.checkStuckState()

	-- ALWAYS execute movement at the end, regardless of decision outcomes
	MovementDecisions.executeMovement(userCmd)

	-- Handle SmartJump after walkTo
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions
