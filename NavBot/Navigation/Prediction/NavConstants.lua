--[[ Imported by: NavGeometry, NavTrace, NavPredict ]]

local NavConstants = {}

NavConstants.PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
NavConstants.STEP_HEIGHT = 18
NavConstants.JUMP_HEIGHT = 72
NavConstants.MAX_FALL_DISTANCE = 250
NavConstants.UP_VECTOR = Vector3(0, 0, 1)
NavConstants.MAX_ITERATIONS = 37
NavConstants.OPPOSITE_EXIT_DIR = { [1] = 3, [3] = 1, [2] = 4, [4] = 2 }
NavConstants.SLOPE_WAYPOINT_Z_DIFF = 8
NavConstants.DOOR_HALF_WIDTH = 12 -- matches DoorGeometry HITBOX_WIDTH / 2
NavConstants.DOOR_SNAP_TOLERANCE = 24 -- snap straight-line exit onto nearest door portal

return NavConstants
