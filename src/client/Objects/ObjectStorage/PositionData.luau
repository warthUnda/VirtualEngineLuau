--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript

-- Buffers
const PositionBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local PositionData = {}

function PositionData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	return ECSMain.CreateVector3Layout(PositionBuffer, MemoryOffset, X, Y, Z)
end

function PositionData.GetData(): buffer
	return PositionBuffer
end

return PositionData
