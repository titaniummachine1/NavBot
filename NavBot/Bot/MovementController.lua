--[[
Movement Controller - TF2 ground physics walk (Auto_Trickstab friction + accel model)
]]

local G = require("NavBot.Core.Globals")
local Common = require("NavBot.Core.Common")
local GroundMovement = require("NavBot.Bot.GroundMovement")

local MovementController = {}

local ARRIVAL_DIST = 1.5

--- Walk toward dest. Stops only on the final path node; intermediate apexes keep full speed.
function MovementController.walkTo(cmd, player, dest)
	if not (cmd and player and dest) then
		return
	end

	local pos = player:GetAbsOrigin()
	if not pos then
		return
	end

	local path = G.Navigation.path
	local isFinalWaypoint = not path or #path <= 1

	local toDest = dest - pos
	toDest.z = 0
	if isFinalWaypoint and toDest:Length2D() < ARRIVAL_DIST then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	local onGround = GroundMovement.isOnGround(player)
	local maxSpeed = GroundMovement.getMaxSpeed(player)
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0

	local wishdir = GroundMovement.computeWalkWishDir(pos, vel, dest, maxSpeed, onGround, isFinalWaypoint)
	if not wishdir then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

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
