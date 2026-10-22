local CameraStore = {}

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

local currentCamera = workspace.CurrentCamera

local function vectorsToRotation(lookVector: Vector3, upVector: Vector3, rightVector: Vector3): CFrame
	local vZ = -lookVector.Unit
	local vY = upVector.Unit
	local vX = rightVector.Unit
	return CFrame.fromMatrix(Vector3.zero, vX, vY, vZ)
end

local fixedPosition = Vector3.new(0, 1000, -5000)

game:GetService("RunService").RenderStepped:Connect(function()
	local CameraCFrameDecoy = CameraTable.CameraCFrame

	CameraPosition = CameraCFrameDecoy.Position
	CameraRight = CameraCFrameDecoy.RightVector
	CameraUp = CameraCFrameDecoy.UpVector
	CameraLook = CameraCFrameDecoy.LookVector

	local CameraCFrame = CameraTable.CameraCFrame

	local targetRotation = vectorsToRotation(CameraCFrame.LookVector, CameraCFrame.UpVector, CameraCFrame.RightVector)

	currentCamera.CFrame = CFrame.new(fixedPosition) * targetRotation
end)

function CameraStore.ReturnCameraTable()
	return CameraTable
end

function CameraStore.ReturnCameraPosition()
	return CameraPosition
end

function CameraStore.ReturnCameraRight()
	return CameraRight
end

function CameraStore.ReturnCameraUp()
	return CameraUp
end

function CameraStore.ReturnCameraLook()
	return CameraLook
end

return CameraStore
