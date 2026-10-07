local BufferHelper = {}

-- Caching --
local BufferWriteU8 = buffer.writeu8

function BufferHelper.WriteF32(Buffer, Offset, Value)
	buffer.writef32(Buffer, Offset, Value)
	Offset += 4
	return Offset
end

function BufferHelper.WriteUINT16(Buffer, Offset, Value)
	buffer.writeu16(Buffer, Offset, Value)
	Offset += 2
	return Offset
end

function BufferHelper.ReadF32(Buffer, Offset)
	return buffer.readf32(Buffer, Offset)
end

function BufferHelper.ReadUNINT16(Buffer, Offset)
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
	MEMORYOFFSET: number,
	V0: Vector3,
	V1: Vector3,
	V2: Vector3,
	R: number,
	G: number,
	B: number
)
	-- v0, v1, v2, R, G, B, WIDTH, HEIGHT

	-- Vectors
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V0.X)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V0.Y)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V0.Z)

	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V1.X)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V1.Y)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V1.Z)

	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V2.X)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V2.Y)
	MEMORYOFFSET = BufferHelper.WriteF32(TargetBuffer, MEMORYOFFSET, V2.Z)

	-- Color
	MEMORYOFFSET = BufferHelper.WriteUINT16(TargetBuffer, MEMORYOFFSET, R)
	MEMORYOFFSET = BufferHelper.WriteUINT16(TargetBuffer, MEMORYOFFSET, G)
	MEMORYOFFSET = BufferHelper.WriteUINT16(TargetBuffer, MEMORYOFFSET, B)

	return MEMORYOFFSET
end

function BufferHelper.BufferPixelWrite(
	PixelBuffer: buffer,
	screenOffset: number,
	r: number,
	g: number,
	b: number,
	a: number
)
	BufferWriteU8(PixelBuffer, screenOffset + 0, r)
	BufferWriteU8(PixelBuffer, screenOffset + 1, g)
	BufferWriteU8(PixelBuffer, screenOffset + 2, b)
	BufferWriteU8(PixelBuffer, screenOffset + 3, a)
end

function BufferHelper.ClearBuffers(TOTAL_PIXELS: number, PixelBuffer: buffer, ZBuffer: buffer)
	for i = 1, TOTAL_PIXELS do
		buffer.writef32(ZBuffer, (i - 1) * 4, 1000.0)
		local offset = (i - 1) * 4 :: number
		BufferWriteU8(PixelBuffer, offset + 0, 15)
		BufferWriteU8(PixelBuffer, offset + 1, 15)
		BufferWriteU8(PixelBuffer, offset + 2, 20)
		BufferWriteU8(PixelBuffer, offset + 3, 255)
	end
end

return BufferHelper
