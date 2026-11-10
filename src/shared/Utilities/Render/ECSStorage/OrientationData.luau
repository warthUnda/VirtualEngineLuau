--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript

-- Buffers
const OrientationBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local OrientationData = {}

function OrientationData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	return ECSMain.CreateVector3Layout(OrientationBuffer, MemoryOffset, X, Y, Z)
end

function OrientationData.GetData(): buffer
	return OrientationBuffer
end

return OrientationData
