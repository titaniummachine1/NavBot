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
		shouldJump = true
		G.SmartJump.RequestEmergencyJump = false
		SJ.jumpState = SJC.STATE_PREPARE_JUMP
	end

	local hasWishDir = getManualWishDir(cmd) ~= nil
		or (G.BotIntendedWishDir and G.BotIntendedWishDir:Length2D() > 0.01)
		or isBotPathfollowing(cmd)

	if SJ.jumpState == SJC.STATE_IDLE then
		if onGround and (hasWishDir or shouldJump) then
			if shouldJump or shouldLateJump(cmd, pLocal) then
				sjDebugThrottled(
					"jump_start",
					"START jump state=%s wish=%s path=%s",
					tostring(G.currentState),
					tostring(G.BotIntendedWishDir ~= nil),
					tostring(isBotPathfollowing(cmd))
				)
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
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
		else
			sjDebugThrottled("idle_wait", "idle: wait onGround=%s hasWish=%s", tostring(onGround), tostring(hasWishDir))
		end
	elseif SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		SJ.jumpState = SJC.STATE_CTAP
	elseif SJ.jumpState == SJC.STATE_CTAP then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		SJ.jumpState = SJC.STATE_ASCENDING
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		local currentPos = pLocal:GetAbsOrigin()
		local shouldUnduck = velocity.z <= 0

		if not shouldUnduck and G.Menu.Main.Duck_Grab and G.SmartJump.LastObstacleHeight then
			if currentPos.z > G.SmartJump.LastObstacleHeight then
				local traceStart = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight + 1)
				local traceEnd = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight - 10)
				local hitbox = getPlayerHitbox(pLocal)
				local obstacleTrace = engine.TraceHull(traceStart, traceEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
				if obstacleTrace.fraction < 1 then
					shouldUnduck = true
				end
			end
		end

		if shouldUnduck then
			SJ.jumpState = SJC.STATE_DESCENDING
		end
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		if not onGround and hasWishDir and shouldLateJump(cmd, pLocal) then
			cmd:SetButtons(cmd.buttons & ~IN_DUCK)
			cmd:SetButtons(cmd.buttons | IN_JUMP)
			SJ.jumpState = SJC.STATE_PREPARE_JUMP
		elseif onGround then
			SJ.jumpState = SJC.STATE_IDLE
		end
	end

	if not SJ.stateStartTime then
		SJ.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - SJ.stateStartTime > 132 then
		SJ.jumpState = SJC.STATE_IDLE
	end

	if SJ.lastState ~= SJ.jumpState then
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
