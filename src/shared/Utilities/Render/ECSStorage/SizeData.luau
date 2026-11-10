--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain")) :: ModuleScript

-- Buffers
const SizeBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local SizeData = {}

function SizeData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	return ECSMain.CreateVector3Layout(SizeBuffer, MemoryOffset, X, Y, Z)
end

function SizeData.GetData(): buffer
	return SizeBuffer
end

return SizeData
