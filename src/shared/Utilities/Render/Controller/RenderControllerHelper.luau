--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const HALF_WIDTH = WIDTH * 0.5 :: number
const HALF_HEIGHT = HEIGHT * 0.5 :: number
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const WORKER_BUFFER_CAPACITY = TOTAL_PIXELS * WORKER_BUFFER_MULTIPLIER :: number
const RENDER_BUFFER_LAYOUT_SIZE = BufferHelper.RenderBufferLayoutSize :: number
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number

local RenderControllerHelper = {}

-- ============================================================================
-- 1. DIRECTION READING, COLOR SHADING & FACE QUAD SUBMISSION
-- ============================================================================

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
	Clips a quad face, tessellates it into triangles, and dispatches them to parallel worker queues based on lowest estimated raster work.
	@param ScreenVertices buffer -- Camera-space box vertex buffer.
	@param ProjectedVertices buffer -- Scratch buffer for projected 2D coordinates.
	@param ClipBufferA buffer -- First polygon clipping scratch buffer.
	@param ClipBufferB buffer -- Second polygon clipping scratch buffer.
	@param WorkerScores { number } -- Workload score tracking per worker.
	@param WorkerOffsets { number } -- Buffer write offsets per worker.
	@param BufferTable { buffer } -- Array of worker render command buffers.
	@param V0ByteOffset number -- Byte offset for vertex 0.
	@param V1ByteOffset number -- Byte offset for vertex 1.
	@param V2ByteOffset number -- Byte offset for vertex 2.
	@param V3ByteOffset number -- Byte offset for vertex 3.
	@param ScaleU number -- Horizontal UV tile scale for the face quad.
	@param ScaleV number -- Vertical UV tile scale for the face quad.
	@param PackedColor number -- Shaded 32-bit RGBA color.
	@param TextureId number -- TextureTable numeric ID.
	@param FocalLength number -- Camera focal length.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
]=]
function RenderControllerHelper.SubmitFace(
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	WorkerScores: { number },
	WorkerOffsets: { number },
	BufferTable: { buffer },
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
)
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
		return
	end

	const Vertex0X = buffer.readf32(ProjectedVertices, 0) :: number
	const Vertex0Y = buffer.readf32(ProjectedVertices, 4) :: number
	const InverseZ0 = buffer.readf32(ProjectedVertices, 8) :: number
	const TexCoordU0 = buffer.readf32(ProjectedVertices, 12) :: number
	const TexCoordV0 = buffer.readf32(ProjectedVertices, 16) :: number

	for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
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

		const SpanHeightY = MaxY - MinY + 1 :: number
		const TriangleCost = SignedDoubleTriangleArea * 0.5 + SpanHeightY * 6 + 24 :: number

		local SmallestScore = WorkerScores[1] :: number
		local BestWorkerIdx = 1 :: number

		for WorkerIdx = 2, ACTOR_COUNT do
			const CandidateScore = WorkerScores[WorkerIdx] :: number
			if CandidateScore < SmallestScore then
				SmallestScore = CandidateScore
				BestWorkerIdx = WorkerIdx
			end
		end

		const RenderBufferOffset = WorkerOffsets[BestWorkerIdx] :: number
		if RenderBufferOffset + RENDER_BUFFER_LAYOUT_SIZE > WORKER_BUFFER_CAPACITY then
			continue
		end

		WorkerScores[BestWorkerIdx] = SmallestScore + TriangleCost
		WorkerOffsets[BestWorkerIdx] = RenderBufferOffset + RENDER_BUFFER_LAYOUT_SIZE

		const RenderBuffer = BufferTable[BestWorkerIdx] :: buffer
		const InverseTriangleArea = 1 / SignedDoubleTriangleArea :: number

		const ScaledInverseZ0 = InverseZ0 * InverseTriangleArea :: number
		const ScaledInverseZ1 = InverseZ1 * InverseTriangleArea :: number
		const ScaledInverseZ2 = InverseZ2 * InverseTriangleArea :: number

		buffer.writei16(RenderBuffer, RenderBufferOffset, Vertex0X)
		buffer.writei16(RenderBuffer, RenderBufferOffset + 2, Vertex0Y)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 4, ScaledInverseZ0)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 8, ScaledInverseZ0 * TexCoordU0)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 12, ScaledInverseZ0 * TexCoordV0)

		buffer.writei16(RenderBuffer, RenderBufferOffset + 16, Vertex1X)
		buffer.writei16(RenderBuffer, RenderBufferOffset + 18, Vertex1Y)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 20, ScaledInverseZ1)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 24, ScaledInverseZ1 * TexCoordU1)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 28, ScaledInverseZ1 * TexCoordV1)

		buffer.writei16(RenderBuffer, RenderBufferOffset + 32, Vertex2X)
		buffer.writei16(RenderBuffer, RenderBufferOffset + 34, Vertex2Y)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 36, ScaledInverseZ2)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 40, ScaledInverseZ2 * TexCoordU2)
		buffer.writef32(RenderBuffer, RenderBufferOffset + 44, ScaledInverseZ2 * TexCoordV2)

		buffer.writeu32(RenderBuffer, RenderBufferOffset + 48, PackedColor)
		buffer.writeu32(RenderBuffer, RenderBufferOffset + 52, TextureId)
	end
end

return RenderControllerHelper
