--[[
	Table serialization and file I/O for NavBot config (from Cheater Detection).
]]

local Serializer = {}

local function deepCopy(orig)
	if type(orig) ~= "table" then
		return orig
	end
	local copy = {}
	for k, v in pairs(orig) do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function serializeTable(tbl, level, visited)
	level = level or 0
	visited = visited or {}
	local indent = string.rep("    ", level)
	local innerIndent = indent .. "    "
	local entries = {}

	for k, v in pairs(tbl) do
		local entryChunks = {}
		local safeKey = tostring(k):gsub("\\", "\\\\"):gsub('"', '\\"')
		local keyRepr = (type(k) == "string") and ('["' .. safeKey .. '"]') or ("[" .. safeKey .. "]")
		table.insert(entryChunks, innerIndent .. keyRepr .. " = ")

		if type(v) == "table" then
			if visited[v] then
				table.insert(entryChunks, '"--[[cycle]]"')
			else
				visited[v] = true
				table.insert(entryChunks, serializeTable(v, level + 1, visited))
			end
		elseif type(v) == "string" then
			local sanitized = v:gsub("[^%z\32-\126]", ""):sub(1, 128)
			sanitized = sanitized:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
			table.insert(entryChunks, '"' .. sanitized .. '"')
		else
			table.insert(entryChunks, tostring(v))
		end
		table.insert(entries, table.concat(entryChunks))
	end

	if #entries == 0 then
		return "{}"
	end

	return "{\n" .. table.concat(entries, ",\n") .. "\n" .. indent .. "}"
end

local function keysMatch(template, loaded)
	for k, v in pairs(template) do
		if loaded[k] == nil then
			return false
		end
		if type(v) == "table" and type(loaded[k]) == "table" then
			if not keysMatch(v, loaded[k]) then
				return false
			end
		end
	end
	return true
end

local function writeFile(path, data)
	local file = io.open(path, "w")
	if not file then
		return false
	end
	file:write(data)
	file:close()
	return true
end

local function readFile(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

Serializer.deepCopy = deepCopy
Serializer.serializeTable = serializeTable
Serializer.keysMatch = keysMatch
Serializer.writeFile = writeFile
Serializer.readFile = readFile

return Serializer
