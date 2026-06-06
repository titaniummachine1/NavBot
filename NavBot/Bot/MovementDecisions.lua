--[[
Movement Decision System — portal apex steering, segment advance, stuck repath
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Navigation = require("NavBot.Navigation")
local PathStringPull = require("NavBot.Navigation.PathStringPull")
local MovementController = require("NavBot.Bot.MovementController")
local GroundMovement = require("NavBot.Bot.GroundMovement")
local NodeSkipper = require("NavBot.Bot.NodeSkipper")
local NavMoveDebug = require("NavBot.Bot.NavMoveDebug")
local SmartJump = require("NavBot.Bot.SmartJump")
local CircuitBreaker = require("NavBot.Bot.CircuitBreaker")
local WorkManager = require("NavBot.WorkManager")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

local DISTANCE_CHECK_COOLDOWN = 3
local STUCK_SPEED_RATIO = 0.8
local STUCK_GRACE_TICKS = 33
local STUCK_SAME_NODE_TICKS = 200
local STUCK_SLOW_REPATH_TICKS = 132

local cachedTargetTick = -1
local cachedTargetPos = nil
local lastSegmentAdvanceTick = -1

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
	G.Navigation.slowSpeedTicks = 0
	G.Navigation.currentNodeTicks = 0

	if not WorkManager.attemptWork(33, "force_repath_cooldown") then
		return
	end

	local path = G.Navigation.path
	if path and path[1] and path[2] then
		CircuitBreaker.addFailure(path[1], path[2])
	end
	NodeSkipper.BlockSkippingForTicks(STUCK_SLOW_REPATH_TICKS)

	-- Lazy: StateHandler also requires MovementDecisions (circular if at module top).
	local StateHandler = require("NavBot.Bot.StateHandler")
	StateHandler.forceRepath(reason, true)
end

function MovementDecisions.checkDistanceAndAdvance(_userCmd)
	local result = { shouldContinue = true }
	local localOrigin = G.pLocal.Origin

	if not WorkManager.attemptWork(DISTANCE_CHECK_COOLDOWN, "distance_check") then
		return result
	end

	if G.currentState == G.States.FOLLOWING then
		return result
	end

	if Navigation.AlignPathIfDesynced(localOrigin) then
		MovementDecisions.resetTargetCache()
		local path = G.Navigation.path
		if path and path[1] and G.pLocal and G.pLocal.Origin then
			PathStringPull.lockIntentTowardNode(G.pLocal.Origin, path[1], path[2])
		end
		local feetArea = path and path[1] and path[1].id
		NavMoveDebug.OnPathAligned(feetArea, path and #path or 0)
	end

	MovementDecisions.tryAdvancePathNode(localOrigin)

	local path = G.Navigation.path
	if path and #path == 1 and G.Navigation.goalPos then
		local goalDist = Common.Distance2D(localOrigin, G.Navigation.goalPos)
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
	local tick = globals.TickCount()
	if tick == lastSegmentAdvanceTick then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]
	if not (currentNode and nextNode and currentNode.pos and nextNode.pos) then
		return false
	end

	local canAdvance, advanceReason = NodeSkipper.CanAdvanceToNext(playerPos, currentNode, nextNode)
	if not canAdvance then
		NavMoveDebug.OnAdvanceBlocked(playerPos, currentNode, nextNode, advanceReason)
		return false
	end

	lastSegmentAdvanceTick = tick
	Log:Debug("Advancing path: left node %s (%s)", tostring(currentNode.id), advanceReason or "?")
	NavMoveDebug.OnAdvanced(currentNode.id, advanceReason)
	NodeSkipper.NoteAdvance(playerPos, advanceReason)
	return MovementDecisions.advanceNode()
end

function MovementDecisions.getCurrentTarget()
	local tick = globals.TickCount()
	if tick == cachedTargetTick and cachedTargetPos then
		return cachedTargetPos
	end

	local origin = G.pLocal and G.pLocal.Origin
	local path = G.Navigation.path
	local target
	if origin and path and #path > 0 then
		target = PathStringPull.GetMovementTarget(origin)
	else
		target = G.Navigation.goalPos
	end

	cachedTargetTick = tick
	cachedTargetPos = target
	return target
end

function MovementDecisions.resetTargetCache()
	cachedTargetTick = -1
	cachedTargetPos = nil
	lastSegmentAdvanceTick = -1
end

function MovementDecisions.advanceNode()
	MovementDecisions.resetTargetCache()
	G.Navigation.slowSpeedTicks = 0
	G.Navigation.currentNodeTicks = 0
	G.Navigation.lastStuckTargetDist2D = nil
	Navigation.RemoveCurrentNode()
	Navigation.ResetTickTimer()
	Navigation.ResetNodeSkipping()

	local path = G.Navigation.path
	if path and path[1] and G.pLocal and G.pLocal.Origin then
		PathStringPull.lockIntentTowardNode(G.pLocal.Origin, path[1], path[2])
	end

	if #G.Navigation.path == 0 then
		Navigation.ClearPath()
		Log:Info("Reached end of path")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		return false
	end

	return true
end

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
		G.Navigation.lastStuckTargetDist2D = nil
		return
	end

	local origin = G.pLocal.Origin
	local targetPos = PathStringPull.GetCachedApexTarget()
	if origin and targetPos then
		local targetDist2D = Common.Distance2D(origin, targetPos)
		local lastDist = G.Navigation.lastStuckTargetDist2D
		if lastDist and targetDist2D < lastDist - 12 then
			G.Navigation.slowSpeedTicks = 0
			G.Navigation.currentNodeTicks = 0
		end
		G.Navigation.lastStuckTargetDist2D = targetDist2D
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
			local path = G.Navigation.path
			local seg = path
					and path[1]
					and path[2]
					and string.format("%s->%s", tostring(path[1].id), tostring(path[2].id))
				or tostring(currentNodeId)
			Log:Warn(
				"STUCK: seg=%s for %d ticks below %d pct speed, repathing",
				seg,
				G.Navigation.currentNodeTicks,
				math.floor(STUCK_SPEED_RATIO * 100)
			)
			triggerStuckRepath("Same node too long while slow")
			return
		end
	end

	if G.Navigation.slowSpeedTicks > STUCK_GRACE_TICKS + STUCK_SLOW_REPATH_TICKS then
		Log:Warn(
			"STUCK: Speed %.1f below %d pct max for %d ticks, repathing",
			speed2D,
			math.floor(STUCK_SPEED_RATIO * 100),
			G.Navigation.slowSpeedTicks
		)
		triggerStuckRepath("Slow for extended period")
	end
end

function MovementDecisions.handleDebugLogging()
	local pLocal = G.pLocal and G.pLocal.entity
	local speed2D = pLocal and getPlayerSpeed2D(pLocal) or 0
	NavMoveDebug.Tick(G.pLocal and G.pLocal.Origin, speed2D)
end

function MovementDecisions.handleSmartJump(userCmd)
	SmartJump.Main(userCmd)
end

function MovementDecisions.executeMovement(userCmd)
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		Log:Warn("No target position available for movement")
		return
	end

	if G.Menu.Main.EnableWalking then
		MovementController.walkTo(userCmd, G.pLocal.entity, targetPos)
	else
		userCmd:SetForwardMove(0)
		userCmd:SetSideMove(0)
	end
end

function MovementDecisions.handleMovingState(userCmd)
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	local targetPos = MovementDecisions.getCurrentTarget()
	if targetPos then
		local localOrigin = G.pLocal.Origin
		local direction = targetPos - localOrigin
		if direction:Length() > 0 then
			G.BotMovementDirection = Common.Normalize(direction)
			G.BotIntendedWishDir = G.BotMovementDirection
		else
			G.BotMovementDirection = Vector3(0, 0, 0)
			G.BotIntendedWishDir = Vector3(0, 0, 0)
		end
		G.BotIsMoving = true
		G.Navigation.currentTargetPos = targetPos
	end

	MovementController.handleCameraRotation(userCmd, targetPos)
	MovementDecisions.handleDebugLogging()
	MovementDecisions.checkDistanceAndAdvance(userCmd)
	MovementDecisions.checkStuckState()
	MovementDecisions.executeMovement(userCmd)
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions
