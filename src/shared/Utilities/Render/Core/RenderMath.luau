--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const MathModule = require(script.Parent.MathModule)
const TextureHelper = require(script.Parent.TextureHelper)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const GUARD_BAND_SCALE = SystemsConfigs.GuardBandScale :: number
const BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number
const BACKFACE_EPSILON = 1e-3 :: number

const PLANE_NEAR = vector.create(0, 0, 1)
const PLANE_FAR = vector.create(0, 0, -1)

local RenderMath = {}

-- ============================================================================
-- 1. FUNCTIONS - RENDERING MATH
-- ============================================================================

--[=[
	Transforms an oriented box entity into camera space, performs frustum culling, backface culling, and writes 8 corner vertices.
	@param PositionBuffer buffer -- Entity position component buffer.
	@param DirectionsBuffer buffer -- Entity basis directions buffer.
	@param SizeBuffer buffer -- Entity size component buffer.
	@param ComponentOffset number -- Byte offset in position/size buffers.
	@param DirectionOffset number -- Byte offset in directions buffer.
	@param CameraVertices buffer -- Output buffer for 8 camera-space vertices.
	@param CamPos vector -- Camera world position.
	@param CamRight vector -- Camera RightVector.
	@param CamUp vector -- Camera UpVector.
	@param CamLook vector -- Camera LookVector.
	@return number -- Bitmask of visible faces (0 if entirely culled).
]=]
function RenderMath.GetPartCameraVertices(
	PositionBuffer: buffer,
	DirectionsBuffer: buffer,
	SizeBuffer: buffer,
	ComponentOffset: number,
	DirectionOffset: number,
	CameraVertices: buffer,
	CamPos: vector,
	CamRight: vector,
	CamUp: vector,
	CamLook: vector
): number
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
		return 0
	end

	-- Object-space backface test: at most 3 of the 6 box faces can face the camera
	const LocalCameraLook = vector.dot(RelativePosition, LookAxis) :: number
	const LocalCameraUp = vector.dot(RelativePosition, UpAxis) :: number
	const LocalCameraRight = vector.dot(RelativePosition, RightAxis) :: number

	local FaceMask = 0 :: number
	if LocalCameraLook < -HalfSizeZ + BACKFACE_EPSILON then
		FaceMask += 1 -- Back (+Look)
	elseif LocalCameraLook > HalfSizeZ - BACKFACE_EPSILON then
		FaceMask += 2 -- Front (-Look)
	end

	if LocalCameraUp > HalfSizeY - BACKFACE_EPSILON then
		FaceMask += 4 -- Bottom (-Up)
	elseif LocalCameraUp < -HalfSizeY + BACKFACE_EPSILON then
		FaceMask += 8 -- Top (+Up)
	end

	if LocalCameraRight > HalfSizeX - BACKFACE_EPSILON then
		FaceMask += 16 -- Left (-Right)
	elseif LocalCameraRight < -HalfSizeX + BACKFACE_EPSILON then
		FaceMask += 32 -- Right (+Right)
	end

	if FaceMask == 0 then
		return 0
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

	const CenterMinusUpAxis = CameraSpaceCenter - CameraSpaceUpAxis
	const CenterPlusUpAxis = CameraSpaceCenter + CameraSpaceUpAxis
	const RightPlusLookAxis = CameraSpaceRightAxis + CameraSpaceLookAxis
	const LookMinusRightAxis = CameraSpaceLookAxis - CameraSpaceRightAxis

	-- 8 corners computed with 3-wide SIMD vector add/sub
	BufferHelper.WriteVec3(CameraVertices, 0, CenterMinusUpAxis + LookMinusRightAxis)
	BufferHelper.WriteVec3(CameraVertices, 12, CenterMinusUpAxis + RightPlusLookAxis)
	BufferHelper.WriteVec3(CameraVertices, 24, CenterPlusUpAxis + RightPlusLookAxis)
	BufferHelper.WriteVec3(CameraVertices, 36, CenterPlusUpAxis + LookMinusRightAxis)
	BufferHelper.WriteVec3(CameraVertices, 48, CenterMinusUpAxis - RightPlusLookAxis)
	BufferHelper.WriteVec3(CameraVertices, 60, CenterMinusUpAxis - LookMinusRightAxis)
	BufferHelper.WriteVec3(CameraVertices, 72, CenterPlusUpAxis - LookMinusRightAxis)
	BufferHelper.WriteVec3(CameraVertices, 84, CenterPlusUpAxis - RightPlusLookAxis)

	return FaceMask
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
	Clips a camera-space triangle against frustum planes and projects vertices onto the screen.
	@param CameraVertices buffer -- Buffer containing camera-space vertices.
	@param V0Index number -- 1-based index for triangle vertex 0.
	@param V1Index number -- 1-based index for triangle vertex 1.
	@param V2Index number -- 1-based index for triangle vertex 2.
	@param ProjectedVertices buffer -- Buffer to receive projected 2D vertices.
	@param ClipBufferA buffer -- Temporary scratch buffer for polygon clipping.
	@param ClipBufferB buffer -- Secondary scratch buffer for polygon clipping.
	@param FocalLength number -- Camera focal length.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@param WIDTH number -- Target screen width in pixels.
	@param HEIGHT number -- Target screen height in pixels.
	@return number -- Total projected vertex count (0 if culled).
]=]
function RenderMath.ClipAndProjectTriangle(
	CameraVertices: buffer,
	V0Index: number,
	V1Index: number,
	V2Index: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	WIDTH: number,
	HEIGHT: number
): number
	const HalfWidth = WIDTH * 0.5 :: number
	const HalfHeight = HEIGHT * 0.5 :: number
	const TriangleVertex0 = BufferHelper.ReadVec3(CameraVertices, (V0Index - 1) * 12)
	const TriangleVertex1 = BufferHelper.ReadVec3(CameraVertices, (V1Index - 1) * 12)
	const TriangleVertex2 = BufferHelper.ReadVec3(CameraVertices, (V2Index - 1) * 12)

	if
		MathModule.IsVertexInside(TriangleVertex0, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(TriangleVertex1, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(TriangleVertex2, GuardBandX, GuardBandY)
	then
		MathModule.ProjectVertex(ProjectedVertices, 0, TriangleVertex0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 12, TriangleVertex1, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 24, TriangleVertex2, FocalLength, HalfWidth, HalfHeight)
		return 3
	end

	BufferHelper.WriteVec3(ClipBufferA, 0, TriangleVertex0)
	BufferHelper.WriteVec3(ClipBufferA, 12, TriangleVertex1)
	BufferHelper.WriteVec3(ClipBufferA, 24, TriangleVertex2)

	local VertexCount = MathModule.ClipPolygon(ClipBufferA, 3, ClipBufferB, PLANE_NEAR, -NEAR_CLIP)
	VertexCount = MathModule.ClipPolygon(ClipBufferB, VertexCount, ClipBufferA, PLANE_FAR, FAR_CLIP)
	VertexCount = MathModule.ClipPolygon(ClipBufferA, VertexCount, ClipBufferB, vector.create(1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygon(ClipBufferB, VertexCount, ClipBufferA, vector.create(-1, 0, GuardBandX), 0)
	VertexCount = MathModule.ClipPolygon(ClipBufferA, VertexCount, ClipBufferB, vector.create(0, 1, GuardBandY), 0)
	VertexCount = MathModule.ClipPolygon(ClipBufferB, VertexCount, ClipBufferA, vector.create(0, -1, GuardBandY), 0)

	for i = 1, VertexCount do
		const Offset = (i - 1) * 12 :: number
		MathModule.ProjectVertex(
			ProjectedVertices,
			Offset,
			BufferHelper.ReadVec3(ClipBufferA, Offset),
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
	Draws a single screen-space triangle into the color pixel and Z depth buffers.
	@param Vertex0X number -- Screen vertex 0 X.
	@param Vertex0Y number -- Screen vertex 0 Y.
	@param ScaledInverseZ0 number -- Pre-scaled 1/Z depth for vertex 0.
	@param Vertex1X number -- Screen vertex 1 X.
	@param Vertex1Y number -- Screen vertex 1 Y.
	@param ScaledInverseZ1 number -- Pre-scaled 1/Z depth for vertex 1.
	@param Vertex2X number -- Screen vertex 2 X.
	@param Vertex2Y number -- Screen vertex 2 Y.
	@param ScaledInverseZ2 number -- Pre-scaled 1/Z depth for vertex 2.
	@param PackedColor number -- Packed 32-bit RGBA color.
	@param WIDTH number -- Screen width in pixels.
	@param HEIGHT number -- Screen height in pixels.
	@param PixelBuffer buffer -- Destination color pixel buffer.
	@param ZBuffer buffer -- Destination 32-bit depth buffer.
]=]
function RenderMath.DrawTriangle(
	Vertex0X: number,
	Vertex0Y: number,
	ScaledInverseZ0: number,
	Vertex1X: number,
	Vertex1Y: number,
	ScaledInverseZ1: number,
	Vertex2X: number,
	Vertex2Y: number,
	ScaledInverseZ2: number,
	PackedColor: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
)
	const DefaultTexture: buffer, TextureWidth: number, TextureHeight: number = TextureHelper.GetDefaultTexture()
	MathModule.RasterizeTriangleSpan(
		Vertex0X,
		Vertex0Y,
		ScaledInverseZ0,
		0,
		0,
		Vertex1X,
		Vertex1Y,
		ScaledInverseZ1,
		0,
		0,
		Vertex2X,
		Vertex2Y,
		ScaledInverseZ2,
		0,
		0,
		PackedColor,
		DefaultTexture,
		TextureWidth,
		TextureHeight,
		WIDTH,
		HEIGHT,
		WIDTH * 4,
		PixelBuffer,
		ZBuffer
	)
end

--[=[
	Iterates and rasterizes a packed batch of textured triangles from a render command buffer.
	@param RenderBuffer buffer -- Source render command queue buffer.
	@param ByteCount number -- Total byte length of queued commands.
	@param TextureBuffers { [number]: buffer } -- Cached 64x64 RGBA texture buffers keyed by TextureId.
	@param DefaultTextureBuffer buffer -- Fallback 64x64 RGBA texture buffer.
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
	DefaultTextureBuffer: buffer,
	TextureWidth: number,
	TextureHeight: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
): (number, number)
	const RowStride = WIDTH * 4 :: number
	local DirtyMinY = HEIGHT :: number
	local DirtyMaxY = -1 :: number
	local ReadOffset = 0 :: number

	while ReadOffset < ByteCount do
		const TextureId = buffer.readu32(RenderBuffer, ReadOffset + 52) :: number
		const TriangleTextureBuffer: buffer? = if TextureId > 0 then (TextureBuffers[TextureId] or DefaultTextureBuffer) else nil

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
			ZBuffer
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
