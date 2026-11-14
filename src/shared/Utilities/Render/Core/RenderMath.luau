--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const MathModule = require(script.Parent.MathModule)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const GUARD_BAND_SCALE = SystemsConfigs.GuardBandScale :: number
const BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number

const PLANE_NEAR = vector.create(0, 0, 1)
const PLANE_FAR = vector.create(0, 0, -1)

local RenderMath = {}

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

--[=[
	Transforms an arbitrary shape's unit local vertices from VerticeFile into camera space and computes local camera/sun vectors for face culling and lighting.
	@param PositionBuffer buffer -- Entity position component buffer.
	@param DirectionsBuffer buffer -- Entity basis directions buffer.
	@param SizeBuffer buffer -- Entity size component buffer.
	@param ComponentOffset number -- Byte offset in position/size buffers.
	@param DirectionOffset number -- Byte offset in directions buffer.
	@param LocalVertices { vector } -- Unit local-space vertices from VerticeFile.
	@param VertexCount number -- Number of vertices in LocalVertices.
	@param CameraVertices buffer -- Output buffer for transformed camera-space vertices (12 bytes per vertex).
	@param CamPos vector -- Camera world position.
	@param CamRight vector -- Camera RightVector.
	@param CamUp vector -- Camera UpVector.
	@param CamLook vector -- Camera LookVector.
	@param SunVec vector -- Normalized world-space sun direction vector.
	@return (boolean, vector, vector, vector) -- (IsVisible, LocalCameraPos, HalfSize, LocalSun).
]=]
function RenderMath.TransformShapeCameraVertices(
	PositionBuffer: buffer,
	DirectionsBuffer: buffer,
	SizeBuffer: buffer,
	ComponentOffset: number,
	DirectionOffset: number,
	LocalVertices: { vector },
	VertexCount: number,
	CameraVertices: buffer,
	CamPos: vector,
	CamRight: vector,
	CamUp: vector,
	CamLook: vector,
	SunVec: vector,
	GuardBandX: number?,
	GuardBandY: number?
): (boolean, vector, vector, vector)
	const PartPosition = BufferHelper.ReadVec3(PositionBuffer, ComponentOffset)
	const HalfSize = BufferHelper.ReadVec3(SizeBuffer, ComponentOffset) * 0.5
	const HalfSizeX: number, HalfSizeY: number, HalfSizeZ: number = HalfSize.x, HalfSize.y, HalfSize.z

	const RelativePosition = PartPosition - CamPos
	const CameraSpaceCenterZ = vector.dot(RelativePosition, CamLook) :: number

	const LookAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset)
	const UpAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 12)
	const RightAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 24)

	const WorldRightAxis = RightAxis * HalfSizeX
	const WorldUpAxis = UpAxis * HalfSizeY
	const WorldLookAxis = LookAxis * HalfSizeZ

	const RightAxisCameraZ = vector.dot(WorldRightAxis, CamLook) :: number
	const UpAxisCameraZ = vector.dot(WorldUpAxis, CamLook) :: number
	const LookAxisCameraZ = vector.dot(WorldLookAxis, CamLook) :: number

	const CameraSpaceExtentZ =
		math.abs(RightAxisCameraZ) + math.abs(UpAxisCameraZ) + math.abs(LookAxisCameraZ) :: number
	if CameraSpaceCenterZ + CameraSpaceExtentZ < NEAR_CLIP or CameraSpaceCenterZ - CameraSpaceExtentZ > FAR_CLIP then
		return false, vector.zero, vector.zero, vector.zero
	end

	const CameraSpaceCenter = vector.create(
		vector.dot(RelativePosition, CamRight),
		vector.dot(RelativePosition, CamUp),
		CameraSpaceCenterZ
	)
	const CameraSpaceRightAxis = vector.create(
		vector.dot(WorldRightAxis, CamRight),
		vector.dot(WorldRightAxis, CamUp),
		RightAxisCameraZ
	)
	const CameraSpaceUpAxis = vector.create(
		vector.dot(WorldUpAxis, CamRight),
		vector.dot(WorldUpAxis, CamUp),
		UpAxisCameraZ
	)
	const CameraSpaceLookAxis = vector.create(
		vector.dot(WorldLookAxis, CamRight),
		vector.dot(WorldLookAxis, CamUp),
		LookAxisCameraZ
	)

	if GuardBandX and GuardBandY then
		const MaxDepth = math.max(CameraSpaceCenterZ + CameraSpaceExtentZ, NEAR_CLIP) :: number
		const ExtentX =
			math.abs(CameraSpaceRightAxis.X) + math.abs(CameraSpaceUpAxis.X) + math.abs(CameraSpaceLookAxis.X) :: number
		const HalfFrustumX = MaxDepth * GuardBandX :: number
		if CameraSpaceCenter.X + ExtentX < -HalfFrustumX or CameraSpaceCenter.X - ExtentX > HalfFrustumX then
			return false, vector.zero, vector.zero, vector.zero
		end

		const ExtentY =
			math.abs(CameraSpaceRightAxis.Y) + math.abs(CameraSpaceUpAxis.Y) + math.abs(CameraSpaceLookAxis.Y) :: number
		const HalfFrustumY = MaxDepth * GuardBandY :: number
		if CameraSpaceCenter.Y + ExtentY < -HalfFrustumY or CameraSpaceCenter.Y - ExtentY > HalfFrustumY then
			return false, vector.zero, vector.zero, vector.zero
		end
	end

	for VertexIndex = 1, VertexCount do
		const LocalVertex = LocalVertices[VertexIndex]
		const CameraVertex = CameraSpaceCenter
			+ CameraSpaceRightAxis * LocalVertex.x
			+ CameraSpaceUpAxis * LocalVertex.y
			+ CameraSpaceLookAxis * LocalVertex.z
		BufferHelper.WriteVec3(CameraVertices, (VertexIndex - 1) * 12, CameraVertex)
	end

	const LocalCameraPos = vector.create(
		-vector.dot(RelativePosition, RightAxis),
		-vector.dot(RelativePosition, UpAxis),
		-vector.dot(RelativePosition, LookAxis)
	)
	const LocalSun = vector.create(
		vector.dot(RightAxis, SunVec),
		vector.dot(UpAxis, SunVec),
		vector.dot(LookAxis, SunVec)
	)

	return true, LocalCameraPos, HalfSize, LocalSun
end

--[=[
	Calculates the camera focal length and frustum guardband scaling parameters.
	@param FovY number -- Vertical field of view in degrees.
	@param WIDTH number -- Viewport width in pixels.
	@param HEIGHT number -- Viewport height in pixels.
	@return (number, number, number) -- FocalLength, GuardBandX, GuardBandY.
]=]
function RenderMath.GetProjectionParameters(FovY: number, WIDTH: number, HEIGHT: number): (number, number, number)
	const FocalLength = (HEIGHT * 0.5) / math.tan(math.rad(FovY) * 0.5) :: number
	const GuardBandX = (WIDTH * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	const GuardBandY = (HEIGHT * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	return FocalLength, GuardBandX, GuardBandY
end

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
function RenderMath.ClipAndProjectQuad(
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
function RenderMath.ClipAndProjectTriangleUV(
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

-- ============================================================================
-- 2. DRAWING OBJECTS - EXACT SPAN RASTERIZATION
-- ============================================================================

--[=[
	Iterates and rasterizes a packed batch of textured triangles from a render command buffer.
	@param RenderBuffer buffer -- Source render command queue buffer.
	@param ByteCount number -- Total byte length of queued commands.
	@param TextureBuffers { [number]: buffer } -- Cached 64x64 RGBA texture buffers keyed by TextureId.
	@param TextureWidth number -- Texture width in texels.
	@param TextureHeight number -- Texture height in texels.
	@param WIDTH number -- Screen width in pixels.
	@param HEIGHT number -- Screen height in pixels.
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit depth buffer.
	@return (number, number) -- Modified scanline row range (DirtyMinY, DirtyMaxY).
]=]
function RenderMath.DrawTriangleBatch(
	RenderBuffer: buffer,
	ByteCount: number,
	TextureBuffers: { [number]: buffer },
	TextureWidth: number,
	TextureHeight: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: buffer,
	BandStartY: number?,
	BandEndY: number?
): (number, number)
	const RowStride = WIDTH * 4 :: number
	local DirtyMinY = HEIGHT :: number
	local DirtyMaxY = -1 :: number
	local ReadOffset = 0 :: number

	while ReadOffset < ByteCount do
		const TextureId = buffer.readu32(RenderBuffer, ReadOffset + 52) :: number
		const TriangleTextureBuffer: buffer? = if TextureId > 0 then TextureBuffers[TextureId] else nil

		const TriangleMinY: number, TriangleMaxY: number = MathModule.RasterizeTriangleSpan(
			buffer.readi16(RenderBuffer, ReadOffset),
			buffer.readi16(RenderBuffer, ReadOffset + 2),
			buffer.readf32(RenderBuffer, ReadOffset + 4),
			buffer.readf32(RenderBuffer, ReadOffset + 8),
			buffer.readf32(RenderBuffer, ReadOffset + 12),
			buffer.readi16(RenderBuffer, ReadOffset + 16),
			buffer.readi16(RenderBuffer, ReadOffset + 18),
			buffer.readf32(RenderBuffer, ReadOffset + 20),
			buffer.readf32(RenderBuffer, ReadOffset + 24),
			buffer.readf32(RenderBuffer, ReadOffset + 28),
			buffer.readi16(RenderBuffer, ReadOffset + 32),
			buffer.readi16(RenderBuffer, ReadOffset + 34),
			buffer.readf32(RenderBuffer, ReadOffset + 36),
			buffer.readf32(RenderBuffer, ReadOffset + 40),
			buffer.readf32(RenderBuffer, ReadOffset + 44),
			buffer.readu32(RenderBuffer, ReadOffset + 48),
			TriangleTextureBuffer,
			TextureWidth,
			TextureHeight,
			WIDTH,
			HEIGHT,
			RowStride,
			PixelBuffer,
			ZBuffer,
			BandStartY,
			BandEndY
		)

		if TriangleMinY < DirtyMinY then
			DirtyMinY = TriangleMinY
		end
		if TriangleMaxY > DirtyMaxY then
			DirtyMaxY = TriangleMaxY
		end

		ReadOffset += BUFFER_LAYOUT_SIZE
	end

	return DirtyMinY, DirtyMaxY
end

return RenderMath
