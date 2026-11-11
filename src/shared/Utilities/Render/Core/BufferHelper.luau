--!native
--!optimize 2

-- Buffers
local ClearTemplateSize = 0 :: number
local ClearPixelTemplate: buffer? = nil

local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = 28 :: number

function BufferHelper.CreateRenderBuffer(
	TargetBuffer: buffer,
	MemoryOffset: number,
	X0: number,
	Y0: number,
	Z0: number,
	X1: number,
	Y1: number,
	Z1: number,
	X2: number,
	Y2: number,
	Z2: number,
	PackedColor: number
): number
	-- Three 8-byte vertices and one 4-byte packed RGBA u32 color (28 bytes total, zero padding).
	buffer.writei16(TargetBuffer, MemoryOffset, X0)
	buffer.writei16(TargetBuffer, MemoryOffset + 2, Y0)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, Z0)

	buffer.writei16(TargetBuffer, MemoryOffset + 8, X1)
	buffer.writei16(TargetBuffer, MemoryOffset + 10, Y1)
	buffer.writef32(TargetBuffer, MemoryOffset + 12, Z1)

	buffer.writei16(TargetBuffer, MemoryOffset + 16, X2)
	buffer.writei16(TargetBuffer, MemoryOffset + 18, Y2)
	buffer.writef32(TargetBuffer, MemoryOffset + 20, Z2)

	buffer.writeu32(TargetBuffer, MemoryOffset + 24, PackedColor)

	return MemoryOffset + 28
end

function BufferHelper.ClearBuffers(TotalPixels: number, PixelBuffer: buffer, ZBuffer: buffer)
	const ByteLength = TotalPixels * 4 :: number
	if ClearTemplateSize ~= ByteLength then
		local NewPixelTemplate = buffer.create(ByteLength) :: buffer
		const PackedClearColor = bit32.bor(15, bit32.lshift(15, 8), bit32.lshift(20, 16), 0xFF000000) :: number
		for i = 0, ByteLength - 4, 4 do
			buffer.writeu32(NewPixelTemplate, i, PackedClearColor)
		end
		ClearPixelTemplate = NewPixelTemplate
		ClearTemplateSize = ByteLength
	end

	buffer.copy(PixelBuffer, 0, ClearPixelTemplate :: buffer, 0, ByteLength)
	buffer.fill(ZBuffer, 0, 0, ByteLength)
end

return BufferHelper
