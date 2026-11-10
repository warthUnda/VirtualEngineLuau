--!native
--!optimize 2

-- Services --
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const CurrentCamera = workspace.CurrentCamera :: Camera

-- Configs --
const FIXED_POSITION = Vector3.new(0, 1000, -5000) :: Vector3

-- Tables --
local CameraTable = {
	CameraCFrame = CFrame.new(5, 5, 5),
	CameraFOV = 70,
	CameraType = Enum.CameraType.Scriptable,
	CameraSubject = nil :: Instance?,
}

local CameraPosition = Vector3.new(0, 0, 0) :: Vector3
local CameraRight = Vector3.new(1, 0, 0) :: Vector3
local CameraUp = Vector3.new(0, 1, 0) :: Vector3
local CameraLook = Vector3.new(0, 0, 1) :: Vector3

local CameraStore = {}

local function VectorsToRotation(LookVector: Vector3, UpVector: Vector3, RightVector: Vector3): CFrame
	const Vz = -LookVector.Unit :: Vector3
	const Vy = UpVector.Unit :: Vector3
	const Vx = RightVector.Unit :: Vector3
	return CFrame.fromMatrix(Vector3.zero, Vx, Vy, Vz)
end

-- ============================================================================
-- 1. CAMERA SYNC - UPDATES CAMERA STATE EACH FRAME
-- ============================================================================

RunService.RenderStepped:Connect(function()
	const CameraCFrame = CameraTable.CameraCFrame :: CFrame

	CameraPosition = CameraCFrame.Position
	CameraRight = CameraCFrame.RightVector
	CameraUp = CameraCFrame.UpVector
	CameraLook = CameraCFrame.LookVector

	const TargetRotation = VectorsToRotation(CameraLook, CameraUp, CameraRight)
	CurrentCamera.CFrame = CFrame.new(FIXED_POSITION) * TargetRotation
end)

function CameraStore.GetCameraTable()
	return CameraTable
end

function CameraStore.GetCameraPosition(): Vector3
	return CameraPosition
end

function CameraStore.GetCameraRight(): Vector3
	return CameraRight
end

function CameraStore.GetCameraUp(): Vector3
	return CameraUp
end

function CameraStore.GetCameraLook(): Vector3
	return CameraLook
end

return CameraStore
