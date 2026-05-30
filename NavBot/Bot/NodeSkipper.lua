--[[
Node Skipper - Per-tick node skipping with menu-controlled limits
Uses:
- G.Menu.Main.MaxSkipRange: max distance to skip (default 500)
- G.Menu.Main.MaxNodesToSkip: max nodes per tick (default 3)
- G.Misc.NodePassProximity / NodePassAngleDegrees: passed-node detection
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local isNavigable = require("NavBot.Navigation.isWalkable.isNavigable")
local Node = require("NavBot.Navigation.Node")
local WorkManager = require("NavBot.WorkManager")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

local function isDoorNode(node)
	return node and not node._minX
end

local function resetPassTracker(nodeId)
	if not nodeId then
		G.Navigation.nodePassTrack = nil
		return
	end
	G.Navigation.nodePassTrack = {
		nodeId = nodeId,
		lastDirToNode = nil, -- previous tick: horizontal bearing from player to this node
	}
end

--- Bearing-to-node overshoot: each tick compare dir-to-node vs last tick.
--- If it swings >= 60° before normal reach distance, you walked past it.
local function checkPassedCurrentNode(playerPos, node, nextNode)
	if not (node and node.pos and nextNode and nextNode.pos) then
		return false, nil
	end

	local track = G.Navigation.nodePassTrack
	if not track or track.nodeId ~= node.id then
		resetPassTracker(node.id)
		track = G.Navigation.nodePassTrack
	end

	local proximity = G.Misc.NodePassProximity or 16
	local passAngle = G.Misc.NodePassAngleDegrees or 60
	local reachDist = G.Misc.NodeTouchDistance or 12

	local dist2D = Common.Distance2D(playerPos, node.pos)
	if dist2D <= proximity then
		return true, "proximity"
	end

	local dirToNode = Vector3(node.pos.x - playerPos.x, node.pos.y - playerPos.y, 0)
	local dirLen = dirToNode:Length2D()
	if dirLen < 1 then
		return true, "at_node"
	end
	dirToNode = dirToNode / dirLen

	-- Overshoot: direction toward node changed sharply before we reached it
	if track.lastDirToNode and dist2D > reachDist then
		local bearingDelta = Common.Angle2DDegrees(track.lastDirToNode, dirToNode)
		if bearingDelta >= passAngle then
			track.lastDirToNode = dirToNode
			return true, "overshoot"
		end
	end

	track.lastDirToNode = dirToNode
	return false, nil
end

local function trySkipCurrentNode(playerPos, currentNode, nextNode, reason)
	if isDoorNode(currentNode) or isDoorNode(nextNode) then
		Log:Debug("SKIP blocked (door): %s", reason)
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, nextNode.pos, currentArea, true, allowJump)
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
	resetPassTracker(nextNode.id)

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

	-- Passed current node (proximity / overshoot) — always on, not menu-gated
	local passed, passReason = checkPassedCurrentNode(playerPos, currentNode, nextNode)
	if passed and trySkipCurrentNode(playerPos, currentNode, nextNode, passReason) then
		G.Navigation.currentNodeIndex = 1
		return true
	end

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	-- Closer to next node than current node is (legacy smart skip)
	local distPlayerToNext = Common.Distance3D(playerPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

	if distPlayerToNext < distCurrentToNext then
		if trySkipCurrentNode(playerPos, currentNode, nextNode, "closer_to_next") then
			G.Navigation.currentNodeIndex = 1
			return true
		end
	end

	-- Forward skip: walk directly to path[3]
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

	local distToTarget = Common.Distance3D(playerPos, skipTarget.pos)
	if distToTarget > maxSkipRange then
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, skipTarget.pos, currentArea, true, allowJump)
	if not (success and canSkip) then
		return false
	end

	G.Navigation.pathHistory = G.Navigation.pathHistory or {}

	local skipped1 = table.remove(path, 1)
	if skipped1 then
		table.insert(G.Navigation.pathHistory, 1, skipped1)
		resetPassTracker(path[1] and path[1].id or nil)
	end
	local skipped2 = table.remove(path, 1)
	if skipped2 then
		table.insert(G.Navigation.pathHistory, 1, skipped2)
	end

	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()

	Log:Info("FORWARD SKIP: bypassed 2 nodes (direct path to %s, range %.0f)", tostring(skipTarget.id), maxSkipRange)
	G.Navigation.currentNodeIndex = 1
	return true
end

return NodeSkipper
