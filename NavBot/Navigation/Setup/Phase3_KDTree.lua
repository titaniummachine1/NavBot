--##########################################################################
--  Phase3_KDTree.lua  ·  Spatial index: XY KD-tree + area grid
--##########################################################################

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local AreaSpatial = require("NavBot.Navigation.AreaSpatial")

local Phase3_KDTree = {}

local Log = Common.Log.new("Phase3_KDTree")

--##########################################################################
--  LOCAL HELPERS
--##########################################################################

local function getSplitCoord(point, axis)
	local node = point.node
	if node and node._minX then
		return (node._minX + node._maxX) * 0.5
	end
	return point.pos.x
end

local function getSplitCoordY(point)
	local node = point.node
	if node and node._minY then
		return (node._minY + node._maxY) * 0.5
	end
	return point.pos.y
end

local function buildKDTree(nodes)
	local points = {}
	for id, node in pairs(nodes) do
		if not node.isDoor and node.pos then
			table.insert(points, {
				pos = node.pos,
				id = id,
				node = node,
			})
		end
	end

	if #points == 0 then
		Log:Warn("No valid nodes for KD-tree")
		return nil
	end

	local function build(pointList, depth)
		if #pointList == 0 then
			return nil
		end

		-- XY only — nav areas are ground partitions; Z handled by containment
		local axis = depth % 2

		table.sort(pointList, function(a, b)
			if axis == 0 then
				return getSplitCoord(a, axis) < getSplitCoord(b, axis)
			end
			return getSplitCoordY(a) < getSplitCoordY(b)
		end)

		local medianIdx = math.floor(#pointList / 2) + 1
		local median = pointList[medianIdx]
		local splitValue = axis == 0 and getSplitCoord(median, axis) or getSplitCoordY(median)

		local leftPoints = {}
		local rightPoints = {}
		for i = 1, #pointList do
			if i < medianIdx then
				table.insert(leftPoints, pointList[i])
			elseif i > medianIdx then
				table.insert(rightPoints, pointList[i])
			end
		end

		return {
			point = median,
			axis = axis,
			split = splitValue,
			left = build(leftPoints, depth + 1),
			right = build(rightPoints, depth + 1),
		}
	end

	return build(points, 0)
end

local function distSqForPoint(pos, point)
	return AreaSpatial.DistSqPointToAABB(pos, point.node)
end

--##########################################################################
--  PUBLIC API
--##########################################################################

function Phase3_KDTree.DistSqPointToAABB(pos, node)
	return AreaSpatial.DistSqPointToAABB(pos, node)
end

--- Build KD-tree and XY area grid for spatial queries
--- @param nodes table
--- @return table|nil tree
function Phase3_KDTree.Execute(nodes)
	assert(type(nodes) == "table", "Phase3_KDTree.Execute: nodes must be table")

	Log:Info("Building spatial indexes (KD-tree + area grid)")

	local tree = buildKDTree(nodes)
	local grid = AreaSpatial.BuildGrid(nodes)

	if grid then
		G.Navigation.areaGrid = grid
		Log:Info("Area grid: %d cells", grid._cellCount or 0)
	end

	if tree then
		Log:Info("Phase 3 complete: KD-tree built")
	else
		Log:Warn("Phase 3: KD-tree build failed")
	end

	return tree
end

--- Find nearest area by point-to-AABB distance (not center distance).
function Phase3_KDTree.FindNearest(tree, pos)
	if not tree or not pos then
		return nil
	end

	local bestDistSq = math.huge
	local best = nil

	local function search(node)
		if not node then
			return
		end

		local distSq = distSqForPoint(pos, node.point)
		if distSq < bestDistSq then
			bestDistSq = distSq
			best = node.point
		end

		local diff = pos.x - node.split
		if node.axis == 1 then
			diff = pos.y - node.split
		end

		local first, second
		if diff < 0 then
			first, second = node.left, node.right
		else
			first, second = node.right, node.left
		end

		search(first)

		if diff * diff < bestDistSq then
			search(second)
		end
	end

	search(tree)
	return best
end

--- Find K nearest areas ranked by point-to-AABB distance.
function Phase3_KDTree.FindKNearest(tree, pos, k)
	if not tree or not pos or k <= 0 then
		return {}
	end

	local candidates = {}
	local count = 0

	local function addCandidate(point, distSq)
		if count < k then
			count = count + 1
			candidates[count] = { point = point, distSq = distSq }
			local i = count
			while i > 1 do
				local parent = math.floor(i / 2)
				if candidates[parent].distSq >= candidates[i].distSq then
					break
				end
				candidates[parent], candidates[i] = candidates[i], candidates[parent]
				i = parent
			end
		elseif distSq < candidates[1].distSq then
			candidates[1] = { point = point, distSq = distSq }
			local i = 1
			while true do
				local left = i * 2
				local right = left + 1
				local largest = i

				if left <= count and candidates[left].distSq > candidates[largest].distSq then
					largest = left
				end
				if right <= count and candidates[right].distSq > candidates[largest].distSq then
					largest = right
				end
				if largest == i then
					break
				end
				candidates[i], candidates[largest] = candidates[largest], candidates[i]
				i = largest
			end
		end
	end

	local function search(node)
		if not node then
			return
		end

		addCandidate(node.point, distSqForPoint(pos, node.point))

		local diff = pos.x - node.split
		if node.axis == 1 then
			diff = pos.y - node.split
		end

		local first, second
		if diff < 0 then
			first, second = node.left, node.right
		else
			first, second = node.right, node.left
		end

		search(first)

		local worstDistSq = count > 0 and candidates[1].distSq or math.huge
		if diff * diff < worstDistSq then
			search(second)
		end
	end

	search(tree)

	table.sort(candidates, function(a, b)
		return a.distSq < b.distSq
	end)

	local result = {}
	for i = 1, count do
		result[i] = candidates[i].point
	end
	return result
end

return Phase3_KDTree
