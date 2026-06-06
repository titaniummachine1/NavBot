--[[
PERFORMANCE OPTIMIZATION STRATEGY:
- Heavy validation (accessibility checks) happens at setup time via pruneInvalidConnections()
- A* uses Node.GetAdjacentAreasForPath() — area-to-area only (doors resolve to neighbor areas)
- Precise walkability uses NavPredict.CanSkip (straight line + door portals + hull traces)
- Invalid connections are pruned at setup; line checks run at movement time
]]

local Navigation = {}

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")
local AStar = require("NavBot.Algorithms.A-Star")
local NodeSkipper = require("NavBot.Bot.NodeSkipper")
local GroundMovement = require("NavBot.Bot.GroundMovement")
local PathStringPull = require("NavBot.Navigation.PathStringPull")
local CircuitBreaker = require("NavBot.Bot.CircuitBreaker")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("NavBot")
Log.Level = 0

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("AddConnection: One or both nodes are nil")
		return
	end
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("RemoveConnection: One or both nodes are nil")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		Log:Warn("AddCostToConnection: One or both nodes are nil")
		return
	end

	-- Use Node module's implementation to avoid duplication
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

-- ========================================================================
-- SETUP & INITIALIZATION
-- ========================================================================

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		Navigation.ClearPath()
	end
end

-- ========================================================================
-- NODE QUERIES
-- ========================================================================

-- Get a node by ID
---@param nodeId integer
---@return table|nil
function Navigation.GetNode(nodeId)
	if not nodeId then
		Log:Warn("GetNode: nodeId is nil")
		return nil
	end

	return Node.GetNodeByID(nodeId)
end

-- Get adjacent nodes for a given node ID (areas only, no doors)
---@param nodeId integer
---@return integer[]
function Navigation.GetAdjacentNodes(nodeId)
	if not nodeId then
		Log:Warn("GetAdjacentNodes: nodeId is nil")
		return {}
	end

	local node = Node.GetNodeByID(nodeId)
	if not node then
		Log:Warn("GetAdjacentNodes: node %d not found", nodeId)
		return {}
	end

	local neighbors = Node.GetAdjacentAreasForPath(node, G.Navigation.nodes)

	-- Extract node IDs
	local adjacentIds = {}
	for _, neighbor in ipairs(neighbors) do
		if neighbor.node and neighbor.node.id then
			table.insert(adjacentIds, neighbor.node.id)
		end
	end

	return adjacentIds
end

-- ========================================================================
-- PATH QUERIES
-- ========================================================================

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- ========================================================================
-- PATH MANAGEMENT
-- ========================================================================

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
	G.Navigation.apexPath = nil
	G.Navigation.apexIndex = 1
	G.Navigation.slowSpeedTicks = 0
	PathStringPull.ResetApexAdvanceTick()
	NodeSkipper.Reset()
end

function Navigation.RebuildApexPath(blockSkipAfterSet)
	local path = G.Navigation.path
	if not path or #path == 0 then
		G.Navigation.apexPath = nil
		G.Navigation.apexIndex = 1
		return
	end
	local startPos = G.pLocal and G.pLocal.Origin or nil
	G.Navigation.apexPath = PathStringPull.ProcessAreaPath(path, G.Navigation.goalPos, startPos)
	G.Navigation.apexIndex = 1
	PathStringPull.ResetApexAdvanceTick()
	if blockSkipAfterSet then
		NodeSkipper.BlockSkippingAfterPathSet()
	end
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	-- Use weak values to avoid strong retention of node objects (nodes table holds strong refs)
	pcall(setmetatable, G.Navigation.path, { __mode = "v" })
	G.Navigation.currentNodeIndex = 1
	Navigation.RebuildApexPath(true)
	NodeSkipper.Reset()
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		local reached = table.remove(G.Navigation.path, 1)
		if reached and reached.id then
			PathStringPull.ConsumeNodeApexes(reached.id)
		end
		G.Navigation.currentNodeIndex = 1
	end
end
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

function Navigation.ResetNodeSkipping()
	NodeSkipper.Reset()
end

-- ========================================================================
-- NODE QUERIES (path)
-- ========================================================================

---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	local n = Node.GetClosestNode(pos)
	if not n then
		return nil
	end
	return n
end

-- Get area at position using multi-point distance check (more precise than GetClosestNode)
---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetAreaAtPosition(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetAreaAtPosition")
		return nil
	end
	local n = Node.GetAreaAtPosition(pos)
	if not n then
		return nil
	end
	return n
end

--- Repath start: exact area under feet first (avoids KD-tree backtrack on stacked nav).
function Navigation.GetPathStartNode(pos)
	local area = Navigation.GetAreaAtPosition(pos)
	if area then
		return area
	end
	return Navigation.GetClosestNode(pos)
end

--- After A* only: drop prefix until player area is path[1] (fixes wrong start node).
function Navigation.AlignPathPrefixToPlayer(playerPos)
	local path = G.Navigation.path
	if not path or #path < 1 or not playerPos then
		return false
	end

	local playerArea = Node.GetAreaAtPosition(playerPos)
	if not playerArea then
		return false
	end

	local targetIndex = nil
	for i = 1, #path do
		if path[i].id == playerArea.id then
			targetIndex = i
			break
		end
	end

	if not targetIndex or targetIndex <= 1 then
		return false
	end

	local popped = 0
	while targetIndex > 1 and #path > 1 do
		local removed = table.remove(path, 1)
		if removed and removed.id then
			PathStringPull.ConsumeNodeApexes(removed.id)
		end
		targetIndex = targetIndex - 1
		popped = popped + 1
	end

	G.Navigation.currentNodeIndex = 1
	if popped > 0 then
		Log:Info("Aligned path prefix to area %s (pathLen=%d, popped=%d)", tostring(playerArea.id), #path, popped)
	end
	return popped > 0
end

--- Feet are on path[i] with i>1 but path[1] is stale — trim prefix (desync recovery only).
function Navigation.AlignPathIfDesynced(playerPos)
	local path = G.Navigation.path
	if not path or #path < 2 or not playerPos then
		return false
	end

	local pLocal = G.pLocal and G.pLocal.entity
	if pLocal and not GroundMovement.isOnGround(pLocal) then
		return false
	end

	local playerArea = Node.GetAreaAtPosition(playerPos)
	if not playerArea then
		return false
	end

	if path[1] and path[1].id == playerArea.id then
		return false
	end

	for i = 2, #path do
		if path[i].id == playerArea.id then
			return Navigation.AlignPathPrefixToPlayer(playerPos)
		end
	end

	return false
end

---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	if not startNode or not startNode.pos then
		Log:Error("Navigation.FindPath: invalid start node")
		return Navigation
	end
	if not goalNode or not goalNode.pos then
		Log:Error("Navigation.FindPath: invalid goal node")
		return Navigation
	end

	local success, path = pcall(AStar.NormalPath, startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentAreasForPath)

	if not success then
		Log:Error("A* pathfinding crashed: %s", tostring(path))
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false
		CircuitBreaker.addFailure(startNode, goalNode)
		return Navigation
	end

	G.Navigation.path = path

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false
		CircuitBreaker.addFailure(startNode, goalNode)
	else
		Log:Info("Path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
		pcall(setmetatable, G.Navigation.path, { __mode = "v" })
		local origin = G.pLocal and G.pLocal.Origin
		if origin then
			Navigation.AlignPathPrefixToPlayer(origin)
		end
		Navigation.RebuildApexPath(true)
	end

	return Navigation
end

return Navigation
