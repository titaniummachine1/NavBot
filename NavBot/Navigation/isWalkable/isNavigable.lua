--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]

local Navigable = {}
local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")
local Common = require("NavBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local JUMP_HEIGHT = 72
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local JUMP_HEIGHT_Vector = Vector3(0, 0, JUMP_HEIGHT)
local FORWARD_STEP = 100 -- Max distance per forward trace
local HILL_THRESHOLD = 4 -- 0.5x step height for significant elevation changes

local MaxSpeed = 450
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 55
local MAX_ITERATIONS = 37
local TOLERANCE = 16.0
local OPPOSITE_EXIT_DIR = { [1] = 3, [3] = 1, [2] = 4, [4] = 2 }
local DOOR_PORTAL_HALF_WIDTH = 24

-- Debug
local DEBUG_MODE = false
local hullTraces = {}
local debugWaypoints = nil
local debugLastResult = nil
local debugFailLine = nil

local engineTraceHull = engine.TraceHull

local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local result = engineTraceHull(startPos, endPos, minHull, maxHull, mask, filter)
	local blocked = result.fraction < 0.999
	table.insert(hullTraces, {
		startPos = startPos,
		endPos = result.endpos,
		blocked = blocked,
	})
	return result
end

local function getTraceHull()
	if DEBUG_MODE then
		return traceHullWrapper
	end
	return engineTraceHull
end

local function snapshotWaypoints(waypoints)
	local snapshot = {}
	for i = 1, #waypoints do
		local wp = waypoints[i]
		snapshot[i] = {
			pos = wp.pos,
			nodeId = wp.node and wp.node.id or nil,
		}
	end
	return snapshot
end

local function saveDebugPath(waypoints)
	if not DEBUG_MODE then
		return
	end
	debugWaypoints = snapshotWaypoints(waypoints)
end

local function setDebugResult(isNavigable)
	if DEBUG_MODE then
		debugLastResult = isNavigable == true
	end
end

local function saveDebugFail(fromPos, toPos)
	if not DEBUG_MODE or not fromPos or not toPos then
		return
	end
	debugFailLine = { from = fromPos, to = toPos }
end

local function setPathDrawColor(isNavigable)
	if isNavigable then
		draw.Color(0, 255, 0, 255)
	else
		draw.Color(255, 0, 0, 255)
	end
end

local function drawWorldLine(a, b)
	local w2sA = client.WorldToScreen(a)
	local w2sB = client.WorldToScreen(b)
	if w2sA and w2sB then
		draw.Line(w2sA[1], w2sA[2], w2sB[1], w2sB[2])
	end
end

-- Helper: Get surface angle from normal-- curently unused
local function getSurfaceAngle(surfaceNormal)
	if not surfaceNormal then
		return 0
	end
	return math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))
end

-- Keep XY bearing fixed; only add pitch (Z) from the surface normal
local function applyPitchToSurface(horizDir, surfaceNormal)
	local flat = Vector3(horizDir.x, horizDir.y, 0)
	if flat:Length() < 0.001 then
		return horizDir
	end
	flat = Common.Normalize(flat)

	if not surfaceNormal then
		return flat
	end

	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))
	if angle > MAX_SURFACE_ANGLE then
		return flat
	end

	local nx, ny, nz = surfaceNormal.x, surfaceNormal.y, surfaceNormal.z
	if math.abs(nz) < 0.001 then
		return flat
	end

	local dz = -(nx * flat.x + ny * flat.y) / nz
	return Common.Normalize(Vector3(flat.x, flat.y, dz))
end

local function projectXYOntoGoalLine(x, y, lineOrigin, lineDir)
	local px = x - lineOrigin.x
	local py = y - lineOrigin.y
	local along = px * lineDir.x + py * lineDir.y
	return lineOrigin.x + lineDir.x * along, lineOrigin.y + lineDir.y * along
end

-- Find where ray exits node bounds
-- Returns: exitPoint, exitDist, exitDir (1=N, 2=E, 3=S, 4=W)
local function findNodeExit(startPos, dir, node)
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir = nil

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = 2 -- East
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = 4 -- West
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = 3 -- South
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = 1 -- North
		end
	end

	if tMin == math.huge then
		return nil, nil, nil
	end
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- Calculate ground Z position from node quad geometry (no engine call)
local function getGroundZFromQuad(pos, node)
	if not (node.nw and node.ne and node.sw and node.se) then
		return nil, nil
	end

	local nw, ne, sw, se = node.nw, node.ne, node.sw, node.se

	-- Determine which triangle contains the point
	-- Split quad into: Triangle1(nw,ne,se) and Triangle2(nw,se,sw)
	local dx = pos.x - nw.x
	local dy = pos.y - nw.y
	local dx_ne = ne.x - nw.x
	local dy_se = se.y - nw.y

	local inTriangle1 = (dx / dx_ne + dy / dy_se) <= 1.0

	local v0, v1, v2
	if inTriangle1 then
		-- Triangle: nw, ne, se
		v0, v1, v2 = nw, ne, se
	else
		-- Triangle: nw, se, sw
		v0, v1, v2 = nw, se, sw
	end

	-- Barycentric interpolation for Z
	local denom = (v1.y - v2.y) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.y - v2.y)
	if math.abs(denom) < 0.0001 then
		return v0.z, UP_VECTOR -- Degenerate triangle, use first vertex
	end

	local w0 = ((v1.y - v2.y) * (pos.x - v2.x) + (v2.x - v1.x) * (pos.y - v2.y)) / denom
	local w1 = ((v2.y - v0.y) * (pos.x - v2.x) + (v0.x - v2.x) * (pos.y - v2.y)) / denom
	local w2 = 1.0 - w0 - w1

	local z = w0 * v0.z + w1 * v1.z + w2 * v2.z

	-- Calculate normal from cross product
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local normal = edge1:Cross(edge2)
	normal = Common.Normalize(normal)
	if not normal then
		normal = UP_VECTOR
	end

	return z, normal
end

-- Helper: Check if horizontal point is within node bounds (with tolerance)
local function isPointInNodeBounds(point, node, tolerance)
	tolerance = tolerance or 0
	local inX = point.x >= (node._minX - tolerance) and point.x <= (node._maxX + tolerance)
	local inY = point.y >= (node._minY - tolerance) and point.y <= (node._maxY + tolerance)
	return inX and inY
end

local function isAreaNode(node)
	return node and node._minX and node._maxX and node._minY and node._maxY
end

-- Min/max on the axis that varies along the facing wall (shared axis between areas)
local function getFacingEdgeSpan(area, exitDir)
	local nw, ne, sw, se = area.nw, area.ne, area.sw, area.se
	if nw and ne and sw and se then
		if exitDir == 2 then
			return math.min(ne.y, se.y), math.max(ne.y, se.y)
		elseif exitDir == 4 then
			return math.min(nw.y, sw.y), math.max(nw.y, sw.y)
		elseif exitDir == 3 then
			return math.min(sw.x, se.x), math.max(sw.x, se.x)
		elseif exitDir == 1 then
			return math.min(nw.x, ne.x), math.max(nw.x, ne.x)
		end
	end

	if exitDir == 2 or exitDir == 4 then
		return area._minY, area._maxY
	end
	return area._minX, area._maxX
end

-- Overlap of both facing edges on the shared axis — the real walkable portal
local function getSharedPortalSpan(currentNode, neighborNode, exitDir)
	local aMin, aMax = getFacingEdgeSpan(currentNode, exitDir)
	local oppDir = OPPOSITE_EXIT_DIR[exitDir]
	local bMin, bMax = getFacingEdgeSpan(neighborNode, oppDir)
	local portalMin = math.max(aMin, bMin)
	local portalMax = math.min(aMax, bMax)
	if portalMax <= portalMin then
		return nil, nil
	end
	return portalMin, portalMax
end

local function getSharedAxisCoord(point, exitDir)
	if exitDir == 2 or exitDir == 4 then
		return point.y
	end
	return point.x
end

local function isExitInPortal(exitPoint, exitDir, portalMin, portalMax)
	local coord = getSharedAxisCoord(exitPoint, exitDir)
	return coord >= portalMin and coord <= portalMax
end

-- Per-connection portal on shared axis (door pos ± hull half-width, clipped to edge overlap)
local function getPortalSpanForConnection(currentNode, neighborNode, exitDir, connection, nodes)
	local geoMin, geoMax = getSharedPortalSpan(currentNode, neighborNode, exitDir)
	if not geoMin then
		return nil, nil
	end

	local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
	local connNode = nodes[targetId]
	if isAreaNode(connNode) then
		return geoMin, geoMax
	end

	if connNode and connNode.pos then
		local coord = getSharedAxisCoord(connNode.pos, exitDir)
		local portalMin = math.max(geoMin, coord - DOOR_PORTAL_HALF_WIDTH)
		local portalMax = math.min(geoMax, coord + DOOR_PORTAL_HALF_WIDTH)
		if portalMax <= portalMin then
			return nil, nil
		end
		return portalMin, portalMax
	end

	return geoMin, geoMax
end

local function resolveConnectionToNeighborArea(connection, currentNodeId, nodes)
	local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
	local target = nodes[targetId]
	if not target then
		return nil
	end

	if isAreaNode(target) then
		if target.id ~= currentNodeId then
			return target
		end
		return nil
	end

	-- Door id encodes the two areas: "4053_4224_left"
	local pair = string.match(tostring(targetId), "^(%d+_%d+)_")
	if pair then
		local areaA, areaB = string.match(pair, "^(%d+)_(%d+)$")
		if areaA and areaB then
			areaA = tonumber(areaA)
			areaB = tonumber(areaB)
			if areaA == currentNodeId then
				return nodes[areaB]
			end
			if areaB == currentNodeId then
				return nodes[areaA]
			end
		end
	end

	return nil
end

-- Phase 1: exit coord must land in a real connection portal on the shared axis
local function findNeighborAtExit(currentNode, exitPoint, exitDir, nodes)
	local dirData = currentNode.c[exitDir]
	if not dirData or not dirData.connections then
		return nil
	end

	local exitCoord = getSharedAxisCoord(exitPoint, exitDir)

	for i = 1, #dirData.connections do
		local connection = dirData.connections[i]
		local neighborArea = resolveConnectionToNeighborArea(connection, currentNode.id, nodes)
		if neighborArea then
			local portalMin, portalMax =
				getPortalSpanForConnection(currentNode, neighborArea, exitDir, connection, nodes)
			if portalMin and isExitInPortal(exitPoint, exitDir, portalMin, portalMax) then
				if DEBUG_MODE then
					print(
						string.format(
							"[IsNavigable]   Portal dir=%d area=%d: coord=%.1f portal=[%.1f,%.1f]",
							exitDir,
							neighborArea.id,
							exitCoord,
							portalMin,
							portalMax
						)
					)
				end
				return neighborArea
			end
		end
	end

	if DEBUG_MODE then
		print(string.format("[IsNavigable] FAIL: coord %.1f not in any portal on dir %d (wall)", exitCoord, exitDir))
	end
	return nil
end

local function runTraceHull(startPos, endPos)
	return getTraceHull()(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- One hull trace across a segment (step height, optional jump retry)
local function traceOneBigSegment(startPos, endPos, _startNormal, allowJump)
	local toTarget = endPos - startPos
	if toTarget:Length() < 0.001 then
		return true
	end

	local horizDist = math.sqrt(toTarget.x * toTarget.x + toTarget.y * toTarget.y)
	if horizDist < 0.001 then
		return math.abs(toTarget.z) <= (allowJump and JUMP_HEIGHT or STEP_HEIGHT) + 8
	end

	local stepHeights = allowJump and { STEP_HEIGHT, JUMP_HEIGHT } or { STEP_HEIGHT }
	for stepIndex = 1, #stepHeights do
		local stepVec = Vector3(0, 0, stepHeights[stepIndex])
		local trace = runTraceHull(startPos + stepVec, endPos + stepVec)
		if trace.fraction >= 0.999 then
			return true
		end
		if DEBUG_MODE and stepIndex < #stepHeights then
			print(string.format("[IsNavigable] Segment blocked at step %d, trying jump...", stepHeights[stepIndex]))
		end
	end

	return false
end

-- MAIN FUNCTION - Phase 1: portal check per crossing; hull trace inline (fail fast)
-- allowJump: if true, will use jump height (72) when step height (18) fails
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors, allowJump)
	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	if DEBUG_MODE then
		hullTraces = {}
		debugFailLine = nil
	end

	-- ============ PHASE 1: Verify path through nodes ============
	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {} -- Waypoints for Phase 2

	-- Get starting ground Z
	local startZ, startNormal = getGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	-- Fixed XY bearing toward goal for the whole march (no horizontal bending)
	local pathLineOrigin = Vector3(currentPos.x, currentPos.y, 0)
	local pathLineDelta = Vector3(goalPos.x - pathLineOrigin.x, goalPos.y - pathLineOrigin.y, 0)
	if pathLineDelta:Length() < 0.001 then
		setDebugResult(false)
		return false
	end
	local pathLineDir = Common.Normalize(pathLineDelta)

	-- Add start waypoint
	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = startNormal,
	})

	local visitedNodes = {}

	-- Traverse to destination (no traces - just verify path exists)
	for iteration = 1, MAX_ITERATIONS do
		if visitedNodes[currentNode.id] then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: Cycle detected at node %d", currentNode.id))
			end
			saveDebugPath(waypoints)
			setDebugResult(false)
			return false
		end
		visitedNodes[currentNode.id] = true

		-- Check if goal reached
		if isPointInNodeBounds(goalPos, currentNode) then
			local goalZ, goalNormal = getGroundZFromQuad(goalPos, currentNode)
			local goalWpPos = goalZ and Vector3(goalPos.x, goalPos.y, goalZ) or goalPos
			if not traceOneBigSegment(currentPos, goalWpPos, goalNormal, allowJump) then
				if DEBUG_MODE then
					print(string.format("[IsNavigable] FAIL: Final segment to goal blocked in node %d", currentNode.id))
				end
				saveDebugPath(waypoints)
				saveDebugFail(currentPos, goalWpPos)
				setDebugResult(false)
				return false
			end
			table.insert(waypoints, { pos = goalWpPos, node = currentNode, normal = nil })
			saveDebugPath(waypoints)
			if DEBUG_MODE then
				print(string.format("[IsNavigable] SUCCESS: reached goal in node %d", currentNode.id))
			end
			setDebugResult(true)
			return true
		end

		-- Snap XY onto the fixed goal line (pitch/Z comes from nav quad only)
		local snappedX, snappedY = projectXYOntoGoalLine(currentPos.x, currentPos.y, pathLineOrigin, pathLineDir)
		local groundZ, groundNormal = getGroundZFromQuad(Vector3(snappedX, snappedY, currentPos.z), currentNode)
		if groundZ then
			currentPos = Vector3(snappedX, snappedY, groundZ)
		else
			currentPos = Vector3(snappedX, snappedY, currentPos.z)
		end

		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, pathLineDir, currentNode)

		if exitPoint then
			local exitZ = getGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				exitPoint = Vector3(exitPoint.x, exitPoint.y, exitZ)
			end
		end

		if not exitPoint or not exitDir then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			saveDebugPath(waypoints)
			saveDebugFail(currentPos, currentPos + pathLineDir * 50)
			setDebugResult(false)
			return false
		end

		if DEBUG_MODE then
			local dirNames = { [1] = "N", [2] = "E", [3] = "S", [4] = "W" }
			print(
				string.format(
					"[IsNavigable] Exit via %s at (%.1f, %.1f)",
					dirNames[exitDir] or "?",
					exitPoint.x,
					exitPoint.y
				)
			)
		end

		-- Find neighbor
		local neighborNode = findNeighborAtExit(currentNode, exitPoint, exitDir, nodes)

		if not neighborNode then
			if DEBUG_MODE then
				print(
					string.format(
						"[IsNavigable] FAIL: No neighbor found at exit (%.1f, %.1f)",
						exitPoint.x,
						exitPoint.y
					)
				)
			end
			saveDebugPath(waypoints)
			saveDebugFail(currentPos, exitPoint)
			setDebugResult(false)
			return false
		end

		-- Entry stays on the shared edge / goal line (no independent X/Y clamping)
		local entryX, entryY = projectXYOntoGoalLine(exitPoint.x, exitPoint.y, pathLineOrigin, pathLineDir)
		local entryZ, entryNormal = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)

		if not entryZ then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No ground geometry at entry to node %d", neighborNode.id))
			end
			saveDebugPath(waypoints)
			saveDebugFail(currentPos, exitPoint)
			setDebugResult(false)
			return false
		end

		local entryPos = Vector3(entryX, entryY, entryZ)

		-- Fail fast: one hull trace per crossing (stop marching if blocked)
		if not traceOneBigSegment(currentPos, entryPos, groundNormal, allowJump) then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: Crossing %d -> %d blocked", currentNode.id, neighborNode.id))
			end
			saveDebugPath(waypoints)
			saveDebugFail(currentPos, entryPos)
			setDebugResult(false)
			return false
		end

		-- Add intermediate waypoint if Z changes significantly (for slopes/hills)
		local zDiff = math.abs(entryZ - currentPos.z)
		if zDiff > 8 then
			-- Create intermediate waypoint at exit point with interpolated Z
			local exitZ = getGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				local exitPos = Vector3(exitPoint.x, exitPoint.y, exitZ)
				local _, exitNormal = getGroundZFromQuad(exitPoint, currentNode)
				table.insert(waypoints, { pos = exitPos, node = currentNode, normal = exitNormal })
				if DEBUG_MODE then
					print(string.format("[IsNavigable] Added slope waypoint at exit (Z=%.1f)", exitZ))
				end
			end
		end

		table.insert(waypoints, { pos = entryPos, node = neighborNode, normal = entryNormal })

		if DEBUG_MODE then
			print(string.format("[IsNavigable] Crossed to node %d (Z=%.1f)", neighborNode.id, entryZ))
		end

		currentPos = entryPos
		currentNode = neighborNode
	end

	if DEBUG_MODE then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
		saveDebugPath(waypoints)
		setDebugResult(false)
	end
	return false
end

function Navigable.GetDebugWaypoints()
	return debugWaypoints
end

function Navigable.GetDebugHullTraceCount()
	return #hullTraces
end

function Navigable.SetDebugResult(isNavigable)
	setDebugResult(isNavigable)
end

-- Debug: green/red = area path, blue = clear hull traces, red = blocked hull / portal wall
function Navigable.DrawDebugTraces()
	if not DEBUG_MODE then
		return
	end

	if debugWaypoints and #debugWaypoints >= 1 and debugLastResult ~= nil then
		setPathDrawColor(debugLastResult)

		for i = 1, #debugWaypoints - 1 do
			local a = debugWaypoints[i].pos
			local b = debugWaypoints[i + 1].pos
			if a and b then
				Common.DrawArrowLine(a, b, 8, 14, false)
			end
		end

		for i = 1, #debugWaypoints do
			local wp = debugWaypoints[i]
			if wp.pos then
				setPathDrawColor(debugLastResult)
				drawWorldLine(wp.pos, wp.pos + Vector3(0, 0, 20))
			end
		end
	end

	if debugFailLine and debugFailLine.from and debugFailLine.to then
		draw.Color(255, 0, 0, 255)
		Common.DrawArrowLine(debugFailLine.from, debugFailLine.to, 12, 22, false)
		drawWorldLine(debugFailLine.to, debugFailLine.to + Vector3(0, 0, 32))
	end

	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			if trace.blocked then
				draw.Color(255, 0, 0, 255)
			else
				draw.Color(0, 80, 255, 255)
			end
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_MODE = enabled == true
	if not DEBUG_MODE then
		hullTraces = {}
		debugWaypoints = nil
		debugLastResult = nil
		debugFailLine = nil
	end
end

return Navigable
