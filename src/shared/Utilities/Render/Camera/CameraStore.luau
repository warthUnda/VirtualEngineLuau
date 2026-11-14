--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const CameraHelper = require(script.Parent.CameraHelper)

-- Configs --
const FIXED_POSITION = SystemsConfigs.CameraFixedPosition :: Vector3
const DEFAULT_CAMERA_CFRAME = SystemsConfigs.DefaultCameraCFrame :: CFrame
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number

-- Tables --
local CameraTable = {
	CameraCFrame = DEFAULT_CAMERA_CFRAME,
	CameraFOV = DEFAULT_CAMERA_FOV,
	CameraType = Enum.CameraType.Scriptable,
	CameraSubject = nil :: Instance?,
}

local CameraPosition = Vector3.new(0, 0, 0) :: Vector3
local CameraRight = Vector3.new(1, 0, 0) :: Vector3
local CameraUp = Vector3.new(0, 1, 0) :: Vector3
local CameraLook = Vector3.new(0, 0, 1) :: Vector3

local CameraStore = {}

-- ============================================================================
-- 1. CAMERA SYNC - UPDATES CAMERA STATE EACH FRAME
-- ============================================================================

RunService.RenderStepped:Connect(function()
	const CameraCFrame = CameraTable.CameraCFrame :: CFrame

	CameraPosition = CameraCFrame.Position
	CameraRight = CameraCFrame.RightVector
	CameraUp = CameraCFrame.UpVector
	CameraLook = CameraCFrame.LookVector

	const TargetRotation = CameraHelper.VectorsToRotation(CameraLook, CameraUp, CameraRight)
	const ActiveCamera = workspace.CurrentCamera
	if ActiveCamera then
		if ActiveCamera.CameraType ~= Enum.CameraType.Scriptable then
			ActiveCamera.CameraType = Enum.CameraType.Scriptable
		end
		ActiveCamera.CFrame = CFrame.new(FIXED_POSITION) * TargetRotation
	end
end)

--[=[
	Returns the shared camera configuration and state table.
	@return table -- Camera state dictionary containing CameraCFrame and CameraFOV.
]=]
function CameraStore.GetCameraTable()
	return CameraTable
end

--[=[
	Returns the latest cached camera world position.
	@return Vector3 -- Current camera world position.
]=]
function CameraStore.GetCameraPosition(): Vector3
	return CameraPosition
end

--[=[
	Returns the current camera RightVector basis vector.
	@return Vector3 -- Current camera right direction.
]=]
function CameraStore.GetCameraRight(): Vector3
	return CameraRight
end

--[=[
	Returns the current camera UpVector basis vector.
	@return Vector3 -- Current camera up direction.
]=]
function CameraStore.GetCameraUp(): Vector3
	return CameraUp
end

--[=[
	Returns the current camera LookVector basis vector.
	@return Vector3 -- Current camera look direction.
]=]
function CameraStore.GetCameraLook(): Vector3
	return CameraLook
end

return CameraStore
