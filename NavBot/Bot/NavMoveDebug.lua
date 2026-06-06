--[[
Nav movement debug — one-line status when Navigation.MoveDebug is enabled.
Imported by: MovementDecisions, Navigation
]]

local Common = require("NavBot.Core.Common")
local G = require("NavBot.Core.Globals")
local Node = require("NavBot.Navigation.Node")
local NodeSkipper = require("NavBot.Bot.NodeSkipper")

local NavMoveDebug = {}
local Log = Common.Log.new("NavMove")

local STATUS_INTERVAL = 33
local lastStatusTick = 0
local lastBlockKey = nil

local function isEnabled()
	return G.Menu.Navigation and G.Menu.Navigation.MoveDebug == true
end

local function getPlayerAreaId(playerPos)
	local area = Node.GetAreaAtPosition(playerPos)
	return area and area.id or nil
end

local function getApexSummary()
	local apexes = G.Navigation.apexPath
	local idx = G.Navigation.apexIndex or 1
	if not apexes or not apexes[idx] then
		return "apex=none"
	end

	local apex = apexes[idx]
	return string.format(
		"apex[%d] %s %s->%s",
		idx,
		tostring(apex.kind or "?"),
		tostring(apex.areaId or "-"),
		tostring(apex.nextAreaId or "-")
	)
end

local function getSmartJumpState()
	local state = G.SmartJump and G.SmartJump.jumpState
	if not state or state == "STATE_IDLE" then
		return "idle"
	end
	return state
end

function NavMoveDebug.OnAdvanceBlocked(playerPos, currentNode, nextNode, reason)
	if not isEnabled() then
		return
	end
	if not (currentNode and nextNode and reason) then
		return
	end

	local key = tostring(currentNode.id) .. "->" .. tostring(nextNode.id) .. ":" .. reason
	if key == lastBlockKey then
		return
	end
	lastBlockKey = key

	local feetArea = getPlayerAreaId(playerPos)
	Log:Info(
		"BLOCKED %s->%s (%s) feet=%s dist2d=%.0f",
		tostring(currentNode.id),
		tostring(nextNode.id),
		reason,
		tostring(feetArea or "?"),
		Common.Distance2D(playerPos, nextNode.pos)
	)
end

function NavMoveDebug.OnAdvanced(currentId, reason)
	if not isEnabled() then
		return
	end
	lastBlockKey = nil
	Log:Info("ADVANCED left node %s (%s)", tostring(currentId), tostring(reason or "?"))
end

function NavMoveDebug.OnPathAligned(playerAreaId, pathLen)
	if not isEnabled() then
		return
	end
	Log:Info("PATH ALIGNED to area %s (pathLen=%d)", tostring(playerAreaId), pathLen or 0)
end

function NavMoveDebug.Tick(playerPos, speed2D)
	if not isEnabled() then
		return
	end
	if not playerPos then
		return
	end

	local now = globals.TickCount()
	if now - lastStatusTick < STATUS_INTERVAL then
		return
	end
	lastStatusTick = now

	local path = G.Navigation.path
	if not path or #path == 0 then
		return
	end

	local currentNode = path[1]
	local nextNode = path[2]
	local feetArea = getPlayerAreaId(playerPos)
	local targetPos = G.Navigation.currentTargetPos
	local targetDist = targetPos and Common.Distance2D(playerPos, targetPos) or -1
	local nextDist = nextNode and nextNode.pos and Common.Distance2D(playerPos, nextNode.pos) or -1
	local canAdvance, advanceReason = NodeSkipper.CanAdvanceToNext(playerPos, currentNode, nextNode)
	local advanceState = canAdvance and ("can:" .. tostring(advanceReason)) or tostring(advanceReason or "?")

	local segment = nextNode and string.format("%s->%s", tostring(currentNode.id), tostring(nextNode.id))
		or tostring(currentNode.id)

	Log:Info(
		"seg=%s len=%d feet=%s spd=%.0f tgt=%.0f next=%.0f advance=%s %s jump=%s",
		segment,
		#path,
		tostring(feetArea or "?"),
		speed2D or 0,
		targetDist,
		nextDist,
		advanceState,
		getApexSummary(),
		getSmartJumpState()
	)
end

return NavMoveDebug
