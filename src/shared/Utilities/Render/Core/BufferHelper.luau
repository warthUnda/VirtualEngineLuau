--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const CLEAR_R = SystemsConfigs.ClearColorR :: number
const CLEAR_G = SystemsConfigs.ClearColorG :: number
const CLEAR_B = SystemsConfigs.ClearColorB :: number
const PACKED_CLEAR_COLOR = bit32.bor(CLEAR_R, bit32.lshift(CLEAR_G, 8), bit32.lshift(CLEAR_B, 16), 0xFF000000) :: number

-- Buffers
local ClearTemplateSize = 0 :: number
local ClearPixelTemplate: buffer? = nil

local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = 28 :: number

function BufferHelper.ReadVec3(TargetBuffer: buffer, Offset: number): vector
	return vector.create(
		buffer.readf32(TargetBuffer, Offset),
		buffer.readf32(TargetBuffer, Offset + 4),
		buffer.readf32(TargetBuffer, Offset + 8)
	)
end

function BufferHelper.WriteVec3(TargetBuffer: buffer, Offset: number, Value: vector)
	buffer.writef32(TargetBuffer, Offset, Value.x)
	buffer.writef32(TargetBuffer, Offset + 4, Value.y)
	buffer.writef32(TargetBuffer, Offset + 8, Value.z)
end

local function EnsureClearTemplate(ByteLength: number): buffer
	if ClearTemplateSize < ByteLength then
		local NewPixelTemplate = buffer.create(ByteLength) :: buffer
		for i = 0, ByteLength - 4, 4 do
			buffer.writeu32(NewPixelTemplate, i, PACKED_CLEAR_COLOR)
		end
		ClearPixelTemplate = NewPixelTemplate
		ClearTemplateSize = ByteLength
	end

	return ClearPixelTemplate :: buffer
end

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
	const Template = EnsureClearTemplate(ByteLength)

	buffer.copy(PixelBuffer, 0, Template, 0, ByteLength)
	buffer.fill(ZBuffer, 0, 0, ByteLength)
end

function BufferHelper.ClearDirtyRows(
	Width: number,
	MinY: number,
	MaxY: number,
	TotalPixels: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
)
	if MinY > MaxY then
		return
	end

	const Template = EnsureClearTemplate(TotalPixels * 4)
	const RowStride = Width * 4 :: number
	const StartOffset = MinY * RowStride :: number
	const DirtyByteLength = (MaxY - MinY + 1) * RowStride :: number

	buffer.copy(PixelBuffer, StartOffset, Template, 0, DirtyByteLength)
	buffer.fill(ZBuffer, StartOffset, 0, DirtyByteLength)
end

return BufferHelper
