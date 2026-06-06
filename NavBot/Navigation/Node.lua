--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local SetupOrchestrator = require("NavBot.Navigation.Setup.SetupOrchestrator")
local Phase3_KDTree = require("NavBot.Navigation.Setup.Phase3_KDTree")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")
local ConnectionUtils = require("NavBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("NavBot.Navigation.ConnectionBuilder")

local Log = Common.Log.new("Node")
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

-- Setup and loading - uses explicit phase orchestration
function Node.Setup()
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end

	-- Explicit flow: Phase1 → Phase2 → SET GLOBAL → Phase3 → Phase4
	SetupOrchestrator.ExecuteFullSetup()
end

function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

function Node.LoadNavFile()
	return SetupOrchestrator.ExecuteFullSetup()
end

function Node.LoadFile(navFile)
	return SetupOrchestrator.ExecuteFullSetup(navFile)
end

-- Node management
function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

-- When multiple areas overlap (stairs), pick closest floor height
local function pickBestContainingArea(pos, candidates)
	local bestNode, bestZErr = nil, math.huge

	for i = 1, #candidates do
		local node = candidates[i]
		if not node.isDoor and AreaSpatial.IsWithinArea(pos, node) then
			local floorZ = node._floorZ or node.pos.z
			local zErr = math.abs(pos.z - floorZ)
			if zErr < bestZErr then
				bestZErr = zErr
				bestNode = node
			end
		end
	end

	return bestNode
end

--- Exact area at pos, or nil if not inside any area (never guesses nearest).
function Node.GetAreaAtPosition(pos)
	if not G.Navigation.nodes or not pos then
		return nil
	end

	local grid = G.Navigation.areaGrid
	if not grid then
		return nil
	end

	return pickBestContainingArea(pos, AreaSpatial.QueryGridCell(grid, pos))
end

--- Nearest area by AABB distance (for path start/goal when off-mesh). Not for "where am I".
function Node.GetClosestNode(pos)
	if not G.Navigation.nodes or not pos then
		return nil
	end

	local grid = G.Navigation.areaGrid
	if grid then
		local cellCandidates = AreaSpatial.QueryGridCell(grid, pos)
		local contained = pickBestContainingArea(pos, cellCandidates)
		if contained then
			return contained
		end

		local fromCell = AreaSpatial.FindNearestInList(pos, cellCandidates)
		if fromCell then
			return fromCell
		end

		local neighborCandidates = AreaSpatial.QueryGridNeighbors(grid, pos)
		contained = pickBestContainingArea(pos, neighborCandidates)
		if contained then
			return contained
		end

		local fromNeighbors = AreaSpatial.FindNearestInList(pos, neighborCandidates)
		if fromNeighbors then
			return fromNeighbors
		end
	end

	if G.Navigation.kdTree then
		local nearest = Phase3_KDTree.FindNearest(G.Navigation.kdTree, pos)
		if nearest then
			return nearest.node
		end
	end

	return nil
end

-- Connection utilities
function Node.GetConnectionNodeId(connection)
	return ConnectionUtils.GetNodeId(connection)
end

---@param node Node The node to check
---@return boolean True if the node is a door node
function Node.IsDoorNode(node)
	return node and node.isDoor == true
end

function Node.GetConnectionCost(connection)
	return ConnectionUtils.GetCost(connection)
end

function Node.GetConnectionEntry(nodeA, nodeB)
	return ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
end

function Node.GetDoorTargetPoint(areaA, areaB)
	return ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
end

-- Connection management
function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			table.insert(dir.connections, { node = nodeB.id, cost = 1 })
			dir.count = #dir.connections
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for i = #dir.connections, 1, -1 do
				local targetId = ConnectionUtils.GetNodeId(dir.connections[i])
				if targetId == nodeB.id then
					table.remove(dir.connections, i)
				end
			end
			dir.count = #dir.connections
		end
	end
end

local function resolveConnectionToArea(connection, fromNodeId, nodes)
	local targetId = ConnectionUtils.GetNodeId(connection)
	local target = nodes[targetId]
	if not target then
		return nil
	end

	if target.isDoor then
		if target.areaId == fromNodeId then
			return nodes[target.targetAreaId]
		end
		if target.targetAreaId == fromNodeId then
			return nodes[target.areaId]
		end
		return nil
	end

	if not target.isDoor and target.id ~= fromNodeId then
		return target
	end

	return nil
end

-- A* / greedy graph: area nodes only — door stubs resolve to neighbor areas
function Node.GetAdjacentAreasForPath(node, nodes)
	local neighbors = {}
	local seenAreaIds = {}

	if not node or node.isDoor or not node.c or not nodes then
		return neighbors
	end

	for _, dir in pairs(node.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local areaNode = resolveConnectionToArea(connection, node.id, nodes)
				if areaNode and areaNode.pos and not seenAreaIds[areaNode.id] then
					seenAreaIds[areaNode.id] = true
					neighbors[#neighbors + 1] = {
						node = areaNode,
						cost = (node.pos - areaNode.pos):Length(),
					}
				end
			end
		end
	end

	return neighbors
end

-- Raw graph adjacency (includes door nodes) — debug / visuals only
function Node.GetAdjacentNodesSimple(node, nodes)
	local neighbors = {}

	if not node.c then
		return neighbors
	end

	for _, dir in pairs(node.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				local targetNode = nodes[targetId]

				if targetNode then
					local cost = (node.pos - targetNode.pos):Length()
					neighbors[#neighbors + 1] = {
						node = targetNode,
						cost = cost,
					}
				end
			end
		end
	end

	return neighbors
end

function Node.GetAdjacentNodesOnly(node, nodes)
	if not node or not node.c or not nodes then
		return {}
	end

	local adjacent = {}
	local count = 0

	for _, dir in pairs(node.c) do
		local connections = dir.connections
		if connections then
			for i = 1, #connections do
				local targetId = ConnectionUtils.GetNodeId(connections[i])
				local targetNode = nodes[targetId]
				if targetNode then
					count = count + 1
					adjacent[count] = targetNode
				end
			end
		end
	end

	return adjacent
end

function Node.NormalizeConnections()
	ConnectionBuilder.NormalizeConnections()
end

function Node.BuildDoorsForConnections()
	ConnectionBuilder.BuildDoorsForConnections()
end

return Node
