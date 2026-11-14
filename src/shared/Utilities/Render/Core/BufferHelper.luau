--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const CLEAR_R = SystemsConfigs.ClearColorR :: number
const CLEAR_G = SystemsConfigs.ClearColorG :: number
const CLEAR_B = SystemsConfigs.ClearColorB :: number
const RENDER_BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number
const PACKED_CLEAR_COLOR = bit32.bor(CLEAR_R, bit32.lshift(CLEAR_G, 8), bit32.lshift(CLEAR_B, 16), 0xFF000000) :: number

-- Buffers
local ClearTemplateSize = 0 :: number
local ClearPixelTemplate: buffer? = nil

local BufferHelper = {}

BufferHelper.RenderBufferLayoutSize = RENDER_BUFFER_LAYOUT_SIZE :: number

-- ============================================================================
-- 1. BUFFER READ / WRITE & FRAME CLEAR HELPERS
-- ============================================================================

--[=[
	Reads 3 consecutive f32 numbers from a buffer into a Luau SIMD vector.
	@param TargetBuffer buffer -- Source memory buffer.
	@param Offset number -- Byte offset to read from.
	@return vector -- SIMD vector containing (X, Y, Z).
]=]
function BufferHelper.ReadVec3(TargetBuffer: buffer, Offset: number): vector
	return vector.create(
		buffer.readf32(TargetBuffer, Offset),
		buffer.readf32(TargetBuffer, Offset + 4),
		buffer.readf32(TargetBuffer, Offset + 8)
	)
end

--[=[
	Writes a Luau SIMD vector's (X, Y, Z) components as 3 consecutive f32 floats into a buffer.
	@param TargetBuffer buffer -- Target destination buffer.
	@param Offset number -- Byte offset to write at.
	@param Value vector -- Source SIMD vector.
]=]
function BufferHelper.WriteVec3(TargetBuffer: buffer, Offset: number, Value: vector)
	buffer.writef32(TargetBuffer, Offset, Value.x)
	buffer.writef32(TargetBuffer, Offset + 4, Value.y)
	buffer.writef32(TargetBuffer, Offset + 8, Value.z)
end

--[=[
	Ensures the pre-filled background clear pixel template buffer is allocated and sized.
	@param ByteLength number -- Total required byte capacity.
	@return buffer -- Pre-filled template buffer.
]=]
function BufferHelper.EnsureClearTemplate(ByteLength: number): buffer
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

--[=[
	Packs 3 projected textured triangle vertices and a 32-bit packed color into the worker render queue buffer.
	@param TargetBuffer buffer -- Destination render command buffer.
	@param MemoryOffset number -- Current byte offset in render command buffer.
	@param Vertex0X number -- Screen vertex 0 X coordinate.
	@param Vertex0Y number -- Screen vertex 0 Y coordinate.
	@param ScaledInverseZ0 number -- Pre-scaled 1/Z depth for vertex 0.
	@param ScaledUOverZ0 number -- Pre-scaled U/Z coordinate for vertex 0.
	@param ScaledVOverZ0 number -- Pre-scaled V/Z coordinate for vertex 0.
	@param Vertex1X number -- Screen vertex 1 X coordinate.
	@param Vertex1Y number -- Screen vertex 1 Y coordinate.
	@param ScaledInverseZ1 number -- Pre-scaled 1/Z depth for vertex 1.
	@param ScaledUOverZ1 number -- Pre-scaled U/Z coordinate for vertex 1.
	@param ScaledVOverZ1 number -- Pre-scaled V/Z coordinate for vertex 1.
	@param Vertex2X number -- Screen vertex 2 X coordinate.
	@param Vertex2Y number -- Screen vertex 2 Y coordinate.
	@param ScaledInverseZ2 number -- Pre-scaled 1/Z depth for vertex 2.
	@param ScaledUOverZ2 number -- Pre-scaled U/Z coordinate for vertex 2.
	@param ScaledVOverZ2 number -- Pre-scaled V/Z coordinate for vertex 2.
	@param PackedColor number -- Packed 32-bit RGBA color.
	@return number -- Next byte offset in render command buffer.
]=]
function BufferHelper.CreateRenderBuffer(
	TargetBuffer: buffer,
	MemoryOffset: number,
	Vertex0X: number,
	Vertex0Y: number,
	ScaledInverseZ0: number,
	ScaledUOverZ0: number,
	ScaledVOverZ0: number,
	Vertex1X: number,
	Vertex1Y: number,
	ScaledInverseZ1: number,
	ScaledUOverZ1: number,
	ScaledVOverZ1: number,
	Vertex2X: number,
	Vertex2Y: number,
	ScaledInverseZ2: number,
	ScaledUOverZ2: number,
	ScaledVOverZ2: number,
	PackedColor: number
): number
	-- Three 16-byte vertices (X, Y, InvZ, U/Z, V/Z) and one 4-byte packed RGBA u32 color (52 bytes total).
	buffer.writei16(TargetBuffer, MemoryOffset, Vertex0X)
	buffer.writei16(TargetBuffer, MemoryOffset + 2, Vertex0Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 4, ScaledInverseZ0)
	buffer.writef32(TargetBuffer, MemoryOffset + 8, ScaledUOverZ0)
	buffer.writef32(TargetBuffer, MemoryOffset + 12, ScaledVOverZ0)

	buffer.writei16(TargetBuffer, MemoryOffset + 16, Vertex1X)
	buffer.writei16(TargetBuffer, MemoryOffset + 18, Vertex1Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 20, ScaledInverseZ1)
	buffer.writef32(TargetBuffer, MemoryOffset + 24, ScaledUOverZ1)
	buffer.writef32(TargetBuffer, MemoryOffset + 28, ScaledVOverZ1)

	buffer.writei16(TargetBuffer, MemoryOffset + 32, Vertex2X)
	buffer.writei16(TargetBuffer, MemoryOffset + 34, Vertex2Y)
	buffer.writef32(TargetBuffer, MemoryOffset + 36, ScaledInverseZ2)
	buffer.writef32(TargetBuffer, MemoryOffset + 40, ScaledUOverZ2)
	buffer.writef32(TargetBuffer, MemoryOffset + 44, ScaledVOverZ2)

	buffer.writeu32(TargetBuffer, MemoryOffset + 48, PackedColor)

	return MemoryOffset + RENDER_BUFFER_LAYOUT_SIZE
end

--[=[
	Clears the entire pixel and Z buffer to the default background state.
	@param TotalPixels number -- Total screen pixel count (Width * Height).
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit depth buffer.
]=]
function BufferHelper.ClearBuffers(TotalPixels: number, PixelBuffer: buffer, ZBuffer: buffer)
	const ByteLength = TotalPixels * 4 :: number
	const Template = BufferHelper.EnsureClearTemplate(ByteLength)

	buffer.copy(PixelBuffer, 0, Template, 0, ByteLength)
	buffer.fill(ZBuffer, 0, 0, ByteLength)
end

--[=[
	Clears only the scanline rows marked dirty between MinY and MaxY.
	@param Width number -- Screen width in pixels.
	@param MinY number -- Minimum modified scanline Y index.
	@param MaxY number -- Maximum modified scanline Y index.
	@param TotalPixels number -- Total screen pixel count.
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit depth buffer.
]=]
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

	const Template = BufferHelper.EnsureClearTemplate(TotalPixels * 4)
	const RowStride = Width * 4 :: number
	const StartOffset = MinY * RowStride :: number
	const DirtyByteLength = (MaxY - MinY + 1) * RowStride :: number

	buffer.copy(PixelBuffer, StartOffset, Template, 0, DirtyByteLength)
	buffer.fill(ZBuffer, StartOffset, 0, DirtyByteLength)
end

return BufferHelper
