--!native
--!optimize 2

-- Buffers
local ClearTemplateSize = 0 :: number
local ClearPixelTemplate: buffer? = nil

local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = 32 :: number

function BufferHelper.CreateRenderBuffer(
	TargetBuffer: buffer,
	MemoryOffset: number,
	V0: Vector3,
	V1: Vector3,
	V2: Vector3,
	R: number,
	G: number,
	B: number
): number
	-- Three 8-byte vertices, three 2-byte color channels, and 2 bytes of padding.
	buffer.writei16(TargetBuffer, MemoryOffset, V0.X)
	buffer.writei16(TargetBuffer, MemoryOffset + 2, V0.Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, V0.Z)

	buffer.writei16(TargetBuffer, MemoryOffset + 8, V1.X)
	buffer.writei16(TargetBuffer, MemoryOffset + 10, V1.Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 12, V1.Z)

	buffer.writei16(TargetBuffer, MemoryOffset + 16, V2.X)
	buffer.writei16(TargetBuffer, MemoryOffset + 18, V2.Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 20, V2.Z)

	buffer.writeu16(TargetBuffer, MemoryOffset + 24, R)
	buffer.writeu16(TargetBuffer, MemoryOffset + 26, G)
	buffer.writeu16(TargetBuffer, MemoryOffset + 28, B)
	buffer.writeu16(TargetBuffer, MemoryOffset + 30, 0)

	return MemoryOffset + 32
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
