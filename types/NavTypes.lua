---@meta NavBot
--- Nav mesh node types (used by A*, Navigation, Node.lua).

---@class Node
---@field id integer
---@field pos Vector3
---@field isDoor boolean|nil
---@field nw Vector3|nil
---@field ne Vector3|nil
---@field sw Vector3|nil
---@field se Vector3|nil
---@field c table|nil Directional connections (N/S/E/W buckets)
---@field _minX number|nil
---@field _maxX number|nil
---@field _minY number|nil
---@field _maxY number|nil
---@field _minZ number|nil
---@field _maxZ number|nil
---@field _floorZ number|nil
---@field _extentX number|nil
---@field _extentY number|nil

---@class NeighborData
---@field node Node
---@field cost number

---@alias NeighborDataArray NeighborData[]
