--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript

-- Buffers
const VisualBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local VisualData = {}

function VisualData.CreateLayout(MemoryOffset: number, R: number, G: number, B: number): number
	return ECSMain.CreateVisualLayout(VisualBuffer, MemoryOffset, R, G, B)
end

function VisualData.GetData(): buffer
	return VisualBuffer
end

return VisualData
