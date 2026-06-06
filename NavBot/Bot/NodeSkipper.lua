--[[
Node Skipper - Single-node skip only, validated by NavPredict.CanSkip.
Pass detection from PathSteering; no multi-node forward skip.
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local NavPredict = require("NavBot.Navigation.Prediction.NavPredict")
local Node = require("NavBot.Navigation.Node")
local PathSteering = require("NavBot.Navigation.PathSteering")
local WorkManager = require("NavBot.WorkManager")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

local lastBlockedLogKey = nil
local lastBlockedLogTick = 0
local BLOCKED_LOG_INTERVAL = 66

local function lockIntentAfterSkip(playerPos)
	local path = G.Navigation.path
	if path and path[1] then
		PathSteering.lockIntentTowardNode(playerPos, path[1], path[2])
	end
end

local function logSkipBlocked(currentNode, nextNode, reason)
	local key = tostring(currentNode.id) .. "->" .. tostring(nextNode.id) .. ":" .. reason
	local now = globals.TickCount()
	if key == lastBlockedLogKey and (now - lastBlockedLogTick) < BLOCKED_LOG_INTERVAL then
		return
	end
	lastBlockedLogKey = key
	lastBlockedLogTick = now
	Log:Debug("SKIP blocked (not walkable): %s -> %s (%s)", tostring(currentNode.id), tostring(nextNode.id), reason)
end

local function canSkipSegment(playerPos, goalPos, fromAreaNode, allowJump)
	if not fromAreaNode then
		return false
	end
	local success, canSkip = pcall(NavPredict.CanSkip, playerPos, goalPos, fromAreaNode, true, allowJump)
	return success and canSkip == true
end

local function trySkipCurrentNode(playerPos, currentNode, nextNode, reason)
	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	local goalPos = nextNode.pos
	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"

	-- Always validate from the path node we are leaving, not overlap-picked area
	if not canSkipSegment(playerPos, goalPos, currentNode, allowJump) then
		logSkipBlocked(currentNode, nextNode, reason)
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

local function shouldAttemptSkip(playerPos, currentNode, nextNode)
	local passed, passReason = PathSteering.hasPassedNode(playerPos, currentNode, nextNode)
	if passed then
		return true, passReason
	end

	local playerArea = Node.GetAreaAtPosition(playerPos)
	if playerArea and playerArea.id == nextNode.id then
		return true, "inside_next_area"
	end

	return false, nil
end

function NodeSkipper.Reset()
	G.Navigation.nodePassTrack = nil
	lastBlockedLogKey = nil
	lastBlockedLogTick = 0
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

	local shouldSkip, skipReason = shouldAttemptSkip(playerPos, currentNode, nextNode)
	if not shouldSkip then
		return false
	end

	if trySkipCurrentNode(playerPos, currentNode, nextNode, skipReason) then
		lockIntentAfterSkip(playerPos)
		G.Navigation.currentNodeIndex = 1
		return true
	end

	return false
end

return NodeSkipper
