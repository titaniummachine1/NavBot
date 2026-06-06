--[[
NavMath — shared 2D nav geometry (single source; do not duplicate in path modules)
]]

local Common = require("NavBot.Core.Common")

local NavMath = {}

function NavMath.horizontalDir2D(from, to)
	if not (from and to) then
		return nil
	end
	local dx = to.x - from.x
	local dy = to.y - from.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then
		return nil
	end
	return Vector3(dx / len, dy / len, 0)
end

function NavMath.horizontalUnit2D(vec)
	if not vec then
		return nil
	end
	local flat = Vector3(vec.x, vec.y, 0)
	local len = flat:Length2D()
	if len < 0.001 then
		return nil
	end
	return flat / len
end

function NavMath.sharedAxisCoord(point, exitDir)
	if exitDir == 2 or exitDir == 4 then
		return point.y
	end
	return point.x
end

function NavMath.isCoordInSpan(coord, spanMin, spanMax, tolerance)
	if not coord or not spanMin or not spanMax then
		return false
	end
	local margin = tolerance or 0
	return coord >= (spanMin - margin) and coord <= (spanMax + margin)
end

function NavMath.distance2D(a, b)
	return Common.Distance2D(a, b)
end

return NavMath
