--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript

-- Buffers
const DirectionsBuffer = buffer.create(300000) :: buffer -- 300 000 bytes or 300 kbs

local DirectionsData = {}

function DirectionsData.CreateLayout(
	MemoryOffset: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	RightX: number,
	RightY: number,
	RightZ: number
): number
	return ECSMain.CreateDirectionsLayout(
		DirectionsBuffer,
		MemoryOffset,
		LookX,
		LookY,
		LookZ,
		UpX,
		UpY,
		UpZ,
		RightX,
		RightY,
		RightZ
	)
end

function DirectionsData.GetData(): buffer
	return DirectionsBuffer
end

return DirectionsData
