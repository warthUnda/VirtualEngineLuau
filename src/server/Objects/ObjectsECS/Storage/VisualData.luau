local VisualData = {}

local VisualBuffer = buffer.create(100000) -- 100 000 bytes or 100 kbs

function VisualData.CreateLayout(MemoryOffset: number, R: number, G: number, B: number): number
	buffer.writeu8(VisualBuffer, MemoryOffset, R)
	buffer.writeu8(VisualBuffer, MemoryOffset + 1, G)
	buffer.writeu8(VisualBuffer, MemoryOffset + 2, B)

	-- Keep a 12-byte stride to match the orientation/position components.
	return MemoryOffset + 12
end

function VisualData.GetData(): buffer
	return VisualBuffer
end

return VisualData
