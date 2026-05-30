--[[
Node Skipper - Per-tick node skipping with menu-controlled limits
Pass detection uses path progress + portal reach (PathSteering), not bearing-to-center.
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local isNavigable = require("NavBot.Navigation.isWalkable.isNavigable")
local Node = require("NavBot.Navigation.Node")
local PathSteering = require("NavBot.Navigation.PathSteering")
local WorkManager = require("NavBot.WorkManager")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

local function isDoorNode(node)
	return node and not node._minX
end

local function lockIntentAfterSkip(playerPos)
	local path = G.Navigation.path
	if path and path[1] then
		PathSteering.lockIntentTowardNode(playerPos, path[1], path[2])
	end
end

local function checkPassedCurrentNode(playerPos, currentNode, nextNode)
	return PathSteering.hasPassedNode(playerPos, currentNode, nextNode)
end

local function skipGoalPos(playerPos, nextNode, afterNext)
	if afterNext and afterNext.pos then
		return PathSteering.getSteeringPoint(playerPos, nextNode, afterNext)
	end
	return nextNode.pos
end

local function trySkipCurrentNode(playerPos, currentNode, nextNode, reason, goalOverride)
	if isDoorNode(currentNode) or isDoorNode(nextNode) then
		Log:Debug("SKIP blocked (door): %s", reason)
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local goalPos = goalOverride or skipGoalPos(playerPos, nextNode, nil)
	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, goalPos, currentArea, true, allowJump)
	if not (success and canSkip) then
		Log:Debug("SKIP blocked (not walkable): %s -> %s (%s)", tostring(currentNode.id), tostring(nextNode.id), reason)
		return false
	end

	local missedNode = table.remove(G.Navigation.path, 1)
	G.Navigation.pathHistory = G.Navigation.pathHistory or {}
	table.insert(G.Navigation.pathHistory, 1, missedNode)
	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()

	Log:Info("Skipped node %s (%s), targeting %s", tostring(missedNode.id), reason, tostring(nextNode.id))
	return true
end

function NodeSkipper.Reset()
	G.Navigation.nodePassTrack = nil
end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not WorkManager.attemptWork(1, "node_skipping") then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]
	if not (currentNode and currentNode.pos and nextNode and nextNode.pos) then
		return false
	end

	local passed, passReason = checkPassedCurrentNode(playerPos, currentNode, nextNode)
	if passed and trySkipCurrentNode(playerPos, currentNode, nextNode, passReason) then
		lockIntentAfterSkip(playerPos)
		G.Navigation.currentNodeIndex = 1
		return true
	end

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	local steerCurrent = PathSteering.getSteeringPoint(playerPos, currentNode, nextNode)
	local steerNext = PathSteering.getSteeringPoint(playerPos, nextNode, path[3])
	local distPlayerToNext = Common.Distance2D(playerPos, steerNext or nextNode.pos)
	local distCurrentToNext = Common.Distance2D(steerCurrent or currentNode.pos, steerNext or nextNode.pos)

	if distPlayerToNext < distCurrentToNext then
		if trySkipCurrentNode(playerPos, currentNode, nextNode, "closer_to_next") then
			lockIntentAfterSkip(playerPos)
			G.Navigation.currentNodeIndex = 1
			return true
		end
	end

	if #path < 3 then
		return false
	end

	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	local skipTarget = path[3]
	if not (skipTarget and skipTarget.pos) then
		return false
	end

	if isDoorNode(path[1]) or isDoorNode(path[2]) or isDoorNode(skipTarget) then
		Log:Debug("FORWARD SKIP blocked: door node in candidate segment")
		return false
	end

	local goalPos = skipGoalPos(playerPos, skipTarget, path[4])
	local distToTarget = Common.Distance3D(playerPos, goalPos)
	if distToTarget > maxSkipRange then
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, goalPos, currentArea, true, allowJump)
	if not (success and canSkip) then
		return false
	end

	G.Navigation.pathHistory = G.Navigation.pathHistory or {}

	local skipped1 = table.remove(path, 1)
	if skipped1 then
		table.insert(G.Navigation.pathHistory, 1, skipped1)
	end
	local skipped2 = table.remove(path, 1)
	if skipped2 then
		table.insert(G.Navigation.pathHistory, 1, skipped2)
	end

	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()
	lockIntentAfterSkip(playerPos)

	Log:Info("FORWARD SKIP: bypassed 2 nodes (direct path to %s, range %.0f)", tostring(skipTarget.id), maxSkipRange)
	G.Navigation.currentNodeIndex = 1
	return true
end

return NodeSkipper
