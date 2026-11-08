local PositionData = {}

local PositionBuffer = buffer.create(100000) -- 100 000 bytes or 100 kbs

function PositionData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writef32(PositionBuffer, MemoryOffset, X)
	buffer.writef32(PositionBuffer, MemoryOffset + 4, Y)
	buffer.writef32(PositionBuffer, MemoryOffset + 8, Z)

	return MemoryOffset + 12
end

function PositionData.GetData(): buffer
	return PositionBuffer
end

return PositionData
