--!native
--!optimize 2

-- Configs --
const COMPONENT_STRIDE = 12 :: number

-- Buffers
const PositionBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local PositionData = {}

function PositionData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writef32(PositionBuffer, MemoryOffset, X)
	buffer.writef32(PositionBuffer, MemoryOffset + 4, Y)
	buffer.writef32(PositionBuffer, MemoryOffset + 8, Z)

	return MemoryOffset + COMPONENT_STRIDE
end

function PositionData.GetData(): buffer
	return PositionBuffer
end

return PositionData
