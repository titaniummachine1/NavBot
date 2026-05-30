---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Imports ]]
local G = require("NavBot.Core.Globals")
local Default_Config = require("NavBot.Utils.DefaultConfig")
local Serializer = require("NavBot.Utils.Serializer")
local json = require("NavBot.Utils.Json")

local Config = {}

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

local function getConfigPath()
	local _, fullPath = filesystem.CreateDirectory(folder_name)
	local sep = package.config:sub(1, 1)
	return fullPath .. sep .. "config.cfg"
end

function Config.GetFilePath()
	return getConfigPath()
end

--- Ensure every expected key exists (handles partial / upgraded configs).
local function safeInitMenu()
	if not G.Menu then
		G.Menu = Serializer.deepCopy(Default_Config)
		return
	end

	local function ensureField(parent, key, default)
		if parent[key] == nil then
			parent[key] = Serializer.deepCopy(default)
		elseif type(default) == "table" and type(parent[key]) == "table" then
			for k, v in pairs(default) do
				ensureField(parent[key], k, v)
			end
		end
	end

	for key, value in pairs(Default_Config) do
		ensureField(G.Menu, key, value)
	end
end

--- Legacy JSON configs (pre-Serializer).
local function tryLoadJson(content)
	if not content or content:sub(1, 1) ~= "{" then
		return nil
	end
	local ok, cfg = pcall(json.decode, content)
	if ok and type(cfg) == "table" then
		return cfg
	end
	return nil
end

local function tryLoadLuaConfig(content)
	if not content or content == "" then
		return nil
	end
	local chunk, err = load("return " .. content)
	if not chunk then
		return nil, err
	end
	local ok, cfg = pcall(chunk)
	if ok and type(cfg) == "table" then
		return cfg
	end
	return nil
end

function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or G.Menu or Default_Config
	local path = getConfigPath()
	local body = Serializer.serializeTable(cfgTable)
	local success = Serializer.writeFile(path, body)
	if not success then
		printc(255, 0, 0, 255, "[Config] Failed to write: " .. path)
		return false
	end
	local shortPath = path:match(".*[\\/](.+[\\/].+)$") or path
	printc(100, 183, 0, 255, "[Config] Saved: " .. shortPath)
	return true
end

function Config.LoadCFG()
	local path = getConfigPath()
	local content = Serializer.readFile(path)
	local needsRewrite = false
	local shiftHeld = input.IsButtonDown(KEY_LSHIFT)

	if not content or shiftHeld then
		if shiftHeld then
			printc(255, 200, 100, 255, "[Config] SHIFT held – creating fresh config...")
		else
			printc(255, 200, 100, 255, "[Config] No config found, creating default...")
		end
		G.Menu = Serializer.deepCopy(Default_Config)
		safeInitMenu()
		Config.CreateCFG(G.Menu)
		return G.Menu
	end

	local cfg, compileErr = tryLoadLuaConfig(content)
	if not cfg then
		cfg = tryLoadJson(content)
		if cfg then
			printc(255, 200, 100, 255, "[Config] Migrated JSON config to Lua format.")
			needsRewrite = true
		end
	end

	if not cfg then
		printc(255, 100, 100, 255, "[Config] Invalid config – regenerating: " .. tostring(compileErr))
		G.Menu = Serializer.deepCopy(Default_Config)
		safeInitMenu()
		Config.CreateCFG(G.Menu)
		return G.Menu
	end

	printc(0, 255, 140, 255, "[Config] Loaded: " .. path)
	G.Menu = cfg
	if not Serializer.keysMatch(Default_Config, cfg) then
		printc(255, 200, 100, 255, "[Config] Missing options detected – merging defaults...")
		needsRewrite = true
	end
	safeInitMenu()
	if needsRewrite then
		Config.CreateCFG(G.Menu)
	end
	return G.Menu
end

Config.LoadCFG()

local function configAutoSaveOnUnload()
	print("[CONFIG] Unloading script, saving configuration...")
	if G.Menu then
		Config.CreateCFG(G.Menu)
	else
		printc(255, 0, 0, 255, "[CONFIG] Warning: Unable to save config, G.Menu is nil")
	end
end

callbacks.Unregister("Unload", "NavBot.ConfigAutoSaveOnUnload")
callbacks.Register("Unload", "NavBot.ConfigAutoSaveOnUnload", configAutoSaveOnUnload)

return Config
