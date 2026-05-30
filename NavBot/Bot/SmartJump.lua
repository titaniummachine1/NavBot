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
local MAX_PATH_SIM_TARGETS = 12

local SmartJump = {}

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
	return (pFlags & FL_ONGROUND) == FL_ONGROUND
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
	if G.currentState ~= G.States.MOVING and G.currentState ~= G.States.FOLLOWING then
		return false
	end
	return true
end

local function getManualWishDir(cmd)
	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveIntent:Length() < 1 then
		return nil
	end
	local viewAngles = engine.GetViewAngles()
	return Common.Normalize(rotateMoveByView(moveIntent, viewAngles.yaw))
end

local function getPathNodeTarget(simPos, pathIndex)
	local path = G.Navigation.path
	local node = path and path[pathIndex]
	if not node or not node.pos then
		return nil
	end

	local nextNode = path[pathIndex + 1]
	if nextNode and not Node.IsDoorNode(node) then
		return PathSteering.getSteeringPoint(simPos, node, nextNode) or node.pos
	end

	return node.pos
end

--- Waypoints when active; otherwise path nodes (portal steering points).
local function buildPathSimTargets(origin)
	local targets = {}

	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		local startIdx = G.Navigation.currentWaypointIndex or 1
		for i = startIdx, #G.Navigation.waypoints do
			local wp = G.Navigation.waypoints[i]
			if wp and wp.pos then
				targets[#targets + 1] = wp.pos
			end
			if #targets >= MAX_PATH_SIM_TARGETS then
				return targets
			end
		end
		return targets
	end

	local path = G.Navigation.path
	if not path then
		return targets
	end

	local limit = math.min(#path, MAX_PATH_SIM_TARGETS)
	for i = 1, limit do
		local pt = getPathNodeTarget(origin, i)
		if pt then
			targets[#targets + 1] = pt
		end
	end

	return targets
end

local function refreshPathTarget(simPos, targets, targetIndex)
	local pos = targets[targetIndex]
	if not pos then
		return nil
	end
	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		return pos
	end
	return getPathNodeTarget(simPos, targetIndex) or pos
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
		if payload:IsValid() then
			local payloadPos = payload:GetAbsOrigin()
			if (position - payloadPos):Length() < 200 then
				return true
			end
			local groundPos = Vector3(payloadPos.x, payloadPos.y, payloadPos.z - 80)
			if (position - groundPos):Length() < 150 then
				return true
			end
		end
	end
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

local function simulateWalkTowardTarget(simPos, simVel, targetPos, maxSpeed, hitbox)
	local toTarget = Vector3(targetPos.x - simPos.x, targetPos.y - simPos.y, 0)
	local dist = toTarget:Length2D()
	if dist < 0.5 then
		return simPos, simVel, false, nil
	end

	local wishDir = toTarget / dist
	return GroundMovement.simulateGroundStepHull(simPos, simVel, wishDir, maxSpeed, hitbox[1], hitbox[2], true)
end

--- Path mode: chain targets (current → next node …) until jump-peek ticks or obstacle.
local function shouldLateJumpPathMode(pLocal)
	local origin = pLocal:GetAbsOrigin()
	if isNearPayload(origin) then
		return false
	end

	local targets = buildPathSimTargets(origin)
	if #targets == 0 then
		return false
	end

	local hitbox = getPlayerHitbox(pLocal)
	local maxSpeed = GroundMovement.getMaxSpeed(pLocal)
	local touch = getTouchDistance()
	local tickInterval = getTickInterval()
	local peakTicks = math.ceil((SJC.JUMP_FORCE / SJC.GRAVITY) / tickInterval)

	local simPos = origin
	local simVel = Vector3(0, 0, 0)
	local targetIndex = 1
	local targetPos = targets[targetIndex]

	G.SmartJump.SimulationPath = { origin }

	for _ = 1, peakTicks do
		if not targetPos then
			break
		end

		local newPos, newVel, hitWall, wallTrace = simulateWalkTowardTarget(simPos, simVel, targetPos, maxSpeed, hitbox)
		if not newPos then
			break
		end

		G.SmartJump.SimulationPath[#G.SmartJump.SimulationPath + 1] = newPos

		local wishDir = Common.Normalize(Vector3(targetPos.x - simPos.x, targetPos.y - simPos.y, 0))
		if wishDir then
			if hitWall then
				if tryLateJumpAtObstacle(simPos, newPos, newVel, wishDir, hitbox, maxSpeed, wallTrace) then
					return true
				end
				return false
			end
		end

		simPos = newPos
		simVel = newVel

		if Common.Distance2D(simPos, targetPos) <= touch then
			targetIndex = targetIndex + 1
			targetPos = refreshPathTarget(simPos, targets, targetIndex)
		end
	end

	return false
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
	local simVel = Vector3(wishDir.x * maxSpeed, wishDir.y * maxSpeed, 0)
	G.SmartJump.SimulationPath = { origin }

	for _ = 1, peakTicks + 4 do
		local newPos, newVel, hitWall, wallTrace =
			GroundMovement.simulateGroundStepHull(simPos, simVel, wishDir, maxSpeed, hitbox[1], hitbox[2], true)

		if not newPos then
			break
		end

		G.SmartJump.SimulationPath[#G.SmartJump.SimulationPath + 1] = newPos

		if hitWall then
			if tryLateJumpAtObstacle(simPos, newPos, newVel, wishDir, hitbox, maxSpeed, wallTrace) then
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
	if not pLocal or not isPlayerOnGround(pLocal) then
		return false
	end

	if isBotPathfollowing(cmd) then
		return shouldLateJumpPathMode(pLocal)
	end

	return shouldLateJumpManual(cmd, pLocal)
end

function SmartJump.Main(cmd)
	if not G.Menu.SmartJump.Enable then
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
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
			end
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
		elseif onGround then
			SJ.jumpState = SJC.STATE_IDLE
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
