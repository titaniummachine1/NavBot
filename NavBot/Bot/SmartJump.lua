local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local GroundMovement = require("NavBot.Bot.GroundMovement")

local Log = Common.Log.new("SmartJump")

Log.Level = 0
local SJ = G.SmartJump
local SJC = G.SmartJump.Constants

local STEP_Z = 18
local STEP_VEC = Vector3(0, 0, STEP_Z)
local FORWARD_PROBE = 1
local FORWARD_SLIDE = 24
local MIN_STEP_HEIGHT = 18
local MAX_CLEAR_HEIGHT = 72

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

--- Bot simulated wishdir first; else manual cmd move rotated by view (same basis as walkTo).
local function getWishDir(cmd)
	if G.BotIntendedWishDir and G.BotIntendedWishDir:Length2D() > 0.01 then
		local dir = G.BotIntendedWishDir
		dir.z = 0
		return Common.Normalize(dir)
	end

	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveIntent:Length() < 1 then
		return nil
	end

	local viewAngles = engine.GetViewAngles()
	return Common.Normalize(rotateMoveByView(moveIntent, viewAngles.yaw))
end

--- Into wall 1u, up 72, forward (slide corners), down — can we land on top?
local function canClearObstacle(hitPos, wishDir, hitbox)
	if not wishDir or not hitPos then
		return false, 0
	end

	local probe = hitPos + wishDir * FORWARD_PROBE
	local headTarget = probe + SJC.MAX_JUMP_HEIGHT

	local upTrace = engine.TraceHull(probe, headTarget, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if upTrace.startsolid then
		return false, 0
	end
	local headPos = upTrace.endpos

	local fwdEnd = headPos + wishDir * FORWARD_SLIDE
	local fwdTrace = engine.TraceHull(headPos, fwdEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local fwdPos = fwdTrace.endpos

	local downTrace = engine.TraceHull(fwdPos, fwdPos - SJC.MAX_JUMP_HEIGHT, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if downTrace.startsolid or downTrace.fraction >= 1 then
		return false, 0
	end
	if not isSurfaceWalkable(downTrace.plane) then
		return false, 0
	end

	local lipZ = downTrace.endpos.z
	local obstacleHeight = lipZ - hitPos.z
	if obstacleHeight < MIN_STEP_HEIGHT or obstacleHeight > MAX_CLEAR_HEIGHT then
		return false, 0
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

--- Walk along wishdir with ground physics; jump only on last tick that can still clear (late jump).
local function shouldLateJump(cmd, pLocal)
	if not pLocal or not isPlayerOnGround(pLocal) then
		return false
	end

	local wishDir = getWishDir(cmd)
	if not wishDir then
		return false
	end

	local origin = pLocal:GetAbsOrigin()
	if isNearPayload(origin) then
		return false
	end

	local hitbox = getPlayerHitbox(pLocal)
	local maxSpeed = GroundMovement.getMaxSpeed(pLocal)
	local vel = pLocal:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0
	local horizSpeed = math.max(vel:Length2D(), maxSpeed * 0.85)
	vel = Vector3(wishDir.x * horizSpeed, wishDir.y * horizSpeed, 0)

	local tickInterval = globals.TickInterval()
	if tickInterval <= 0 then
		tickInterval = 1 / 66.67
	end

	local peakTicks = math.ceil((SJC.JUMP_FORCE / SJC.GRAVITY) / tickInterval)
	local maxWalkTicks = peakTicks + 8

	local simPos = origin
	local simVel = vel
	G.SmartJump.SimulationPath = { origin }

	for _ = 1, maxWalkTicks do
		local newPos, newVel, hitWall = GroundMovement.simulateGroundStepHull(
			simPos,
			simVel,
			wishDir,
			maxSpeed,
			hitbox[1],
			hitbox[2],
			true
		)

		if not newPos then
			break
		end

		G.SmartJump.SimulationPath[#G.SmartJump.SimulationPath + 1] = newPos

		if hitWall then
			local clearNow, _height = canClearObstacle(newPos, wishDir, hitbox)
			if not clearNow then
				return false
			end

			local nextPos, nextVel, hitNext = GroundMovement.simulateGroundStepHull(
				newPos,
				newVel,
				wishDir,
				maxSpeed,
				hitbox[1],
				hitbox[2],
				true
			)

			if not nextPos then
				if isNearPayload(newPos) then
					return false
				end
				G.SmartJump.PredPos = newPos
				G.SmartJump.HitObstacle = true
				return true
			end

			if not hitNext then
				-- Not flush with wall yet — keep walking toward it
				simPos = nextPos
				simVel = nextVel
			else
				local clearNext = canClearObstacle(nextPos, wishDir, hitbox)
				if not clearNext then
					if isNearPayload(newPos) then
						return false
					end
					G.SmartJump.PredPos = newPos
					G.SmartJump.HitObstacle = true
					Log:Debug("SmartJump: late jump at obstacle")
					return true
				end
				simPos = nextPos
				simVel = nextVel
			end
		else
			simPos = newPos
			simVel = newVel
		end
	end

	return false
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

	local hasWishDir = getWishDir(cmd) ~= nil

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
				local obstacleTrace =
					engine.TraceHull(traceStart, traceEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
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
