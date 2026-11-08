local OrientationData = {}

local OrientationBuffer = buffer.create(100000) -- 100 000 bytes or 100 kbs

function OrientationData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writei16(OrientationBuffer, MemoryOffset, X)
	buffer.writei16(OrientationBuffer, MemoryOffset + 2, Y)
	buffer.writei16(OrientationBuffer, MemoryOffset + 4, Z)

	return MemoryOffset + 6
end

function OrientationData.GetData(): buffer
	return OrientationBuffer
end

return OrientationData
