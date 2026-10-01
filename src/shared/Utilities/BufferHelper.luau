local BufferHelper = {}

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

return BufferHelper
