local CameraStore = {}

local CameraTable = {
	CameraCFrame = CFrame.new(5, 5, 5),
	CameraFOV = 70,
	CameraType = Enum.CameraType.Scriptable,
	CameraSubject = nil :: Instance?,
}

local SecondaryTable = {
	CameraCFrame = CFrame.new(5, 5, 5),
	CameraFOV = 70,
	CameraType = Enum.CameraType.Scriptable,
	CameraSubject = nil :: Instance?,
}

function CameraStore.ReturnCameraTable()
	return CameraTable
end

function CameraStore.ReturnSecondaryTable()
	return SecondaryTable
end

return CameraStore
