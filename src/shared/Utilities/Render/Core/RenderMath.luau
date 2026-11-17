--!strict
--!native
--!optimize 2

--[=[
	@class RenderMath
	Core software rasterizer math facade for camera-space OBB vertex transformation,
	projection parameter calculation, polygon clipping, Cube-to-Plane impostor selection,
	and scanline triangle batch dispatch.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const RasterizerMath = require(script.Parent.RasterizerMath)
const PolygonClipMath = require(script.Parent.PolygonClipMath)
const CubeImpostorMath = require(script.Parent.CubeImpostorMath)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const GUARD_BAND_SCALE = SystemsConfigs.GuardBandScale :: number
const BUFFER_LAYOUT_SIZE = SystemsConfigs.RenderBufferLayoutSize :: number

-- Tables --
local RenderMath = {}

-- Functions --
-- ============================================================================
-- 1. CAMERA-SPACE OBB TRANSFORM, PROJECTION PARAMS & BATCH DISPATCH FACADE
-- ============================================================================

--[=[
	Transforms an arbitrary shape's unit local vertices into camera space and computes local camera/sun vectors.
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
	@param GuardBandX number? -- Optional horizontal guardband slope factor.
	@param GuardBandY number? -- Optional vertical guardband slope factor.
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
	const RelativePosition = PartPosition - CamPos
	const CameraSpaceCenterZ = vector.dot(RelativePosition, CamLook) :: number

	const LookAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset)
	const UpAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 12)
	const RightAxis = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 24)

	const WorldRightAxis = RightAxis * HalfSize.x
	const WorldUpAxis = UpAxis * HalfSize.y
	const WorldLookAxis = LookAxis * HalfSize.z

	const RightAxisCameraZ = vector.dot(WorldRightAxis, CamLook) :: number
	const UpAxisCameraZ = vector.dot(WorldUpAxis, CamLook) :: number
	const LookAxisCameraZ = vector.dot(WorldLookAxis, CamLook) :: number
	const CameraSpaceExtentZ = math.abs(RightAxisCameraZ) + math.abs(UpAxisCameraZ) + math.abs(LookAxisCameraZ) :: number

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
		const ExtentX = math.abs(CameraSpaceRightAxis.X) + math.abs(CameraSpaceUpAxis.X) + math.abs(CameraSpaceLookAxis.X) :: number
		const HalfFrustumX = MaxDepth * GuardBandX :: number
		if CameraSpaceCenter.X + ExtentX < -HalfFrustumX or CameraSpaceCenter.X - ExtentX > HalfFrustumX then
			return false, vector.zero, vector.zero, vector.zero
		end

		const ExtentY = math.abs(CameraSpaceRightAxis.Y) + math.abs(CameraSpaceUpAxis.Y) + math.abs(CameraSpaceLookAxis.Y) :: number
		const HalfFrustumY = MaxDepth * GuardBandY :: number
		if CameraSpaceCenter.Y + ExtentY < -HalfFrustumY or CameraSpaceCenter.Y - ExtentY > HalfFrustumY then
			return false, vector.zero, vector.zero, vector.zero
		end
	end

	for VertexIndex = 1, VertexCount do
		const LocalVertex = LocalVertices[VertexIndex]
		const VertexOffset = (VertexIndex - 1) * 12 :: number
		BufferHelper.WriteVec3(
			CameraVertices,
			VertexOffset,
			CameraSpaceCenter + CameraSpaceRightAxis * LocalVertex.x + CameraSpaceUpAxis * LocalVertex.y + CameraSpaceLookAxis * LocalVertex.z
		)
	end

	const LocalCameraPos = vector.create(
		-vector.dot(RelativePosition, RightAxis),
		-vector.dot(RelativePosition, UpAxis),
		-vector.dot(RelativePosition, LookAxis)
	)
	const LocalSun = vector.create(vector.dot(RightAxis, SunVec), vector.dot(UpAxis, SunVec), vector.dot(LookAxis, SunVec))

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

RenderMath.ClipAndProjectQuad = PolygonClipMath.ClipAndProjectQuad
RenderMath.ClipAndProjectTriangleUV = PolygonClipMath.ClipAndProjectTriangleUV
RenderMath.SelectCubeRenderMode = CubeImpostorMath.SelectCubeRenderMode
RenderMath.TransformCubeOrPlaneImpostor = CubeImpostorMath.TransformCubeOrPlaneImpostor
RenderMath.GetImpostorShadingAndUV = CubeImpostorMath.GetImpostorShadingAndUV

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
	@param BandStartY number? -- Optional inclusive scanline band start Y.
	@param BandEndY number? -- Optional inclusive scanline band end Y.
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
	const RasterizeSpan = RasterizerMath.RasterizeTriangleSpan
	local DirtyMinY = HEIGHT :: number
	local DirtyMaxY = -1 :: number
	local ReadOffset = 0 :: number

	while ReadOffset < ByteCount do
		const TextureId = buffer.readu32(RenderBuffer, ReadOffset + 52) :: number
		const TriangleTextureBuffer: buffer? = if TextureId > 0 then TextureBuffers[TextureId] else nil

		const TriangleMinY: number, TriangleMaxY: number = RasterizeSpan(
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
