--[[
Movement Controller - TF2 ground physics walk (Auto_Trickstab friction + accel model)
]]

local G = require("NavBot.Core.Globals")
local Common = require("NavBot.Core.Common")
local GroundMovement = require("NavBot.Bot.GroundMovement")

local MovementController = {}

local ARRIVAL_DIST = 1.5

--- Same wishdir walkTo would use (coast + accel model); nil if at destination.
function MovementController.computeWishDir(player, dest)
	if not (player and dest) then
		return nil
	end

	local pos = player:GetAbsOrigin()
	if not pos then
		return nil
	end

	local toDest = dest - pos
	toDest.z = 0
	if toDest:Length2D() < ARRIVAL_DIST then
		return nil
	end

	local onGround = GroundMovement.isOnGround(player)
	local maxSpeed = GroundMovement.getMaxSpeed(player)
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0

	local horizSpeed = vel:Length2D()
	local coastTicks = onGround and GroundMovement.getCoastTicks(horizSpeed, maxSpeed) or 0
	return GroundMovement.computeWishDirToTarget(pos, vel, dest, coastTicks, onGround)
end

--- Walk toward dest using simulated friction/coast wish direction + optimal ground accel input.
function MovementController.walkTo(cmd, player, dest)
	if not (cmd and player and dest) then
		return
	end

	local pos = player:GetAbsOrigin()
	if not pos then
		return
	end

	local toDest = dest - pos
	toDest.z = 0
	if toDest:Length2D() < ARRIVAL_DIST then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	local onGround = GroundMovement.isOnGround(player)
	local maxSpeed = GroundMovement.getMaxSpeed(player)
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0

	local horizSpeed = vel:Length2D()
	local coastTicks = onGround and GroundMovement.getCoastTicks(horizSpeed, maxSpeed) or 0
	local wishdir = GroundMovement.computeWishDirToTarget(pos, vel, dest, coastTicks, onGround)

	if not wishdir then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	-- Air: still steer toward target; ground uses full cmd speed cap
	local cmdSpeed = math.min(maxSpeed + 1, 450)
	GroundMovement.wishDirToCmd(cmd, wishdir, cmdSpeed)
end

--- Handle camera rotation if LookingAhead is enabled AND walking is enabled
function MovementController.handleCameraRotation(userCmd, targetPos)
	if not G.Menu.Main.EnableWalking or not G.Menu.Main.LookingAhead then
		return
	end

	local Lib = Common.Lib
	local WPlayer = Lib.TF2.WPlayer
	local pLocalWrapped = WPlayer.GetLocal()
	local angles = Lib.Utils.Math.PositionAngles(pLocalWrapped:GetEyePos(), targetPos)
	angles.x = 0

	local currentAngles = userCmd.viewangles
	local deltaAngles = { x = angles.x - currentAngles.x, y = angles.y - currentAngles.y }
	deltaAngles.y = ((deltaAngles.y + 180) % 360) - 180
	angles = EulerAngles(
		currentAngles.x + deltaAngles.x * 0.05,
		currentAngles.y + deltaAngles.y * G.Menu.Main.smoothFactor,
		0
	)
	engine.SetViewAngles(angles)
end

return MovementController
