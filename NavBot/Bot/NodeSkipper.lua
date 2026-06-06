--[[
Node Skipper — runs every tick; skip current node when NavPredict.CanSkip passes (no doors-only).
Door portals are reserved for PathStringPull at path-build time.
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local NavPredict = require("NavBot.Navigation.Prediction.NavPredict")
local PathSteering = require("NavBot.Navigation.PathSteering")
local PathStringPull = require("NavBot.Navigation.PathStringPull")

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

local function rebuildApexPath(playerPos)
	G.Navigation.apexPath = PathStringPull.ProcessAreaPath(G.Navigation.path, G.Navigation.goalPos, playerPos)
	G.Navigation.apexIndex = 1
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
	-- doorsOnly=false for skipping; doors-only mode is for string-pull apex build
	local success, canSkip = pcall(NavPredict.CanSkip, playerPos, goalPos, fromAreaNode, false, allowJump)
	return success and canSkip == true
end

local function trySkipCurrentNode(playerPos, currentNode, nextNode)
	local goalPos = nextNode.pos
	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"

	if not canSkipSegment(playerPos, goalPos, currentNode, allowJump) then
		logSkipBlocked(currentNode, nextNode, "not_walkable")
		return false
	end

	local missedNode = table.remove(G.Navigation.path, 1)
	G.Navigation.pathHistory = G.Navigation.pathHistory or {}
	table.insert(G.Navigation.pathHistory, 1, missedNode)
	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()
	G.Navigation.currentNodeIndex = 1
	rebuildApexPath(playerPos)
	Log:Info("Skipped node %s, targeting %s", tostring(missedNode.id), tostring(nextNode.id))
	return true
end

function NodeSkipper.Reset()
	G.Navigation.nodePassTrack = nil
	lastBlockedLogKey = nil
	lastBlockedLogTick = 0
end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
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

	if trySkipCurrentNode(playerPos, currentNode, nextNode) then
		lockIntentAfterSkip(playerPos)
		return true
	end

	return false
end

return NodeSkipper
