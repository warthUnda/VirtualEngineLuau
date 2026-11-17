--!strict
--!native
--!optimize 2

--[=[
	@class CameraStore
	Read-only facade exposing the active OOP CameraObject state table and basis
	vectors to client physics/player/culling systems.
]=]

-- Libraries --
const CameraService = require(script.Parent.CameraService)

-- Tables --
local CameraStore = {}

-- Functions --
-- ============================================================================
-- 1. CAMERA STORE FACADE
-- ============================================================================

--[=[
	Returns the active OOP CameraObject as the shared camera state table (CameraCFrame, CameraFOV).
	@return CameraService.CameraObject -- Active camera state object.
]=]
function CameraStore.GetCameraTable(): CameraService.CameraObject
	return CameraService.GetActiveCamera()
end

--[=[
	Returns the active camera's world position.
	@return Vector3 -- Current camera world position.
]=]
function CameraStore.GetCameraPosition(): Vector3
	return CameraService.GetActiveCamera().CameraCFrame.Position
end

--[=[
	Returns the active camera's RightVector basis direction.
	@return Vector3 -- Current camera right direction.
]=]
function CameraStore.GetCameraRight(): Vector3
	return CameraService.GetActiveCamera().CameraCFrame.RightVector
end

--[=[
	Returns the active camera's UpVector basis direction.
	@return Vector3 -- Current camera up direction.
]=]
function CameraStore.GetCameraUp(): Vector3
	return CameraService.GetActiveCamera().CameraCFrame.UpVector
end

--[=[
	Returns the active camera's LookVector basis direction.
	@return Vector3 -- Current camera look direction.
]=]
function CameraStore.GetCameraLook(): Vector3
	return CameraService.GetActiveCamera().CameraCFrame.LookVector
end

return CameraStore
