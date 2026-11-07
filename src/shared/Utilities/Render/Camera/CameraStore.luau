local CameraState = {}

local CameraTable = {
	CameraCFrame = CFrame.new(5, 5, 5),
	CameraFOV = 70,
	CameraType = Enum.CameraType.Scriptable,
	CameraSubject = nil :: Instance?,
}

local CameraPosition = Vector3.new(0, 0, 0)

local CameraRight = Vector3.new(1, 0, 0)
local CameraUp = Vector3.new(0, 1, 0)
local CameraLook = Vector3.new(0, 0, 1)

local CurrentCamera = workspace.CurrentCamera

local function VectorsToRotation(LookVector: Vector3, UpVector: Vector3, RightVector: Vector3): CFrame
	local vZ = -LookVector.Unit
	local vY = UpVector.Unit
	local vX = RightVector.Unit
	return CFrame.fromMatrix(Vector3.zero, vX, vY, vZ)
end

local FixedPosition = Vector3.new(0, 1000, -5000)

game:GetService("RunService").RenderStepped:Connect(function()
	local CameraCFrameDecoy = CameraTable.CameraCFrame

	CameraPosition = CameraCFrameDecoy.Position
	CameraRight = CameraCFrameDecoy.RightVector
	CameraUp = CameraCFrameDecoy.UpVector
	CameraLook = CameraCFrameDecoy.LookVector

	local CameraCFrame = CameraTable.CameraCFrame

	local TargetRotation = VectorsToRotation(CameraCFrame.LookVector, CameraCFrame.UpVector, CameraCFrame.RightVector)

	CurrentCamera.CFrame = CFrame.new(FixedPosition) * TargetRotation
end)

function CameraState.GetCameraTable()
	return CameraTable
end

function CameraState.GetCameraPosition()
	return CameraPosition
end

function CameraState.GetCameraRight()
	return CameraRight
end

function CameraState.GetCameraUp()
	return CameraUp
end

function CameraState.GetCameraLook()
	return CameraLook
end

return CameraState
