--!native
--!optimize 2

-- Configs --
const COMPONENT_STRIDE = 12 :: number

-- Buffers
const SizeBuffer = buffer.create(100000) :: buffer -- 100 000 bytes or 100 kbs

local SizeData = {}

-- Same 12-byte (3 x f32) stride as position and orientation.
function SizeData.CreateLayout(MemoryOffset: number, X: number, Y: number, Z: number): number
	buffer.writef32(SizeBuffer, MemoryOffset, X)
	buffer.writef32(SizeBuffer, MemoryOffset + 4, Y)
	buffer.writef32(SizeBuffer, MemoryOffset + 8, Z)

	return MemoryOffset + COMPONENT_STRIDE
end

function SizeData.GetData(): buffer
	return SizeBuffer
end

return SizeData
