local OrientationData = {}

local OrientationBuffer = buffer.create(100000) -- 100 000 bytes or 100 kbs

function OrientationData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writef32(OrientationBuffer, MemoryOffset, X)
	buffer.writef32(OrientationBuffer, MemoryOffset + 4, Y)
	buffer.writef32(OrientationBuffer, MemoryOffset + 8, Z)

	return MemoryOffset + 12
end

function OrientationData.GetData(): buffer
	return OrientationBuffer
end

return OrientationData
