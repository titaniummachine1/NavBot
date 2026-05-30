local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local GroundMovement = require("NavBot.Bot.GroundMovement")
local PathSteering = require("NavBot.Navigation.PathSteering")
local Node = require("NavBot.Navigation.Node")

local Log = Common.Log.new("SmartJump")

Log.Level = 0
local SJ = G.SmartJump
local SJC = G.SmartJump.Constants

local MIN_STEP_HEIGHT = 18
local MAX_CLEAR_HEIGHT = 72
local MAX_PATH_SIM_SEGMENTS = 16
local MIN_POLY_POINT_DIST = 8
local ARRIVAL_DIST = 1.5

local SmartJump = {}

local JUMP_STUCK_SUPPRESS_TICKS = 90
local JUMP_FAIL_COOLDOWN_TICKS = 66
local JUMP_STATE_TIMEOUT_TICKS = 132
local JUMP_MIN_AIRBORNE_TICKS = 3
-- Duck-jump timing: 1 cmd duck (PREPARE), 1 cmd unduck+jump on ground (CTAP), then ASCENDING.
local JUMP_PREPARE_HOLD_TICKS = 1
local JUMP_MAX_DUCK_TICKS = 1
local JUMP_CTAP_MIN_VZ = 50
local JUMP_MIN_RUN_SPEED = 180
local JUMP_LAND_REJUMP_TICKS = 66

function SmartJump.isActive()
	if SJ.jumpState ~= SJC.STATE_IDLE then
		return true
	end
	local tick = globals.TickCount()
	if SJ.suppressStuckUntilTick and tick < SJ.suppressStuckUntilTick then
		return true
	end
	return false
end

local function getAdvanceKey(cmd)
	if cmd and cmd.command_number then
		return cmd.command_number
	end
	return globals.TickCount()
end

local function logJumpStateTransition(fromState, toState, cmd, pLocal, onGround, reason)
	if not (G.Menu.SmartJump and G.Menu.SmartJump.Debug) then
		return
	end
	if fromState == toState then
		return
	end

	local tick = globals.TickCount()
	local cmdNum = (cmd and cmd.command_number) and cmd.command_number or -1
	local ticksInPrev = 0
	if SJ.stateStartTime then
		ticksInPrev = tick - SJ.stateStartTime
	end

	local speed2d = 0
	local velZ = 0
	if pLocal then
		local vel = pLocal:EstimateAbsVelocity()
		if vel then
			speed2d = vel:Length2D()
			velZ = vel.z
		end
	end

	Log:Info(
		"SmartJump tick=%d cmd=%d | %s -> %s (%d ticks in prev) | %s | onGround=%s spd=%.0f vz=%.1f | duck=%s prep=%s air=%s leftGnd=%s bot=%s",
		tick,
		cmdNum,
		tostring(fromState or "nil"),
		tostring(toState),
		ticksInPrev,
		tostring(reason or ""),
		tostring(onGround),
		speed2d,
		velZ,
		tostring(SJ.duckTicksThisJump or 0),
		tostring(SJ.prepareTicks or 0),
		tostring(SJ.airborneTicks or 0),
		tostring(SJ.leftGroundThisJump),
		tostring(G.currentState)
	)
end

function SmartJump.isOnJumpFailCooldown()
	local untilTick = SJ.jumpFailCooldownUntil
	return untilTick ~= nil and globals.TickCount() < untilTick
end

function SmartJump.hasMinJumpSpeed(pLocal)
	if not pLocal then
		return false
	end
	local vel = pLocal:EstimateAbsVelocity()
	return vel ~= nil and vel:Length2D() >= JUMP_MIN_RUN_SPEED
end

local function isOnJumpFailCooldown()
	return SmartJump.isOnJumpFailCooldown()
end

local function beginJumpAttempt(cmd, pLocal, onGround, reason)
	if not onGround then
		return
	end
	if isOnJumpFailCooldown() then
		return
	end

	local tick = globals.TickCount()
	if SJ.lastLandTick and tick - SJ.lastLandTick < JUMP_LAND_REJUMP_TICKS then
		return
	end

	if not SmartJump.hasMinJumpSpeed(pLocal) then
		return
	end

	local fromState = SJ.jumpState
	if fromState and fromState ~= SJC.STATE_IDLE then
		return
	end

	SJ.leftGroundThisJump = false
	SJ.airborneTicks = 0
	SJ.prepareTicks = 0
	SJ.ctapTicks = 0
	SJ.prepareEnterTick = tick
	SJ.ctapEnterTick = nil
	SJ.duckTicksThisJump = 0
	SJ.lastDuckCountTick = nil
	SJ.allowLedgeGrabDuck = false
	SJ.jumpState = SJC.STATE_PREPARE_JUMP
	SJ.suppressStuckUntilTick = tick + JUMP_STUCK_SUPPRESS_TICKS
	SJ.jumpCommitUntilTick = tick + JUMP_STATE_TIMEOUT_TICKS
	SJ.stateStartTime = tick
	SJ.lastState = SJC.STATE_PREPARE_JUMP
	G.Navigation.lowVelocityTicks = 0
	if G.currentState == G.States.STUCK then
		G.currentState = G.States.MOVING
	end
	logJumpStateTransition(fromState, SJC.STATE_PREPARE_JUMP, cmd, pLocal, onGround, reason or "beginJumpAttempt")
end

local function markJumpFailed(cmd, pLocal, onGround, reason)
	local fromState = SJ.jumpState
	SJ.jumpState = SJC.STATE_IDLE
	SJ.leftGroundThisJump = false
	SJ.airborneTicks = 0
	SJ.prepareTicks = 0
	SJ.jumpFailCooldownUntil = globals.TickCount() + JUMP_FAIL_COOLDOWN_TICKS
	SJ.lastState = SJC.STATE_IDLE
	logJumpStateTransition(fromState, SJC.STATE_IDLE, cmd, pLocal, onGround, reason or "markJumpFailed")
end

local SJ_DEBUG_INTERVAL = 22

local function sjDebugThrottled(key, msg, ...)
	if not (G.Menu.SmartJump and G.Menu.SmartJump.Debug) then
		if not (G.Menu.Visuals and G.Menu.Visuals.Debug_Mode) then
			return
		end
		if not Common.Log.isModuleFilterEnabled("SmartJump") then
			return
		end
	end

	G.SmartJump._debugLast = G.SmartJump._debugLast or {}
	local tick = globals.TickCount()
	local last = G.SmartJump._debugLast[key] or 0
	if tick - last < SJ_DEBUG_INTERVAL then
		return
	end
	G.SmartJump._debugLast[key] = tick
	Log:Debug(msg, ...)
end

local function getPlayerHitbox(player)
	return { player:GetMins(), player:GetMaxs() }
end

local function rotateMoveByView(moveIntent, yaw)
	local rad = math.rad(yaw)
	local cos, sin = math.cos(rad), math.sin(rad)
	return Vector3(cos * moveIntent.x - sin * moveIntent.y, sin * moveIntent.x + cos * moveIntent.y, 0)
end

local function isSurfaceWalkable(normal)
	local angle = math.deg(math.acos(normal:Dot(Vector3(0, 0, 1))))
	return angle < SJC.MAX_WALKABLE_ANGLE
end

local function isPlayerOnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	return (pFlags & FL_ONGROUND) ~= 0
end

local function getTouchDistance()
	return G.Misc.NodeTouchDistance or 16
end

local function getTickInterval()
	local tick = globals.TickInterval()
	if tick <= 0 then
		return 1 / 66.67
	end
	return tick
end

local function oneTickStepLength(maxSpeed)
	return maxSpeed * getTickInterval()
end

--- Manual movement this tick or walking disabled — not bot pathfollow.
local function isManualOverride(cmd)
	if not G.Menu.Main.EnableWalking then
		return true
	end

	if cmd and (cmd:GetForwardMove() ~= 0 or cmd:GetSideMove() ~= 0) then
		if G.currentState == G.States.IDLE then
			local lastManual = G.lastManualMovementTick
			if lastManual and (globals.TickCount() - lastManual) < 66 then
				return true
			end
		end
	end

	return false
end

--- Active path + bot moving (not manual override).
local function isBotPathfollowing(cmd)
	if not G.Navigation.path or #G.Navigation.path == 0 then
		return false
	end
	if isManualOverride(cmd) then
		return false
	end
	if
		G.currentState ~= G.States.MOVING
		and G.currentState ~= G.States.FOLLOWING
		and G.currentState ~= G.States.STUCK
	then
		return false
	end
	return true
end

local function getManualWishDir(cmd)
	local forward = cmd:GetForwardMove()
	local side = cmd:GetSideMove()
	if forward == 0 and side == 0 then
		return nil
	end
	local moveIntent = Vector3(forward, -side, 0)
	local viewAngles = engine.GetViewAngles()
	return Common.Normalize(rotateMoveByView(moveIntent, viewAngles.yaw))
end

local function getActiveWishDir(cmd)
	if G.BotIntendedWishDir and G.BotIntendedWishDir:Length2D() > 0.01 then
		return Common.Normalize(Vector3(G.BotIntendedWishDir.x, G.BotIntendedWishDir.y, 0))
	end
	return getManualWishDir(cmd)
end

--- Fixed corner polyline the bot walks (no per-tick retarget noise).
local function addPolyPoint(points, pos)
	if not pos then
		return
	end
	if #points > 0 then
		if Common.Distance2D(points[#points], pos) < MIN_POLY_POINT_DIST then
			return
		end
	end
	points[#points + 1] = pos
end

local function buildWalkPolyline(origin)
	local points = {}

	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		local startIdx = G.Navigation.currentWaypointIndex or 1
		for i = startIdx, #G.Navigation.waypoints do
			local wp = G.Navigation.waypoints[i]
			addPolyPoint(points, wp and wp.pos)
			if #points >= MAX_PATH_SIM_SEGMENTS then
				return points
			end
		end
		return points
	end

	local path = G.Navigation.path
	if not path or #path == 0 then
		return points
	end

	local n1, n2 = path[1], path[2]
	if n1 and n1.pos then
		if n2 and not Node.IsDoorNode(n1) then
			addPolyPoint(points, PathSteering.getSteeringPoint(origin, n1, n2) or n1.pos)
		else
			addPolyPoint(points, n1.pos)
		end
	end

	for i = 2, #path do
		local node = path[i]
		local nextNode = path[i + 1]
		if not node or not node.pos then
			break
		end
		if nextNode and not Node.IsDoorNode(node) then
			addPolyPoint(points, PathSteering.getSteeringPoint(node.pos, node, nextNode) or node.pos)
		else
			addPolyPoint(points, node.pos)
		end
		if #points >= MAX_PATH_SIM_SEGMENTS then
			break
		end
	end

	return points
end

--- Up 72 → one tick forward step → down. Corners: slide forward then down with startsolid checks.
local function canClearObstacle(hitPos, wishDir, hitbox, maxSpeed, wallTrace)
	if not wishDir or not hitPos then
		return false, 0
	end

	local groundZ = hitPos.z
	local upStart = Vector3(hitPos.x, hitPos.y, groundZ + 1)
	local upEnd = Vector3(hitPos.x, hitPos.y, groundZ) + SJC.MAX_JUMP_HEIGHT

	local upTrace = engine.TraceHull(upStart, upEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if upTrace.startsolid then
		return false, 0
	end
	local headPos = upTrace.endpos

	local stepLen = oneTickStepLength(maxSpeed)
	if stepLen < 1 then
		stepLen = 1
	end

	local fwdEnd = headPos + wishDir * stepLen
	local fwdTrace = engine.TraceHull(headPos, fwdEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if fwdTrace.startsolid then
		return false, 0
	end

	local fwdPos = fwdTrace.endpos
	local downFrom = fwdPos
	local downTo = fwdPos - SJC.MAX_JUMP_HEIGHT

	local downTrace = engine.TraceHull(downFrom, downTo, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if downTrace.startsolid then
		return false, 0
	end
	if downTrace.fraction >= 1 then
		return false, 0
	end
	if not isSurfaceWalkable(downTrace.plane) then
		return false, 0
	end

	local lipZ = downTrace.endpos.z
	local obstacleHeight = lipZ - groundZ
	if obstacleHeight < MIN_STEP_HEIGHT then
		return false, 0
	end
	if obstacleHeight > MAX_CLEAR_HEIGHT then
		return false, 0
	end

	if downTrace.fraction <= 0.01 then
		return false, 0
	end

	-- Sheer wall with no standable ledge above step height
	if wallTrace and wallTrace.fraction < 1 then
		local normal = wallTrace.plane
		local wallAngle = math.deg(math.acos(math.min(1, math.max(-1, normal:Dot(Vector3(0, 0, 1))))))
		if wallAngle > SJC.MAX_WALKABLE_ANGLE and obstacleHeight < MIN_STEP_HEIGHT then
			return false, 0
		end
	end

	G.SmartJump.LastObstacleHeight = lipZ
	G.SmartJump.JumpPeekPos = downTrace.endpos
	return true, obstacleHeight
end

local function isNearPayload(position)
	if not G.World.payloads then
		return false
	end

	for _, payload in pairs(G.World.payloads) do
		if payload and payload:IsValid() then
			local payloadPos = payload:GetAbsOrigin()
			if (position - payloadPos):Length() < 64 then
				return true
			end
		end
	end
	return false
end

--- Real position + wishdir: wall in front with a clear ledge (doors/steps), not polyline-only.
local function shouldJumpAtLiveWall(cmd, pLocal)
	if not isPlayerOnGround(pLocal) then
		return false
	end

	local wishDir = getActiveWishDir(cmd)
	if not wishDir then
		return false
	end

	local origin = pLocal:GetAbsOrigin()
	if isNearPayload(origin) then
		return false
	end

	local hitbox = getPlayerHitbox(pLocal)
	local maxSpeed = GroundMovement.getMaxSpeed(pLocal)
	local stepLen = math.max(oneTickStepLength(maxSpeed) * 2, 12)
	local step = Vector3(0, 0, 18)
	local hullMin, hullMax = hitbox[1], hitbox[2]

	local groundTrace = engine.TraceHull(origin + step, origin, hullMin, hullMax, MASK_PLAYERSOLID)
	local feet = groundTrace.endpos
	local wallTrace = engine.TraceHull(feet + step, feet + step + wishDir * stepLen, hullMin, hullMax, MASK_PLAYERSOLID)

	if wallTrace.fraction >= 0.99 then
		sjDebugThrottled("live_no_wall", "live: no wall (frac=%.2f)", wallTrace.fraction)
		return false
	end

	local clearNow, obstacleHeight = canClearObstacle(wallTrace.endpos, wishDir, hitbox, maxSpeed, wallTrace)
	if clearNow then
		G.SmartJump.PredPos = wallTrace.endpos
		G.SmartJump.HitObstacle = true
		sjDebugThrottled("live_jump", "live: jump OK lip=%.0f frac=%.2f", obstacleHeight or 0, wallTrace.fraction)
		return true
	end

	sjDebugThrottled("live_blocked", "live: wall frac=%.2f but canClear=false", wallTrace.fraction)
	return false
end

function SmartJump.wantsLiveJump(cmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return false
	end
	return shouldJumpAtLiveWall(cmd, pLocal)
end

local function tryLateJumpAtObstacle(simPos, newPos, newVel, wishDir, hitbox, maxSpeed, wallTrace)
	local clearNow = canClearObstacle(newPos, wishDir, hitbox, maxSpeed, wallTrace)
	if not clearNow then
		return false
	end

	local nextPos, _nextVel, hitNext, nextWall =
		GroundMovement.simulateGroundStepHull(newPos, newVel, wishDir, maxSpeed, hitbox[1], hitbox[2], true)

	if not nextPos then
		G.SmartJump.PredPos = newPos
		G.SmartJump.HitObstacle = true
		return true
	end

	if not hitNext then
		return false
	end

	local clearNext, _h = canClearObstacle(nextPos, wishDir, hitbox, maxSpeed, nextWall)
	if not clearNext then
		G.SmartJump.PredPos = newPos
		G.SmartJump.HitObstacle = true
		return true
	end

	return false
end

--- Same wishdir + hull step as MovementController.walkTo, along fixed polyline corners.
---@param checkJump boolean When false, only fills SimulationPath (visualization).
local function simulatePathPolyline(pLocal, checkJump)
	local origin = pLocal:GetAbsOrigin()
	local segments = buildWalkPolyline(origin)
	if #segments == 0 then
		G.SmartJump.SimulationPath = { origin }
		return false
	end

	local hitbox = getPlayerHitbox(pLocal)
	local maxSpeed = GroundMovement.getMaxSpeed(pLocal)
	local touch = getTouchDistance()
	local tickInterval = getTickInterval()
	local peakTicks = math.ceil((SJC.JUMP_FORCE / SJC.GRAVITY) / tickInterval)

	local simPos = origin
	local simVel = Vector3(0, 0, 0)
	local segIndex = 1
	local dest = segments[segIndex]

	G.SmartJump.SimulationPath = { origin }
	if not checkJump then
		G.SmartJump.PredPos = nil
		G.SmartJump.HitObstacle = false
		G.SmartJump.JumpPeekPos = nil
	end

	for _ = 1, peakTicks do
		if not dest then
			break
		end

		local horizSpeed = simVel:Length2D()
		local coastTicks = GroundMovement.getCoastTicks(horizSpeed, maxSpeed)
		local wishDir = GroundMovement.computeWishDirToTarget(simPos, simVel, dest, coastTicks, true)

		if not wishDir then
			if Common.Distance2D(simPos, dest) <= math.max(touch, ARRIVAL_DIST) then
				segIndex = segIndex + 1
				dest = segments[segIndex]
			end
			if not dest then
				break
			end
			wishDir = GroundMovement.computeWishDirToTarget(simPos, simVel, dest, coastTicks, true)
		end

		if not wishDir then
			break
		end

		local newPos, newVel, hitWall, wallTrace =
			GroundMovement.simulateGroundStepHull(simPos, simVel, wishDir, maxSpeed, hitbox[1], hitbox[2], true)

		if not newPos then
			break
		end

		G.SmartJump.SimulationPath[#G.SmartJump.SimulationPath + 1] = newPos

		if checkJump and hitWall then
			if tryLateJumpAtObstacle(simPos, newPos, newVel, wishDir, hitbox, maxSpeed, wallTrace) then
				return true
			end
			return false
		end

		simPos = newPos
		simVel = newVel

		if Common.Distance2D(simPos, dest) <= touch then
			segIndex = segIndex + 1
			dest = segments[segIndex]
		end
	end

	return false
end

local function shouldLateJumpPathMode(pLocal)
	if isNearPayload(pLocal:GetAbsOrigin()) then
		return false
	end
	return simulatePathPolyline(pLocal, true)
end

--- Manual / no path: single wishdir along cmd or bot intent.
local function shouldLateJumpManual(cmd, pLocal)
	local wishDir = nil
	if G.BotIntendedWishDir and G.BotIntendedWishDir:Length2D() > 0.01 then
		wishDir = Common.Normalize(Vector3(G.BotIntendedWishDir.x, G.BotIntendedWishDir.y, 0))
	else
		wishDir = getManualWishDir(cmd)
	end
	if not wishDir then
		return false
	end

	local origin = pLocal:GetAbsOrigin()
	if isNearPayload(origin) then
		return false
	end

	local hitbox = getPlayerHitbox(pLocal)
	local maxSpeed = GroundMovement.getMaxSpeed(pLocal)
	local tickInterval = getTickInterval()
	local peakTicks = math.ceil((SJC.JUMP_FORCE / SJC.GRAVITY) / tickInterval)

	local simPos = origin
	local simVel = Vector3(0, 0, 0)
	local farDest = origin + wishDir * 512
	G.SmartJump.SimulationPath = { origin }

	for _ = 1, peakTicks + 4 do
		local coastTicks = GroundMovement.getCoastTicks(simVel:Length2D(), maxSpeed)
		local stepWish = GroundMovement.computeWishDirToTarget(simPos, simVel, farDest, coastTicks, true) or wishDir

		local newPos, newVel, hitWall, wallTrace =
			GroundMovement.simulateGroundStepHull(simPos, simVel, stepWish, maxSpeed, hitbox[1], hitbox[2], true)

		if not newPos then
			break
		end

		G.SmartJump.SimulationPath[#G.SmartJump.SimulationPath + 1] = newPos

		if hitWall then
			if tryLateJumpAtObstacle(simPos, newPos, newVel, stepWish, hitbox, maxSpeed, wallTrace) then
				return true
			end
			return false
		end

		simPos = newPos
		simVel = newVel
	end

	return false
end

local function shouldLateJump(cmd, pLocal)
	if not pLocal then
		return false
	end
	if SJ.lastLandTick and globals.TickCount() - SJ.lastLandTick < JUMP_LAND_REJUMP_TICKS then
		return false
	end
	if not isPlayerOnGround(pLocal) then
		sjDebugThrottled("airborne", "skip: not on ground (state=%s)", tostring(SJ.jumpState))
		return false
	end

	if shouldJumpAtLiveWall(cmd, pLocal) then
		return true
	end

	if isBotPathfollowing(cmd) then
		local pathResult = shouldLateJumpPathMode(pLocal)
		if not pathResult then
			sjDebugThrottled(
				"path_no_jump",
				"path sim: no jump trigger (segments=%d)",
				#buildWalkPolyline(pLocal:GetAbsOrigin())
			)
		end
		return pathResult
	end

	if isManualOverride(cmd) then
		sjDebugThrottled("manual_override", "skip: manual movement override")
		return false
	end

	return shouldLateJumpManual(cmd, pLocal)
end

--- State transitions at most once per command (CreateMove may run multiple times per tick).
local function advanceJumpState(cmd, pLocal, onGround, hasWishDir, shouldJump)
	local advanceKey = getAdvanceKey(cmd)
	if SJ.lastAdvanceTick == advanceKey then
		return
	end
	SJ.lastAdvanceTick = advanceKey

	local tick = globals.TickCount()

	if SJ.jumpState == SJC.STATE_IDLE then
		if not onGround or not (hasWishDir or shouldJump) then
			return
		end
		if isOnJumpFailCooldown() then
			return
		end
		if shouldJump or shouldLateJump(cmd, pLocal) then
			sjDebugThrottled(
				"jump_start",
				"START jump state=%s wish=%s path=%s",
				tostring(G.currentState),
				tostring(G.BotIntendedWishDir ~= nil),
				tostring(isBotPathfollowing(cmd))
			)
			beginJumpAttempt(cmd, pLocal, onGround, "idle:shouldLateJump")
		else
			sjDebugThrottled(
				"idle_no_trigger",
				"idle: no trigger onGround=%s hasWish=%s state=%s enabled=%s",
				tostring(onGround),
				tostring(hasWishDir),
				tostring(G.currentState),
				tostring(G.Menu.Main.EnableWalking)
			)
		end
	elseif SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		if not onGround then
			markJumpFailed(cmd, pLocal, onGround, "airborneDuringPrepare")
		elseif tick > (SJ.prepareEnterTick or 0) then
			SJ.jumpState = SJC.STATE_CTAP
			SJ.ctapEnterTick = tick
			SJ.ctapTicks = 0
		end
	elseif SJ.jumpState == SJC.STATE_CTAP then
		if tick <= (SJ.ctapEnterTick or 0) then
			return
		end
		SJ.ctapTicks = (SJ.ctapTicks or 0) + 1
		local velocity = pLocal:EstimateAbsVelocity()
		local vz = velocity and velocity.z or 0
		if vz >= JUMP_CTAP_MIN_VZ then
			SJ.jumpState = SJC.STATE_ASCENDING
			if not onGround then
				SJ.airborneTicks = (SJ.airborneTicks or 0) + 1
			end
		elseif not onGround and vz <= 0 then
			markJumpFailed(cmd, pLocal, onGround, "airborneDuringCtap")
		elseif SJ.ctapTicks > 6 then
			markJumpFailed(cmd, pLocal, onGround, "ctapTimeout")
		end
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		if not onGround then
			SJ.airborneTicks = (SJ.airborneTicks or 0) + 1
			if SJ.airborneTicks >= JUMP_MIN_AIRBORNE_TICKS then
				SJ.leftGroundThisJump = true
			end
		end
		local velocity = pLocal:EstimateAbsVelocity()
		local currentPos = pLocal:GetAbsOrigin()
		local shouldUnduck = velocity.z <= 0 and SJ.leftGroundThisJump

		if not shouldUnduck and SJ.leftGroundThisJump and G.Menu.Main.Duck_Grab and G.SmartJump.LastObstacleHeight then
			if currentPos.z > G.SmartJump.LastObstacleHeight then
				local traceStart = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight + 1)
				local traceEnd = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight - 10)
				local hitbox = getPlayerHitbox(pLocal)
				local obstacleTrace = engine.TraceHull(traceStart, traceEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
				if obstacleTrace.fraction < 1 then
					shouldUnduck = true
					SJ.allowLedgeGrabDuck = true
				end
			end
		end

		if shouldUnduck then
			SJ.jumpState = SJC.STATE_DESCENDING
		end
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		if not onGround then
			SJ.airborneTicks = (SJ.airborneTicks or 0) + 1
			if SJ.airborneTicks >= JUMP_MIN_AIRBORNE_TICKS then
				SJ.leftGroundThisJump = true
			end
		elseif onGround and SJ.leftGroundThisJump and (SJ.airborneTicks or 0) >= JUMP_MIN_AIRBORNE_TICKS then
			SJ.jumpState = SJC.STATE_IDLE
			SJ.leftGroundThisJump = false
			SJ.airborneTicks = 0
			SJ.lastLandTick = tick
			SJ.suppressStuckUntilTick = tick + 22
		end
	end
end

--- Duck is limited to JUMP_MAX_DUCK_TICKS per jump attempt (counts game ticks, not CreateMove calls).
---@param allowLedgeGrabExtra boolean|nil Duck_Grab over a lip may exceed the CTAP duck budget.
local function tryApplyDuck(cmd, allowLedgeGrabExtra)
	local used = SJ.duckTicksThisJump or 0
	if not allowLedgeGrabExtra and used >= JUMP_MAX_DUCK_TICKS then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		return false
	end

	local tick = globals.TickCount()
	if SJ.lastDuckCountTick ~= tick then
		SJ.lastDuckCountTick = tick
		SJ.duckTicksThisJump = used + 1
	end

	cmd:SetButtons(cmd.buttons | IN_DUCK)
	return true
end

local function forceUnduck(cmd)
	cmd:SetButtons(cmd.buttons & ~IN_DUCK)
end

--- Ledge-grab duck during ascent (not limited by PREPARE duck budget; matches pre-refactor SmartJump).
local function applyAscendingDuck(cmd)
	cmd:SetButtons(cmd.buttons & ~IN_JUMP)
	cmd:SetButtons(cmd.buttons | IN_DUCK)
end

--- Apply duck/jump buttons every CreateMove call for the current state.
local function applyJumpButtons(cmd, _pLocal, onGround, _hasWishDir)
	cmd:SetButtons(cmd.buttons & ~IN_JUMP)

	if not onGround then
		if SJ.jumpState == SJC.STATE_ASCENDING then
			applyAscendingDuck(cmd)
		else
			forceUnduck(cmd)
		end
		return
	end

	if SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		tryApplyDuck(cmd)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
	elseif SJ.jumpState == SJC.STATE_CTAP then
		if onGround then
			forceUnduck(cmd)
			cmd:SetButtons(cmd.buttons | IN_JUMP)
		else
			forceUnduck(cmd)
		end
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		forceUnduck(cmd)
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		forceUnduck(cmd)
	end
end

function SmartJump.Main(cmd)
	if not G.Menu.SmartJump or not G.Menu.SmartJump.Enable then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.RequestEmergencyJump = false
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() or pLocal:IsDormant() then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.RequestEmergencyJump = false
		return
	end

	local onGround = isPlayerOnGround(pLocal)
	local shouldJump = false

	if G.SmartJump.RequestEmergencyJump then
		if SJ.jumpState == SJC.STATE_IDLE and onGround and not isOnJumpFailCooldown() then
			shouldJump = true
			G.SmartJump.RequestEmergencyJump = false
			beginJumpAttempt(cmd, pLocal, onGround, "RequestEmergencyJump")
		elseif SJ.jumpState ~= SJC.STATE_IDLE then
			-- Jump already in progress; do not queue another beginJumpAttempt next tick.
			G.SmartJump.RequestEmergencyJump = false
		end
		-- IDLE but on cooldown or in air: keep flag until we can start.
	end

	local hasWishDir = getManualWishDir(cmd) ~= nil
		or (G.BotIntendedWishDir and G.BotIntendedWishDir:Length2D() > 0.01)
		or isBotPathfollowing(cmd)

	applyJumpButtons(cmd, pLocal, onGround, hasWishDir)
	advanceJumpState(cmd, pLocal, onGround, hasWishDir, shouldJump)

	if SJ.stateStartTime == nil then
		SJ.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - SJ.stateStartTime > JUMP_STATE_TIMEOUT_TICKS then
		if SJ.jumpState ~= SJC.STATE_IDLE then
			markJumpFailed(cmd, pLocal, onGround, "timeout:" .. tostring(JUMP_STATE_TIMEOUT_TICKS) .. "ticks")
		end
	end

	if SJ.lastState ~= SJ.jumpState then
		logJumpStateTransition(SJ.lastState, SJ.jumpState, cmd, pLocal, onGround, "stateMachine")
		SJ.stateStartTime = globals.TickCount()
		SJ.lastState = SJ.jumpState
	end

	G.SmartJump.ShouldJump = shouldJump
end

local function onDrawSmartJump()
	if not G.Menu.SmartJump or not G.Menu.SmartJump.Enable then
		return
	end
	if not (G.Menu.Visuals and G.Menu.Visuals.showSmartJump) then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if pLocal and pLocal:IsAlive() and isBotPathfollowing(nil) then
		simulatePathPolyline(pLocal, false)
	end

	if G.SmartJump.PredPos then
		local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
		if screenPos then
			draw.Color(255, 0, 0, 255)
			draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
		end
	end

	if G.SmartJump.SimulationPath and #G.SmartJump.SimulationPath > 1 then
		for i = 1, #G.SmartJump.SimulationPath - 1 do
			local a = client.WorldToScreen(G.SmartJump.SimulationPath[i])
			local b = client.WorldToScreen(G.SmartJump.SimulationPath[i + 1])
			if a and b then
				draw.Color(0, 150, 255, 180)
				draw.Line(a[1], a[2], b[1], b[2])
			end
		end
	end

	local origin = pLocal and pLocal:GetAbsOrigin()
	if origin then
		local corners = buildWalkPolyline(origin)
		for i = 1, #corners do
			local s = client.WorldToScreen(corners[i])
			if s then
				draw.Color(255, 200, 0, 200)
				draw.FilledRect(s[1] - 3, s[2] - 3, s[1] + 3, s[2] + 3)
			end
			if i > 1 then
				local a = client.WorldToScreen(corners[i - 1])
				local b = s
				if a and b then
					draw.Color(255, 200, 0, 120)
					draw.Line(a[1], a[2], b[1], b[2])
				end
			end
		end
	end

	if G.SmartJump.JumpPeekPos then
		local s = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if s then
			draw.Color(0, 255, 0, 255)
			draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
		end
	end
end

callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", onDrawSmartJump)

return SmartJump
