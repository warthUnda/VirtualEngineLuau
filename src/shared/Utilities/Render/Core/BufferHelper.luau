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
