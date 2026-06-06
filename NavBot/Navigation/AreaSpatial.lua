--##########################################################################
--  AreaSpatial.lua  ·  AABB distance, containment, and grid indexing
--##########################################################################
--
--  TF2 nav areas are axis-aligned in XY. Bots stay upright; ramps tilt the floor.
--  Containment = horizontal AABB + vertical band above local floor (82 up, 8 down).

local G = require("NavBot.Core.Globals")
local NavGeometry = require("NavBot.Navigation.Prediction.NavGeometry")

local AreaSpatial = {}

local GRID_CELL_SIZE = 256

AreaSpatial.Z_PAD_BELOW = 8
AreaSpatial.Z_PAD_ABOVE = 82

local Z_PAD_BELOW = AreaSpatial.Z_PAD_BELOW

local function getZPadAbove()
	return (G.Misc and G.Misc.NodeTouchHeight) or AreaSpatial.Z_PAD_ABOVE
end

local function getLocalFloorZ(pos, node)
	if node.nw and node.ne and node.sw and node.se then
		local z = NavGeometry.GetGroundZFromQuad(pos, node)
		if z then
			return z
		end
	end
	return node._floorZ
end

--- Precompute floor Z and vertical query band on a normalized node.
function AreaSpatial.PrecomputeVerticalBounds(node)
	if not node.nw then
		return
	end

	local minZ = math.min(node.nw.z, node.ne.z, node.sw.z, node.se.z)
	local maxZ = math.max(node.nw.z, node.ne.z, node.sw.z, node.se.z)
	node._floorZ = minZ
	node._minZ = minZ - Z_PAD_BELOW
	node._maxZ = maxZ + getZPadAbove()
end

--- Horizontal AABB + vertical band (NodeTouchHeight above local floor, 8 below).
function AreaSpatial.IsWithinArea(pos, node)
	if not node or not node._minX then
		return false
	end

	if pos.x < node._minX or pos.x > node._maxX then
		return false
	end
	if pos.y < node._minY or pos.y > node._maxY then
		return false
	end

	local floorZ = getLocalFloorZ(pos, node)
	if not floorZ then
		return true
	end

	local zPadAbove = getZPadAbove()
	local heightAboveFloor = pos.z - floorZ
	return heightAboveFloor <= zPadAbove and heightAboveFloor >= -Z_PAD_BELOW
end

--- Squared distance from a point to the XY footprint + Z query band (0 if inside).
function AreaSpatial.DistSqPointToAABB(pos, node)
	if not node or not node._minX then
		return math.huge
	end

	local dx, dy, dz = 0, 0, 0
	if pos.x < node._minX then
		dx = node._minX - pos.x
	elseif pos.x > node._maxX then
		dx = pos.x - node._maxX
	end
	if pos.y < node._minY then
		dy = node._minY - pos.y
	elseif pos.y > node._maxY then
		dy = pos.y - node._maxY
	end
	if node._minZ and node._maxZ then
		if pos.z < node._minZ then
			dz = node._minZ - pos.z
		elseif pos.z > node._maxZ then
			dz = pos.z - node._maxZ
		end
	end

	return dx * dx + dy * dy + dz * dz
end

local function cellCoord(value)
	return math.floor(value / GRID_CELL_SIZE)
end

local function cellKey(gx, gy)
	return gx .. "," .. gy
end

function AreaSpatial.BuildGrid(nodes)
	local grid = {}
	local cellCount = 0

	for _, node in pairs(nodes) do
		if not node.isDoor and node._minX and node._maxX then
			local gx0 = cellCoord(node._minX)
			local gx1 = cellCoord(node._maxX)
			local gy0 = cellCoord(node._minY)
			local gy1 = cellCoord(node._maxY)

			for gx = gx0, gx1 do
				for gy = gy0, gy1 do
					local key = cellKey(gx, gy)
					local bucket = grid[key]
					if not bucket then
						bucket = {}
						grid[key] = bucket
						cellCount = cellCount + 1
					end
					bucket[#bucket + 1] = node
				end
			end
		end
	end

	grid._cellSize = GRID_CELL_SIZE
	grid._cellCount = cellCount
	return grid
end

local function appendBucket(bucket, seen, candidates, count)
	if not bucket then
		return count
	end
	for i = 1, #bucket do
		local node = bucket[i]
		local id = node.id
		if id and not seen[id] then
			seen[id] = true
			count = count + 1
			candidates[count] = node
		end
	end
	return count
end

--- All areas whose XY AABB overlaps pos's grid cell.
--- Complete for containment: if pos is inside an area's XY box, that area is indexed here.
function AreaSpatial.QueryGridCell(grid, pos)
	if not grid or not pos then
		return {}
	end

	local bucket = grid[cellKey(cellCoord(pos.x), cellCoord(pos.y))]
	if not bucket then
		return {}
	end

	local candidates = {}
	for i = 1, #bucket do
		candidates[i] = bucket[i]
	end
	return candidates
end

--- 3×3 cells — for nearest-area queries when pos is outside all areas.
function AreaSpatial.QueryGridNeighbors(grid, pos)
	if not grid or not pos then
		return {}
	end

	local gx = cellCoord(pos.x)
	local gy = cellCoord(pos.y)
	local seen = {}
	local candidates = {}
	local count = 0

	for dx = -1, 1 do
		for dy = -1, 1 do
			count = appendBucket(grid[cellKey(gx + dx, gy + dy)], seen, candidates, count)
		end
	end

	return candidates
end

function AreaSpatial.FindNearestInList(pos, candidates)
	local bestNode, bestDistSq = nil, math.huge

	for i = 1, #candidates do
		local node = candidates[i]
		if not node.isDoor then
			local distSq = AreaSpatial.DistSqPointToAABB(pos, node)
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestNode = node
			end
		end
	end

	return bestNode
end

function AreaSpatial.GetGridCellSize()
	return GRID_CELL_SIZE
end

return AreaSpatial
