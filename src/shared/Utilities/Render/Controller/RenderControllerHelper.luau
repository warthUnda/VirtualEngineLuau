--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)
const WorkerPartitionHelper = require(script.Parent.WorkerPartitionHelper)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const HALF_WIDTH = WIDTH * 0.5 :: number
const HALF_HEIGHT = HEIGHT * 0.5 :: number
const RENDER_BUFFER_LAYOUT_SIZE = BufferHelper.RenderBufferLayoutSize :: number
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number
const FRAME_PACING_EPSILON = 1e-5 :: number

-- Tables --
local RenderControllerHelper = {}

-- ============================================================================
-- 1. FRAME PACING, DIRECTION READING, COLOR SHADING & FACE QUAD STAGING
-- ============================================================================

--[=[
	Advances the render frame-pacing accumulator and determines whether a new frame should be dispatched.
	@param Accumulator number -- Current accumulated frame time in seconds.
	@param DeltaTime number -- Elapsed tick delta time in seconds.
	@param FrameInterval number -- Target seconds per rendered frame (<= 0 for uncapped).
	@param IsFrameBlocked boolean -- True when a previous worker frame is still in flight.
	@return boolean -- True when a render pass should execute this tick.
	@return number -- Updated accumulator value in seconds.
]=]
function RenderControllerHelper.StepFrameAccumulator(
	Accumulator: number,
	DeltaTime: number,
	FrameInterval: number,
	IsFrameBlocked: boolean
): (boolean, number)
	if FrameInterval <= 0 then
		return not IsFrameBlocked, 0
	end

	const NextAccumulator = Accumulator + math.max(0, DeltaTime) :: number
	if NextAccumulator < FrameInterval - FRAME_PACING_EPSILON then
		return false, NextAccumulator
	end
	if IsFrameBlocked then
		return false, FrameInterval
	end

	const Remainder = if NextAccumulator >= FrameInterval * 2
		then 0
		else math.max(0, NextAccumulator - FrameInterval) :: number
	return true, Remainder
end

--[=[
	Reads a 3-component float direction vector from the directions buffer into a SIMD vector.
	@param DirectionsBuffer buffer -- Basis directions buffer.
	@param Offset number -- Byte offset to read from.
	@return vector -- Direction SIMD vector.
]=]
function RenderControllerHelper.ReadDirectionVec(DirectionsBuffer: buffer, Offset: number): vector
	return vector.create(
		buffer.readf32(DirectionsBuffer, Offset),
		buffer.readf32(DirectionsBuffer, Offset + 4),
		buffer.readf32(DirectionsBuffer, Offset + 8)
	)
end

--[=[
	Packs shaded RGB channels and illumination into a 32-bit integer color.
	@param RedChannel number -- Base red color channel (0-255).
	@param GreenChannel number -- Base green color channel (0-255).
	@param BlueChannel number -- Base blue color channel (0-255).
	@param Illumination number -- Illumination scalar factor.
	@return number -- Packed 32-bit RGBA color.
]=]
function RenderControllerHelper.PackShadedColor(
	RedChannel: number,
	GreenChannel: number,
	BlueChannel: number,
	Illumination: number
): number
	return bit32.bor(
		math.floor(RedChannel * Illumination),
		bit32.lshift(math.floor(GreenChannel * Illumination), 8),
		bit32.lshift(math.floor(BlueChannel * Illumination), 16),
		0xFF000000
	)
end

--[=[
	Clips a face polygon, tessellates it into screen-space triangles, stages each 56-byte triangle once,
	and records O(1) scanline row work into RowWorkDiff for dynamic worker band partitioning.
	@param ScreenVertices buffer -- Camera-space vertex buffer.
	@param ProjectedVertices buffer -- Scratch buffer for projected 2D coordinates.
	@param ClipBufferA buffer -- First polygon clipping scratch buffer.
	@param ClipBufferB buffer -- Second polygon clipping scratch buffer.
	@param StagedTriangles buffer -- Contiguous staged 56-byte triangle command buffer.
	@param StagedBounds buffer -- Contiguous 4-byte (u16 MinY, u16 MaxY) bounds buffer.
	@param StagedTriangleCount number -- Current staged triangle count.
	@param MaxStagedTriangles number -- Maximum triangle capacity in StagedTriangles.
	@param RowWorkDiff buffer -- Scanline difference buffer of size (Height + 1) * 4.
	@param V0ByteOffset number -- Byte offset for vertex 0.
	@param V1ByteOffset number -- Byte offset for vertex 1.
	@param V2ByteOffset number -- Byte offset for vertex 2.
	@param V3ByteOffset number -- Byte offset for vertex 3 (-1 for triangle face).
	@param ScaleU number -- Horizontal UV tile scale for the face.
	@param ScaleV number -- Vertical UV tile scale for the face.
	@param PackedColor number -- Shaded 32-bit RGBA color.
	@param TextureId number -- TextureTable numeric ID.
	@param FocalLength number -- Camera focal length.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@return number -- Updated staged triangle count.
]=]
function RenderControllerHelper.SubmitFace(
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	StagedTriangles: buffer,
	StagedBounds: buffer,
	StagedTriangleCount: number,
	MaxStagedTriangles: number,
	RowWorkDiff: buffer,
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	ScaleU: number,
	ScaleV: number,
	PackedColor: number,
	TextureId: number,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number
): number
	if StagedTriangleCount >= MaxStagedTriangles then
		return StagedTriangleCount
	end

	const ClippedVertexCount = if V3ByteOffset >= 0
		then RenderMath.ClipAndProjectQuad(
			ScreenVertices,
			V0ByteOffset,
			V1ByteOffset,
			V2ByteOffset,
			V3ByteOffset,
			ScaleU,
			ScaleV,
			ProjectedVertices,
			ClipBufferA,
			ClipBufferB,
			FocalLength,
			GuardBandX,
			GuardBandY,
			HALF_WIDTH,
			HALF_HEIGHT
		)
		else RenderMath.ClipAndProjectTriangleUV(
			ScreenVertices,
			V0ByteOffset,
			V1ByteOffset,
			V2ByteOffset,
			ScaleU,
			ScaleV,
			ProjectedVertices,
			ClipBufferA,
			ClipBufferB,
			FocalLength,
			GuardBandX,
			GuardBandY,
			HALF_WIDTH,
			HALF_HEIGHT
		) :: number

	if ClippedVertexCount < 3 then
		return StagedTriangleCount
	end

	local NextTriangleCount = StagedTriangleCount :: number

	const Vertex0X = buffer.readf32(ProjectedVertices, 0) :: number
	const Vertex0Y = buffer.readf32(ProjectedVertices, 4) :: number
	const InverseZ0 = buffer.readf32(ProjectedVertices, 8) :: number
	const TexCoordU0 = buffer.readf32(ProjectedVertices, 12) :: number
	const TexCoordV0 = buffer.readf32(ProjectedVertices, 16) :: number

	for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
		if NextTriangleCount >= MaxStagedTriangles then
			break
		end

		const V1Offset = (ClippedTriangleIndex - 1) * 20 :: number
		const V2Offset = V1Offset + 20 :: number

		const Vertex1X = buffer.readf32(ProjectedVertices, V1Offset) :: number
		const Vertex1Y = buffer.readf32(ProjectedVertices, V1Offset + 4) :: number
		const InverseZ1 = buffer.readf32(ProjectedVertices, V1Offset + 8) :: number
		const TexCoordU1 = buffer.readf32(ProjectedVertices, V1Offset + 12) :: number
		const TexCoordV1 = buffer.readf32(ProjectedVertices, V1Offset + 16) :: number

		const Vertex2X = buffer.readf32(ProjectedVertices, V2Offset) :: number
		const Vertex2Y = buffer.readf32(ProjectedVertices, V2Offset + 4) :: number
		const InverseZ2 = buffer.readf32(ProjectedVertices, V2Offset + 8) :: number
		const TexCoordU2 = buffer.readf32(ProjectedVertices, V2Offset + 12) :: number
		const TexCoordV2 = buffer.readf32(ProjectedVertices, V2Offset + 16) :: number

		const SignedDoubleTriangleArea = (Vertex2X - Vertex0X) * (Vertex1Y - Vertex0Y)
			- (Vertex2Y - Vertex0Y) * (Vertex1X - Vertex0X) :: number
		if SignedDoubleTriangleArea <= MIN_TRIANGLE_AREA then
			continue
		end

		const MinX = math.max(0, math.min(Vertex0X, Vertex1X, Vertex2X)) :: number
		const MaxX = math.min(WIDTH - 1, math.max(Vertex0X, Vertex1X, Vertex2X)) :: number
		const MinY = math.max(0, math.min(Vertex0Y, Vertex1Y, Vertex2Y)) :: number
		const MaxY = math.min(HEIGHT - 1, math.max(Vertex0Y, Vertex1Y, Vertex2Y)) :: number

		if MinX > MaxX or MinY > MaxY then
			continue
		end

		const InverseTriangleArea = 1 / SignedDoubleTriangleArea :: number

		const ScaledInverseZ0 = InverseZ0 * InverseTriangleArea :: number
		const ScaledInverseZ1 = InverseZ1 * InverseTriangleArea :: number
		const ScaledInverseZ2 = InverseZ2 * InverseTriangleArea :: number

		const ScaledU0 = ScaledInverseZ0 * TexCoordU0 :: number
		const ScaledV0 = ScaledInverseZ0 * TexCoordV0 :: number
		const ScaledU1 = ScaledInverseZ1 * TexCoordU1 :: number
		const ScaledV1 = ScaledInverseZ1 * TexCoordV1 :: number
		const ScaledU2 = ScaledInverseZ2 * TexCoordU2 :: number
		const ScaledV2 = ScaledInverseZ2 * TexCoordV2 :: number

		const StageOffset = NextTriangleCount * RENDER_BUFFER_LAYOUT_SIZE :: number
		buffer.writei16(StagedTriangles, StageOffset, Vertex0X)
		buffer.writei16(StagedTriangles, StageOffset + 2, Vertex0Y)
		buffer.writef32(StagedTriangles, StageOffset + 4, ScaledInverseZ0)
		buffer.writef32(StagedTriangles, StageOffset + 8, ScaledU0)
		buffer.writef32(StagedTriangles, StageOffset + 12, ScaledV0)

		buffer.writei16(StagedTriangles, StageOffset + 16, Vertex1X)
		buffer.writei16(StagedTriangles, StageOffset + 18, Vertex1Y)
		buffer.writef32(StagedTriangles, StageOffset + 20, ScaledInverseZ1)
		buffer.writef32(StagedTriangles, StageOffset + 24, ScaledU1)
		buffer.writef32(StagedTriangles, StageOffset + 28, ScaledV1)

		buffer.writei16(StagedTriangles, StageOffset + 32, Vertex2X)
		buffer.writei16(StagedTriangles, StageOffset + 34, Vertex2Y)
		buffer.writef32(StagedTriangles, StageOffset + 36, ScaledInverseZ2)
		buffer.writef32(StagedTriangles, StageOffset + 40, ScaledU2)
		buffer.writef32(StagedTriangles, StageOffset + 44, ScaledV2)

		buffer.writeu32(StagedTriangles, StageOffset + 48, PackedColor)
		buffer.writeu32(StagedTriangles, StageOffset + 52, TextureId)

		const BoundsOffset = NextTriangleCount * 4 :: number
		buffer.writeu16(StagedBounds, BoundsOffset, MinY)
		buffer.writeu16(StagedBounds, BoundsOffset + 2, MaxY)

		WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, MinX, MaxX, MinY, MaxY, TextureId)
		NextTriangleCount += 1
	end

	return NextTriangleCount
end

--[=[
	Decodes synced TextureTable entries received from the server into 64x64 buffers and invokes OnTextureUpdated when cached buffers change.
	@param Entries any -- Array of TextureTable.TextureEntry records from TextureSyncEvent.
	@param OnTextureUpdated ({ [number]: buffer }) -> () -- Callback invoked with updated cached texture buffers.
]=]
function RenderControllerHelper.ApplySyncedTextures(Entries: any, OnTextureUpdated: ({ [number]: buffer }) -> ())
	if typeof(Entries) ~= "table" then
		return
	end

	for _, Entry: any in ipairs(Entries :: { TextureTable.TextureEntry }) do
		if typeof(Entry) ~= "table" then
			continue
		end

		const TextureId = Entry.Id :: number?
		const RawUrl = Entry.Url :: string?
		const TextureName = Entry.Name :: string?
		if typeof(TextureId) ~= "number" or typeof(RawUrl) ~= "string" then
			continue
		end

		task.spawn(function()
			const _Buf: buffer?, Updated: boolean = TextureTable.RegisterEntryWithId(
				TextureId,
				RawUrl,
				if typeof(TextureName) == "string" then TextureName else nil
			)
			if Updated then
				OnTextureUpdated(TextureTable.GetAllCachedBuffers())
			end
		end)
	end
end

return RenderControllerHelper
