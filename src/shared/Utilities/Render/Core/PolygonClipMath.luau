--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const MathModule = require(script.Parent.MathModule)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const PLANE_NEAR = vector.create(0, 0, 1)
const PLANE_FAR = vector.create(0, 0, -1)

-- Tables --
local PolygonClipMath = {}

-- Functions --
-- ============================================================================
-- 1. FRUSTUM QUAD & TRIANGLE CLIPPING AND PROJECTION
-- ============================================================================

--[=[
	Clips a camera-space quad against frustum planes and projects vertices with UVs onto the screen.
	@param CameraVertices buffer -- Buffer containing camera-space vertices.
	@param V0ByteOffset number -- Byte offset for quad vertex 0.
	@param V1ByteOffset number -- Byte offset for quad vertex 1.
	@param V2ByteOffset number -- Byte offset for quad vertex 2.
	@param V3ByteOffset number -- Byte offset for quad vertex 3.
	@param ScaleU number -- Horizontal UV tile scale for the quad.
	@param ScaleV number -- Vertical UV tile scale for the quad.
	@param ProjectedVertices buffer -- Buffer to receive projected 20-byte vertices (X, Y, InvZ, U, V).
	@param ClipBufferA buffer -- Temporary scratch buffer for 20-byte polygon clipping.
	@param ClipBufferB buffer -- Secondary scratch buffer for 20-byte polygon clipping.
	@param FocalLength number -- Camera focal length.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@param HalfWidth number -- Half screen width in pixels.
	@param HalfHeight number -- Half screen height in pixels.
	@return number -- Total projected vertex count (0 if culled).
]=]
function PolygonClipMath.ClipAndProjectQuad(
	CameraVertices: buffer,
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	ScaleU: number,
	ScaleV: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	HalfWidth: number,
	HalfHeight: number
): number
	const QuadVertex0 = BufferHelper.ReadVec3(CameraVertices, V0ByteOffset)
	const QuadVertex1 = BufferHelper.ReadVec3(CameraVertices, V1ByteOffset)
	const QuadVertex2 = BufferHelper.ReadVec3(CameraVertices, V2ByteOffset)
	const QuadVertex3 = BufferHelper.ReadVec3(CameraVertices, V3ByteOffset)

	if
		MathModule.IsVertexInside(QuadVertex0, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(QuadVertex1, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(QuadVertex2, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(QuadVertex3, GuardBandX, GuardBandY)
	then
		MathModule.ProjectVertexUV(ProjectedVertices, 0, QuadVertex0, 0, ScaleV, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertexUV(ProjectedVertices, 20, QuadVertex1, 0, 0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertexUV(ProjectedVertices, 40, QuadVertex2, ScaleU, 0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertexUV(ProjectedVertices, 60, QuadVertex3, ScaleU, ScaleV, FocalLength, HalfWidth, HalfHeight)
		return 4
	end

	BufferHelper.WriteVec3(ClipBufferA, 0, QuadVertex0)
	buffer.writef32(ClipBufferA, 12, 0)
	buffer.writef32(ClipBufferA, 16, ScaleV)

	BufferHelper.WriteVec3(ClipBufferA, 20, QuadVertex1)
	buffer.writef32(ClipBufferA, 32, 0)
	buffer.writef32(ClipBufferA, 36, 0)

	BufferHelper.WriteVec3(ClipBufferA, 40, QuadVertex2)
	buffer.writef32(ClipBufferA, 52, ScaleU)
	buffer.writef32(ClipBufferA, 56, 0)

	BufferHelper.WriteVec3(ClipBufferA, 60, QuadVertex3)
	buffer.writef32(ClipBufferA, 72, ScaleU)
	buffer.writef32(ClipBufferA, 76, ScaleV)

	local VertexCount = MathModule.ClipPolygonUV(ClipBufferA, 4, ClipBufferB, PLANE_NEAR, -NEAR_CLIP)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, PLANE_FAR, FAR_CLIP)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferA, VertexCount, ClipBufferB, vector.create(1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, vector.create(-1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferA, VertexCount, ClipBufferB, vector.create(0, 1, GuardBandY), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, vector.create(0, -1, GuardBandY), 0)

	for i = 1, VertexCount do
		const Offset = (i - 1) * 20 :: number
		MathModule.ProjectVertexUV(
			ProjectedVertices,
			Offset,
			BufferHelper.ReadVec3(ClipBufferA, Offset),
			buffer.readf32(ClipBufferA, Offset + 12),
			buffer.readf32(ClipBufferA, Offset + 16),
			FocalLength,
			HalfWidth,
			HalfHeight
		)
	end

	return VertexCount
end

--[=[
	Clips a camera-space triangle face against frustum planes and projects vertices with UVs onto the screen.
	@param CameraVertices buffer -- Buffer containing camera-space vertices.
	@param V0ByteOffset number -- Byte offset for triangle vertex 0.
	@param V1ByteOffset number -- Byte offset for triangle vertex 1.
	@param V2ByteOffset number -- Byte offset for triangle vertex 2.
	@param ScaleU number -- Horizontal UV tile scale for the face.
	@param ScaleV number -- Vertical UV tile scale for the face.
	@param ProjectedVertices buffer -- Buffer to receive projected 20-byte vertices (X, Y, InvZ, U, V).
	@param ClipBufferA buffer -- Temporary scratch buffer for 20-byte polygon clipping.
	@param ClipBufferB buffer -- Secondary scratch buffer for 20-byte polygon clipping.
	@param FocalLength number -- Camera focal length.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@param HalfWidth number -- Half screen width in pixels.
	@param HalfHeight number -- Half screen height in pixels.
	@return number -- Total projected vertex count (0 if culled).
]=]
function PolygonClipMath.ClipAndProjectTriangleUV(
	CameraVertices: buffer,
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	ScaleU: number,
	ScaleV: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	HalfWidth: number,
	HalfHeight: number
): number
	const TriVertex0 = BufferHelper.ReadVec3(CameraVertices, V0ByteOffset)
	const TriVertex1 = BufferHelper.ReadVec3(CameraVertices, V1ByteOffset)
	const TriVertex2 = BufferHelper.ReadVec3(CameraVertices, V2ByteOffset)

	if
		MathModule.IsVertexInside(TriVertex0, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(TriVertex1, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(TriVertex2, GuardBandX, GuardBandY)
	then
		MathModule.ProjectVertexUV(ProjectedVertices, 0, TriVertex0, 0, ScaleV, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertexUV(ProjectedVertices, 20, TriVertex1, 0, 0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertexUV(ProjectedVertices, 40, TriVertex2, ScaleU, ScaleV, FocalLength, HalfWidth, HalfHeight)
		return 3
	end

	BufferHelper.WriteVec3(ClipBufferA, 0, TriVertex0)
	buffer.writef32(ClipBufferA, 12, 0)
	buffer.writef32(ClipBufferA, 16, ScaleV)

	BufferHelper.WriteVec3(ClipBufferA, 20, TriVertex1)
	buffer.writef32(ClipBufferA, 32, 0)
	buffer.writef32(ClipBufferA, 36, 0)

	BufferHelper.WriteVec3(ClipBufferA, 40, TriVertex2)
	buffer.writef32(ClipBufferA, 52, ScaleU)
	buffer.writef32(ClipBufferA, 56, ScaleV)

	local VertexCount = MathModule.ClipPolygonUV(ClipBufferA, 3, ClipBufferB, PLANE_NEAR, -NEAR_CLIP)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, PLANE_FAR, FAR_CLIP)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferA, VertexCount, ClipBufferB, vector.create(1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, vector.create(-1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferA, VertexCount, ClipBufferB, vector.create(0, 1, GuardBandY), 0)
	VertexCount = MathModule.ClipPolygonUV(ClipBufferB, VertexCount, ClipBufferA, vector.create(0, -1, GuardBandY), 0)

	for i = 1, VertexCount do
		const Offset = (i - 1) * 20 :: number
		MathModule.ProjectVertexUV(
			ProjectedVertices,
			Offset,
			BufferHelper.ReadVec3(ClipBufferA, Offset),
			buffer.readf32(ClipBufferA, Offset + 12),
			buffer.readf32(ClipBufferA, Offset + 16),
			FocalLength,
			HalfWidth,
			HalfHeight
		)
	end

	return VertexCount
end

return PolygonClipMath
