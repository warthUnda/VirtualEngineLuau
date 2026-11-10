--!native
--!optimize 2

-- Configs --
-- 36 bytes per entity: look, up and right vectors stored as 3 x f32 each.
const DIRECTION_STRIDE = 36 :: number

-- Buffers
const DirectionsBuffer = buffer.create(300000) :: buffer -- 300 000 bytes or 300 kbs

local DirectionsData = {}

function DirectionsData.CreateLayout(
	MemoryOffset: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	RightX: number,
	RightY: number,
	RightZ: number
): number
	buffer.writef32(DirectionsBuffer, MemoryOffset, LookX)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 4, LookY)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 8, LookZ)

	buffer.writef32(DirectionsBuffer, MemoryOffset + 12, UpX)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 16, UpY)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 20, UpZ)

	buffer.writef32(DirectionsBuffer, MemoryOffset + 24, RightX)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 28, RightY)
	buffer.writef32(DirectionsBuffer, MemoryOffset + 32, RightZ)

	return MemoryOffset + DIRECTION_STRIDE
end

function DirectionsData.GetData(): buffer
	return DirectionsBuffer
end

return DirectionsData
