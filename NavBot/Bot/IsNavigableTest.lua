--[[
    IsNavigable Test Suite
    Test module for node-based navigation skipping
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isNavigable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
}

-- Load Navigable module
local Navigable = require("NavBot.Navigation.isWalkable.isNavigable")

-- Constants
local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }

-- Benchmark functions
local function BenchmarkStart()
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- Draw 3D box at position
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local function syncNavigableDebug()
	local showDebug = G.Menu.Visuals.IsNavigableTest == true
	Navigable.SetDebug(showDebug)
end

-- CreateMove callback
local function OnCreateMove(Cmd)
	syncNavigableDebug()

	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- F sets / moves the target point (one press per tick edge)
	if input.IsButtonPressed(KEY_F) then
		TestState.startPos = TestState.currentPos
		return
	end

	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		-- Get current node for start position
		local startNode = Node.GetAreaAtPosition(TestState.currentPos)

		if startNode then
			local startTime, startMemory = BenchmarkStart()
			local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
			TestState.isNavigable =
				Navigable.CanSkip(TestState.currentPos, TestState.startPos, startNode, true, allowJump)
			Navigable.SetDebugResult(TestState.isNavigable)
			BenchmarkStop(startTime, startMemory)
		else
			TestState.isNavigable = false
			Navigable.SetDebugResult(false)
		end
	end
end

-- Draw callback
local function OnDraw()
	syncNavigableDebug()

	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(20, 120, string.format("IsNavigable Test: %s", G.Menu.Visuals.IsNavigableTest and "ON" or "OFF"))
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isNavigable and "NAVIGABLE" or "NOT NAVIGABLE"))
	draw.Text(20, 240, "Press F to set target | Walk away to test")

	local debugWps = Navigable.GetDebugWaypoints()
	if debugWps then
		draw.Text(
			20,
			270,
			string.format("Area waypoints: %d | Hull traces: %d", #debugWps, Navigable.GetDebugHullTraceCount())
		)
		draw.Text(20, 300, "Green/red = area path | Blue = hull traces")
	end

	Navigable.DrawDebugTraces()
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("IsNavigable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("IsNavigable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local IsNavigableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "IsNavigableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "IsNavigableTest_Draw", OnDraw)

-- Add to global for easy access
G.IsNavigableTest = IsNavigableTest

print("IsNavigable Test Suite loaded. Use G.IsNavigableTest.Toggle() to enable/disable.")

return IsNavigableTest
