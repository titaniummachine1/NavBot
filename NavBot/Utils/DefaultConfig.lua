--[[
    Default menu schema for NavBot.
    Persisted via NavBot.Utils.Config (JSON). Types: types/NavBot.lua
]]

---@type NavMenu
local Default_Config = {
	Tab = "Main",
	Tabs = {
		Main = true,
		Navigation = false,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		EnableWalking = true, -- false = manual WASD only (pathfinding may still run)
		shouldfindhealth = true,
		SelfHealTreshold = 45,
		smoothFactor = 0.05,
		LookingAhead = true,
		Duck_Grab = true,
		MaxSkipRange = 500,
		MaxNodesToSkip = 3,
	},

	Navigation = {
		Skip_Nodes = true,
		StopDistance = 50,
		WalkableMode = "Smooth", -- "Smooth" = 18u steps; "Aggressive" = 72u jump links
		CleanupConnections = true,
		AllowExpensiveChecks = true,
	},

	Visuals = {
		EnableVisuals = true,
		connectionDepth = 4,
		memoryUsage = false,
		drawPath = true,
		showConnections = true,
		showAreas = true,
		showDoors = true,
		showCornerConnections = false,
		showD2D = false,
		showNodeIds = false,
		showAgentBoxes = false,
		showSmartJump = false,
		ISWalkableTest = false,
		OptimizedISWalkableTest = false,
		IsNavigableTest = false,
		Debug_Mode = false,
	},

	Movement = {
		lookatpath = true,
		smoothLookAtPath = true,
	},

	SmartJump = {
		Enable = true,
		Debug = false,
	},
}

return Default_Config
