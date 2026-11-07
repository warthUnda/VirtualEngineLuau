local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = 32

-- Caching --
local BufferWriteU8 = buffer.writeu8

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

	-- Vectors
	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V0.X)
	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V0.Y)
	MemoryOffset = BufferHelper.WriteF32(TargetBuffer, MemoryOffset, V0.Z)

	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V1.X)
	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V1.Y)
	MemoryOffset = BufferHelper.WriteF32(TargetBuffer, MemoryOffset, V1.Z)

	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V2.X)
	MemoryOffset = BufferHelper.WriteI16(TargetBuffer, MemoryOffset, V2.Y)
	MemoryOffset = BufferHelper.WriteF32(TargetBuffer, MemoryOffset, V2.Z)

	-- Color
	MemoryOffset = BufferHelper.WriteU16(TargetBuffer, MemoryOffset, R)
	MemoryOffset = BufferHelper.WriteU16(TargetBuffer, MemoryOffset, G)
	MemoryOffset = BufferHelper.WriteU16(TargetBuffer, MemoryOffset, B)

	-- Padding
	MemoryOffset = BufferHelper.WriteU16(TargetBuffer, MemoryOffset, 0)

	return MemoryOffset
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
	for i = 1, TotalPixels do
		buffer.writef32(ZBuffer, (i - 1) * 4, 1000.0)
		local Offset = (i - 1) * 4 :: number
		BufferWriteU8(PixelBuffer, Offset + 0, 15)
		BufferWriteU8(PixelBuffer, Offset + 1, 15)
		BufferWriteU8(PixelBuffer, Offset + 2, 20)
		BufferWriteU8(PixelBuffer, Offset + 3, 255)
	end
end

function BufferHelper.ConvertVector3ToBuffer(TargetBuffer: buffer, MemoryOffset: number, Value: Vector3)
	buffer.writef32(TargetBuffer, MemoryOffset, Value.X)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, Value.Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, Value.Z)
	return MemoryOffset + 12
end

return BufferHelper
