---@diagnostic disable: duplicate-set-field, undefined-field

---@type NavMenu
local DefaultConfig = require("NavBot.Utils.DefaultConfig")
local Constants = require("NavBot.Utils.Constants")

local defaultPlayer = {
	entity = nil,
	index = 1,
	team = 1,
	Class = 1,
	flags = 1,
	OnGround = true,
	Origin = Vector3(0, 0, 0),
	ViewAngles = EulerAngles(90, 0, 0),
	Viewheight = Vector3(0, 0, 75),
	VisPos = Vector3(0, 0, 75),
	vHitbox = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 45) },
}

local worldDefault = {
	players = {},
	healthPacks = {},
	spawns = {},
	payloads = {},
	flags = {},
}

---@type NavBotGlobals
local G = {
	-- Filled by NavBot.Utils.Config.LoadCFG; never alias DefaultConfig (shared table breaks saves).
	Menu = {},
	Default = defaultPlayer,
	pLocal = defaultPlayer,
	World_Default = worldDefault,
	World = worldDefault,
	Misc = {
		NodeTouchDistance = 16,
		NodeOvershootTouchDistance = 48,
		NodeTouchHeight = Constants.HITBOX.MAX_JUMP_HEIGHT, -- 72u: full jump apex can still touch/pass nodes
		NodePassProximity = 16,
		NodePassDirDotThreshold = 0.5,
		NodePassAngleDegrees = 60,
		workLimit = 1,
	},
	---@type table Navigation module table + runtime path state (replaced in Main.lua)
	Navigation = {
		path = nil,
		nodes = nil,
		currentNodeIndex = 1,
		currentNodeTicks = 0,
		stuckStartTick = nil,
		FirstAgentNode = 1,
		SecondAgentNode = 2,
		lastKnownTargetPosition = nil,
		goalPos = nil,
		goalNodeId = nil,
		navMeshUpdated = false,
		kdTree = nil,
		areaGrid = nil,
		lastSkipCheckTick = 0,
		nextNodeCloser = false,
	},
	SmartJump = {
		Constants = {
			GRAVITY = 800,
			JUMP_FORCE = 271,
			MAX_JUMP_HEIGHT = Vector3(0, 0, 72),
			MAX_WALKABLE_ANGLE = 55,
			STATE_IDLE = "STATE_IDLE",
			STATE_PREPARE_JUMP = "STATE_PREPARE_JUMP",
			STATE_CTAP = "STATE_CTAP",
			STATE_ASCENDING = "STATE_ASCENDING",
			STATE_DESCENDING = "STATE_DESCENDING",
		},
		jumpState = "STATE_IDLE",
		leftGroundThisJump = false,
		ShouldJump = false,
		LastSmartJumpAttempt = 0,
		LastEmergencyJump = 0,
		ObstacleDetected = false,
		RequestEmergencyJump = false,
		SimulationPath = {},
		PredPos = nil,
		JumpPeekPos = nil,
		HitObstacle = false,
		lastAngle = nil,
		stateStartTime = nil,
		lastState = nil,
		lastAdvanceTick = -1,
		suppressStuckUntilTick = nil,
		jumpCommitUntilTick = nil,
		jumpFailCooldownUntil = nil,
		lastJumpTime = 0,
		LastObstacleHeight = 0,
	},
	BotIsMoving = false,
	BotMovementDirection = Vector3(0, 0, 0),
	BotIntendedWishDir = nil,
	Cache = {
		lastCleanup = 0,
		cleanupInterval = 500,
		maxCacheSize = 1000,
	},
	Tasks = {
		None = 0,
		Objective = 1,
		Follow = 2,
		Health = 3,
		Medic = 4,
		Goto = 5,
	},
	Current_Tasks = {},
	Current_Task = 1,
	Benchmark = {
		MemUsage = 0,
	},
	States = {
		IDLE = "IDLE",
		PATHFINDING = "PATHFINDING",
		MOVING = "MOVING",
		STUCK = "STUCK",
		FOLLOWING = "FOLLOWING",
	},
	currentState = nil,
	prevState = nil,
	wasManualWalking = false,
}

G.Current_Task = G.Tasks.Objective

return G
