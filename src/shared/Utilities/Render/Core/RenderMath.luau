--!strict
--!native
--!optimize 2

--[=[
	@class RenderMath
	Core software rasterizer math facade for camera-space OBB vertex transformation (with AllInside
	fast-path detection), projection parameter calculation, outcode polygon clipping, and
	legacy/tile-based triangle batch rasterization.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const RasterizerMath = require(script.Parent.RasterizerMath)
const PolygonClipMath = require(script.Parent.PolygonClipMath)
const TileRasterizerMath = require(script.Parent.TileRasterizerMath)

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
	Transforms an arbitrary shape's unit local vertices into camera space, computes local camera/sun vectors,
	and returns AllInside = true when the entire OBB lies strictly inside Near/Far and GuardBandX/Y.
	@return (boolean, vector, vector, vector, boolean) -- (IsVisible, LocalCameraPos, HalfSize, LocalSun, AllInside).
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
): (boolean, vector, vector, vector, boolean)
	const PartPosition = vector.create(
		buffer.readf32(PositionBuffer, ComponentOffset),
		buffer.readf32(PositionBuffer, ComponentOffset + 4),
		buffer.readf32(PositionBuffer, ComponentOffset + 8)
	)
	const HalfSize = vector.create(
		buffer.readf32(SizeBuffer, ComponentOffset) * 0.5,
		buffer.readf32(SizeBuffer, ComponentOffset + 4) * 0.5,
		buffer.readf32(SizeBuffer, ComponentOffset + 8) * 0.5
	)
	const RelativePosition = PartPosition - CamPos
	const CameraSpaceCenterZ = vector.dot(RelativePosition, CamLook) :: number

	const LookAxis = vector.create(
		buffer.readf32(DirectionsBuffer, DirectionOffset),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 4),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 8)
	)
	const UpAxis = vector.create(
		buffer.readf32(DirectionsBuffer, DirectionOffset + 12),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 16),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 20)
	)
	const RightAxis = vector.create(
		buffer.readf32(DirectionsBuffer, DirectionOffset + 24),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 28),
		buffer.readf32(DirectionsBuffer, DirectionOffset + 32)
	)

	const WorldRightAxis = RightAxis * HalfSize.x
	const WorldUpAxis = UpAxis * HalfSize.y
	const WorldLookAxis = LookAxis * HalfSize.z

	const RightAxisCameraZ = vector.dot(WorldRightAxis, CamLook) :: number
	const UpAxisCameraZ = vector.dot(WorldUpAxis, CamLook) :: number
	const LookAxisCameraZ = vector.dot(WorldLookAxis, CamLook) :: number
	const CameraSpaceExtentZ = math.abs(RightAxisCameraZ) + math.abs(UpAxisCameraZ) + math.abs(LookAxisCameraZ) :: number

	const MaxDepthZ = CameraSpaceCenterZ + CameraSpaceExtentZ :: number
	const MinDepthZ = CameraSpaceCenterZ - CameraSpaceExtentZ :: number
	if MaxDepthZ < NEAR_CLIP or MinDepthZ > FAR_CLIP then
		return false, vector.zero, vector.zero, vector.zero, false
	end

	const CenterX = vector.dot(RelativePosition, CamRight) :: number
	const CenterY = vector.dot(RelativePosition, CamUp) :: number
	const CameraSpaceCenter = vector.create(CenterX, CenterY, CameraSpaceCenterZ)
	const CameraSpaceRightAxis = vector.create(vector.dot(WorldRightAxis, CamRight), vector.dot(WorldRightAxis, CamUp), RightAxisCameraZ)
	const CameraSpaceUpAxis = vector.create(vector.dot(WorldUpAxis, CamRight), vector.dot(WorldUpAxis, CamUp), UpAxisCameraZ)
	const CameraSpaceLookAxis = vector.create(vector.dot(WorldLookAxis, CamRight), vector.dot(WorldLookAxis, CamUp), LookAxisCameraZ)

	local AllInside = false :: boolean
	if GuardBandX and GuardBandY then
		const ClampedMaxDepth = math.max(MaxDepthZ, NEAR_CLIP) :: number
		const ExtentX = math.abs(CameraSpaceRightAxis.x) + math.abs(CameraSpaceUpAxis.x) + math.abs(CameraSpaceLookAxis.x) :: number
		const HalfFrustumX = ClampedMaxDepth * GuardBandX :: number
		if CenterX + ExtentX < -HalfFrustumX or CenterX - ExtentX > HalfFrustumX then
			return false, vector.zero, vector.zero, vector.zero, false
		end

		const ExtentY = math.abs(CameraSpaceRightAxis.y) + math.abs(CameraSpaceUpAxis.y) + math.abs(CameraSpaceLookAxis.y) :: number
		const HalfFrustumY = ClampedMaxDepth * GuardBandY :: number
		if CenterY + ExtentY < -HalfFrustumY or CenterY - ExtentY > HalfFrustumY then
			return false, vector.zero, vector.zero, vector.zero, false
		end

		if
			MinDepthZ >= NEAR_CLIP
			and MaxDepthZ <= FAR_CLIP
			and (math.abs(CenterX) + ExtentX) <= MinDepthZ * GuardBandX
			and (math.abs(CenterY) + ExtentY) <= MinDepthZ * GuardBandY
		then
			AllInside = true
		end
	end

	for VertexIndex = 1, VertexCount do
		const LocalVertex = LocalVertices[VertexIndex]
		const VertexOffset = (VertexIndex - 1) * 12 :: number
		const CamV = CameraSpaceCenter
			+ CameraSpaceRightAxis * LocalVertex.x
			+ CameraSpaceUpAxis * LocalVertex.y
			+ CameraSpaceLookAxis * LocalVertex.z
		buffer.writef32(CameraVertices, VertexOffset, CamV.x)
		buffer.writef32(CameraVertices, VertexOffset + 4, CamV.y)
		buffer.writef32(CameraVertices, VertexOffset + 8, CamV.z)
	end

	const LocalCameraPos = vector.create(
		-vector.dot(RelativePosition, RightAxis),
		-vector.dot(RelativePosition, UpAxis),
		-vector.dot(RelativePosition, LookAxis)
	)
	const LocalSun = vector.create(vector.dot(RightAxis, SunVec), vector.dot(UpAxis, SunVec), vector.dot(LookAxis, SunVec))

	return true, LocalCameraPos, HalfSize, LocalSun, AllInside
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
RenderMath.RasterizeBandDual = TileRasterizerMath.RasterizeBandDual

--[=[
	Iterates and rasterizes a legacy packed batch of triangles (skipping UV reads for untextured commands).
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

		local TriangleMinY: number, TriangleMaxY: number
		if TriangleTextureBuffer then
			TriangleMinY, TriangleMaxY = RasterizeSpan(
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
		else
			TriangleMinY, TriangleMaxY = RasterizeSpan(
				buffer.readi16(RenderBuffer, ReadOffset),
				buffer.readi16(RenderBuffer, ReadOffset + 2),
				buffer.readf32(RenderBuffer, ReadOffset + 4),
				0,
				0,
				buffer.readi16(RenderBuffer, ReadOffset + 16),
				buffer.readi16(RenderBuffer, ReadOffset + 18),
				buffer.readf32(RenderBuffer, ReadOffset + 20),
				0,
				0,
				buffer.readi16(RenderBuffer, ReadOffset + 32),
				buffer.readi16(RenderBuffer, ReadOffset + 34),
				buffer.readf32(RenderBuffer, ReadOffset + 36),
				0,
				0,
				buffer.readu32(RenderBuffer, ReadOffset + 48),
				nil,
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
		end

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
