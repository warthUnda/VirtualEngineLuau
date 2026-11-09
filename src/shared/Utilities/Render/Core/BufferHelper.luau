--!native
--!optimize 2

local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = 32

-- Caching --
local BufferWriteU8 = buffer.writeu8
local ClearTemplateSize = 0 :: number
local ClearPixelTemplate: buffer? = nil
local ClearZTemplate: buffer? = nil

function BufferHelper.WriteF32(Buffer, Offset, Value)
	buffer.writef32(Buffer, Offset, Value)
	Offset += 4
	return Offset
end

function BufferHelper.WriteU16(Buffer, Offset, Value)
	buffer.writeu16(Buffer, Offset, Value)
	Offset += 2
	return Offset
end

function BufferHelper.WriteI16(Buffer, Offset, Value)
	buffer.writei16(Buffer, Offset, Value)
	Offset += 2
	return Offset
end

function BufferHelper.ReadF32(Buffer, Offset)
	return buffer.readf32(Buffer, Offset)
end

function BufferHelper.ReadU16(Buffer, Offset)
	return buffer.readu16(Buffer, Offset)
end

function BufferHelper.ReadBool(Buffer, Offset)
	return buffer.readu8(Buffer, Offset)
end

function BufferHelper.WriteBool(Buffer, Offset, Value)
	buffer.writeu8(Buffer, Offset, Value)
	Offset += 1
	return Offset
end

function BufferHelper.CreateRenderBuffer(
	TargetBuffer: buffer,
	MemoryOffset: number,
	V0: Vector3,
	V1: Vector3,
	V2: Vector3,
	R: number,
	G: number,
	B: number
)
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

function BufferHelper.Write3DVertices(TargetBuffer: buffer)
	local CubeData = {
		-1,
		-1,
		-1,
		1,
		-1,
		-1,
		1,
		1,
		-1,
		-1,
		1,
		-1,
		-1,
		-1,
		1,
		1,
		-1,
		1,
		1,
		1,
		1,
		-1,
		1,
		1,
	}

	for i = 1, #CubeData do
		buffer.writei8(TargetBuffer, i - 1, CubeData[i])
	end
end

function BufferHelper.BufferPixelWrite(
	PixelBuffer: buffer,
	ScreenOffset: number,
	R: number,
	G: number,
	B: number,
	A: number
)
	BufferWriteU8(PixelBuffer, ScreenOffset + 0, R)
	BufferWriteU8(PixelBuffer, ScreenOffset + 1, G)
	BufferWriteU8(PixelBuffer, ScreenOffset + 2, B)
	BufferWriteU8(PixelBuffer, ScreenOffset + 3, A)
end

function BufferHelper.ClearBuffers(TotalPixels: number, PixelBuffer: buffer, ZBuffer: buffer)
	local ByteLength = TotalPixels * 4 :: number
	if ClearTemplateSize ~= ByteLength then
		local NewPixelTemplate = buffer.create(ByteLength)
		local PackedClearColor = bit32.bor(15, bit32.lshift(15, 8), bit32.lshift(20, 16), 0xFF000000)
		for i = 0, ByteLength - 4, 4 do
			buffer.writeu32(NewPixelTemplate, i, PackedClearColor)
		end
		ClearPixelTemplate = NewPixelTemplate
		ClearTemplateSize = ByteLength
	end

	buffer.copy(PixelBuffer, 0, ClearPixelTemplate :: buffer, 0, ByteLength)
	buffer.fill(ZBuffer, 0, 0, ByteLength)
end

function BufferHelper.ConvertVector3ToBuffer(TargetBuffer: buffer, MemoryOffset: number, Value: Vector3)
	buffer.writef32(TargetBuffer, MemoryOffset, Value.X)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, Value.Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, Value.Z)
	return MemoryOffset + 12
end

return BufferHelper
