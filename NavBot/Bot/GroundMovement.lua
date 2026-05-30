--[[
Ground movement physics (from Auto_Trickstab SimulateDash / CalculateOptimalWishdir)
Friction + sv_accelerate ground model for optimal wish direction each tick.
]]

local GroundMovement = {}

local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180

local DEFAULT_FRICTION = 4
local DEFAULT_ACCELERATE = 10
local DEFAULT_STOP_SPEED = 100
local DEFAULT_MAX_SPEED = 320
local DEFAULT_CMD_SPEED = 450

local function getTickInterval()
	local tick = globals.TickInterval()
	if tick <= 0 then
		return 1 / 66.67
	end
	return tick
end

local function getFriction()
	local ok, val = pcall(client.GetConVar, "sv_friction")
	if ok and val and val > 0 then
		return val
	end
	return DEFAULT_FRICTION
end

local function getAccelerate()
	local ok, val = pcall(client.GetConVar, "sv_accelerate")
	if ok and val and val > 0 then
		return val
	end
	return DEFAULT_ACCELERATE
end

local function horizontalDir(from, to)
	local dir = Vector3(to.x - from.x, to.y - from.y, 0)
	local len = dir:Length2D()
	if len < 0.001 then
		return nil, 0
	end
	return dir / len, len
end

---@param velocity Vector3
---@param onGround boolean
---@return Vector3
function GroundMovement.applyFriction(velocity, onGround)
	if not velocity or not onGround then
		return velocity or Vector3(0, 0, 0)
	end

	local speed = velocity:Length()
	if speed < DEFAULT_STOP_SPEED then
		return Vector3(0, 0, 0)
	end

	local tick = getTickInterval()
	local friction = getFriction() * tick
	local control = speed < DEFAULT_STOP_SPEED and DEFAULT_STOP_SPEED or speed
	local drop = control * friction
	local newSpeed = speed - drop

	if newSpeed < 0 then
		newSpeed = 0
	end

	if newSpeed < speed then
		return velocity * (newSpeed / speed)
	end

	return velocity
end

--- One tick of ground acceleration along wishdir (TF2 ProcessMovement style).
---@param velocity Vector3
---@param wishdir Vector3
---@param maxSpeed number
---@param onGround boolean
---@return Vector3
function GroundMovement.applyGroundAccel(velocity, wishdir, maxSpeed, onGround)
	if not onGround or not wishdir then
		return velocity
	end

	local tick = getTickInterval()
	local accel = getAccelerate()
	local vel = Vector3(velocity.x, velocity.y, velocity.z)

	local currentSpeed = vel:Dot(wishdir)
	local addSpeed = maxSpeed - currentSpeed
	if addSpeed > 0 then
		local accelSpeed = math.min(accel * maxSpeed * tick, addSpeed)
		vel = vel + wishdir * accelSpeed
	end

	local horizSpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	if horizSpeed > maxSpeed then
		local scale = maxSpeed / horizSpeed
		vel = Vector3(vel.x * scale, vel.y * scale, vel.z)
	end

	return vel
end

--- Coast with friction only (no input), like CalculateOptimalWishdir pass 1.
---@param startPos Vector3
---@param startVel Vector3
---@param ticks number
---@param onGround boolean
---@return Vector3 pos, Vector3 vel
function GroundMovement.predictCoast(startPos, startVel, ticks, onGround)
	local tick = getTickInterval()
	local pos = Vector3(startPos.x, startPos.y, startPos.z)
	local vel = Vector3(startVel.x, startVel.y, startVel.z)

	for _ = 1, ticks do
		pos = pos + vel * tick
		vel = GroundMovement.applyFriction(vel, onGround)
	end

	return pos, vel
end

--- Wish direction after coasting: where we should accelerate after friction bleeds velocity.
---@param startPos Vector3
---@param startVel Vector3
---@param dest Vector3
---@param coastTicks number|nil
---@param onGround boolean
---@return Vector3|nil wishdir
function GroundMovement.computeWishDirToTarget(startPos, startVel, dest, coastTicks, onGround)
	coastTicks = coastTicks or 1
	onGround = onGround ~= false

	local coastPos, _coastVel
	if coastTicks > 0 and onGround then
		coastPos, _coastVel = GroundMovement.predictCoast(startPos, startVel, coastTicks, onGround)
	else
		coastPos = startPos
	end

	local wishdir, dist = horizontalDir(coastPos, dest)
	if not wishdir then
		return nil
	end

	-- Already at target after coast
	if dist < 1.5 then
		return nil
	end

	return wishdir
end

--- How many ticks to coast before aiming (more speed → slightly more lookahead).
function GroundMovement.getCoastTicks(horizSpeed, maxSpeed)
	if not maxSpeed or maxSpeed <= 0 then
		return 1
	end
	local ratio = horizSpeed / maxSpeed
	if ratio < 0.25 then
		return 0
	end
	if ratio < 0.6 then
		return 1
	end
	return 2
end

--- Convert world wish direction into forward/side move (view-relative).
---@param cmd UserCmd
---@param wishdir Vector3
---@param cmdSpeed number|nil
function GroundMovement.wishDirToCmd(cmd, wishdir, cmdSpeed)
	cmdSpeed = cmdSpeed or DEFAULT_CMD_SPEED

	local targetYaw = (math.atan(wishdir.y, wishdir.x) + TWO_PI) % TWO_PI
	local _, currentYaw = cmd:GetViewAngles()
	currentYaw = currentYaw * DEG_TO_RAD

	local yawDiff = (targetYaw - currentYaw + math.pi) % TWO_PI - math.pi

	cmd:SetForwardMove(math.cos(yawDiff) * cmdSpeed)
	cmd:SetSideMove(math.sin(-yawDiff) * cmdSpeed)
end

--- Simulate one tick forward with friction + accel; returns post-tick position.
function GroundMovement.simulateGroundStep(pos, vel, wishdir, maxSpeed, onGround)
	local tick = getTickInterval()
	vel = GroundMovement.applyFriction(vel, onGround)
	vel = GroundMovement.applyGroundAccel(vel, wishdir, maxSpeed, onGround)
	return pos + vel * tick, vel
end

local STEP_HEIGHT = Vector3(0, 0, 18)

--- One ground physics tick with hull collision (for SmartJump prediction).
---@return Vector3|nil newPos
---@return Vector3 newVel
---@return boolean hitWall
---@return table|nil wallTrace
function GroundMovement.simulateGroundStepHull(pos, vel, wishdir, maxSpeed, hullMin, hullMax, onGround)
	local tick = getTickInterval()
	vel = GroundMovement.applyFriction(vel, onGround)
	vel = GroundMovement.applyGroundAccel(vel, wishdir, maxSpeed, onGround)

	local targetPos = pos + vel * tick
	local step = STEP_HEIGHT

	local startTrace = engine.TraceHull(pos + step, pos, hullMin, hullMax, MASK_PLAYERSOLID)
	local startOnGround = startTrace.endpos

	local upTrace = engine.TraceHull(targetPos + step, targetPos, hullMin, hullMax, MASK_PLAYERSOLID)
	local targetRaised = upTrace.endpos

	local wallTrace = engine.TraceHull(startOnGround + step, targetRaised + step, hullMin, hullMax, MASK_PLAYERSOLID)
	local newPos = targetRaised
	if wallTrace.fraction > 0 then
		newPos = wallTrace.endpos
	end

	local groundTrace = engine.TraceHull(newPos, newPos - step * 2, hullMin, hullMax, MASK_PLAYERSOLID)
	if groundTrace.fraction >= 1 then
		return nil, vel, false, nil
	end
	newPos = groundTrace.endpos

	groundTrace = engine.TraceHull(newPos, newPos - step, hullMin, hullMax, MASK_PLAYERSOLID)
	if groundTrace.fraction >= 1 then
		return nil, vel, false, nil
	end
	newPos = groundTrace.endpos

	local hitWall = wallTrace.fraction < 1
	if hitWall then
		local wallNormal = wallTrace.plane
		local up = Vector3(0, 0, 1)
		local wallAngle = math.deg(math.acos(wallNormal:Dot(up)))
		if wallAngle > 55 then
			local dot = vel:Dot(wallNormal)
			vel = vel - wallNormal * dot
		end
	end

	return newPos, vel, hitWall, wallTrace
end

function GroundMovement.getMaxSpeed(player)
	local cap = player and player:GetPropFloat("m_flMaxspeed")
	if cap and cap > 0 then
		return cap
	end
	return DEFAULT_MAX_SPEED
end

function GroundMovement.isOnGround(player)
	if player and player.IsOnGround and player:IsOnGround() then
		return true
	end
	local flags = player and player:GetPropInt("m_fFlags") or 0
	return (flags & 1) ~= 0
end

return GroundMovement
