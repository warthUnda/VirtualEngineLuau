--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)
const MathModule = require(script.Parent.MathModule)

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
	const Pos = BufferHelper.ReadVec3(PositionBuffer, ComponentOffset)
	const Size = BufferHelper.ReadVec3(SizeBuffer, ComponentOffset) * 0.5
	const Hx: number, Hy: number, Hz: number = Size.x, Size.y, Size.z

	const Rel = Pos - CamPos
	const Cz = vector.dot(Rel, CamLook) :: number

	const Look = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset)
	const Up = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 12)
	const Right = BufferHelper.ReadVec3(DirectionsBuffer, DirectionOffset + 24)

	const RWorld = Right * Hx
	const UWorld = Up * Hy
	const LWorld = Look * Hz

	const Rz = vector.dot(RWorld, CamLook) :: number
	const Uz = vector.dot(UWorld, CamLook) :: number
	const Lz = vector.dot(LWorld, CamLook) :: number

	const ExtentZ = math.abs(Rz) + math.abs(Uz) + math.abs(Lz) :: number
	if Cz + ExtentZ < NEAR_CLIP or Cz - ExtentZ > FAR_CLIP then
		return 0
	end

	-- Object-space backface test: at most 3 of the 6 box faces can face the camera
	const RelLook = vector.dot(Rel, Look) :: number
	const RelUp = vector.dot(Rel, Up) :: number
	const RelRight = vector.dot(Rel, Right) :: number

	local FaceMask = 0 :: number
	if RelLook < -Hz + BACKFACE_EPSILON then
		FaceMask += 1 -- Back (+Look)
	elseif RelLook > Hz - BACKFACE_EPSILON then
		FaceMask += 2 -- Front (-Look)
	end

	if RelUp > Hy - BACKFACE_EPSILON then
		FaceMask += 4 -- Bottom (-Up)
	elseif RelUp < -Hy + BACKFACE_EPSILON then
		FaceMask += 8 -- Top (+Up)
	end

	if RelRight > Hx - BACKFACE_EPSILON then
		FaceMask += 16 -- Left (-Right)
	elseif RelRight < -Hx + BACKFACE_EPSILON then
		FaceMask += 32 -- Right (+Right)
	end

	if FaceMask == 0 then
		return 0
	end

	const C = vector.create(vector.dot(Rel, CamRight), vector.dot(Rel, CamUp), Cz)
	const R = vector.create(vector.dot(RWorld, CamRight), vector.dot(RWorld, CamUp), Rz)
	const U = vector.create(vector.dot(UWorld, CamRight), vector.dot(UWorld, CamUp), Uz)
	const L = vector.create(vector.dot(LWorld, CamRight), vector.dot(LWorld, CamUp), Lz)

	const CenterMinusU = C - U
	const CenterPlusU = C + U
	const RightPlusL = R + L
	const LMinusRight = L - R

	-- 8 corners computed with 3-wide SIMD vector add/sub
	BufferHelper.WriteVec3(CameraVertices, 0, CenterMinusU + LMinusRight)
	BufferHelper.WriteVec3(CameraVertices, 12, CenterMinusU + RightPlusL)
	BufferHelper.WriteVec3(CameraVertices, 24, CenterPlusU + RightPlusL)
	BufferHelper.WriteVec3(CameraVertices, 36, CenterPlusU + LMinusRight)
	BufferHelper.WriteVec3(CameraVertices, 48, CenterMinusU - RightPlusL)
	BufferHelper.WriteVec3(CameraVertices, 60, CenterMinusU - LMinusRight)
	BufferHelper.WriteVec3(CameraVertices, 72, CenterPlusU - LMinusRight)
	BufferHelper.WriteVec3(CameraVertices, 84, CenterPlusU - RightPlusL)

	return FaceMask
end

function RenderMath.GetProjectionParameters(FovY: number, WIDTH: number, HEIGHT: number): (number, number, number)
	const FocalLength = (HEIGHT * 0.5) / math.tan(math.rad(FovY) * 0.5) :: number
	const GuardBandX = (WIDTH * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	const GuardBandY = (HEIGHT * 0.5 * GUARD_BAND_SCALE) / FocalLength :: number
	return FocalLength, GuardBandX, GuardBandY
end

function RenderMath.ClipAndProjectQuad(
	CameraVertices: buffer,
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	HalfWidth: number,
	HalfHeight: number
): number
	const Q0 = BufferHelper.ReadVec3(CameraVertices, V0ByteOffset)
	const Q1 = BufferHelper.ReadVec3(CameraVertices, V1ByteOffset)
	const Q2 = BufferHelper.ReadVec3(CameraVertices, V2ByteOffset)
	const Q3 = BufferHelper.ReadVec3(CameraVertices, V3ByteOffset)

	if
		MathModule.IsVertexInside(Q0, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(Q1, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(Q2, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(Q3, GuardBandX, GuardBandY)
	then
		MathModule.ProjectVertex(ProjectedVertices, 0, Q0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 12, Q1, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 24, Q2, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 36, Q3, FocalLength, HalfWidth, HalfHeight)
		return 4
	end

	BufferHelper.WriteVec3(ClipBufferA, 0, Q0)
	BufferHelper.WriteVec3(ClipBufferA, 12, Q1)
	BufferHelper.WriteVec3(ClipBufferA, 24, Q2)
	BufferHelper.WriteVec3(ClipBufferA, 36, Q3)

	local VertexCount = MathModule.ClipPolygon(ClipBufferA, 4, ClipBufferB, PLANE_NEAR, -NEAR_CLIP)
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
	const T0 = BufferHelper.ReadVec3(CameraVertices, (V0Index - 1) * 12)
	const T1 = BufferHelper.ReadVec3(CameraVertices, (V1Index - 1) * 12)
	const T2 = BufferHelper.ReadVec3(CameraVertices, (V2Index - 1) * 12)

	if
		MathModule.IsVertexInside(T0, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(T1, GuardBandX, GuardBandY)
		and MathModule.IsVertexInside(T2, GuardBandX, GuardBandY)
	then
		MathModule.ProjectVertex(ProjectedVertices, 0, T0, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 12, T1, FocalLength, HalfWidth, HalfHeight)
		MathModule.ProjectVertex(ProjectedVertices, 24, T2, FocalLength, HalfWidth, HalfHeight)
		return 3
	end

	BufferHelper.WriteVec3(ClipBufferA, 0, T0)
	BufferHelper.WriteVec3(ClipBufferA, 12, T1)
	BufferHelper.WriteVec3(ClipBufferA, 24, T2)

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

function RenderMath.DrawTriangle(
	X0: number,
	Y0: number,
	ScaledInvZ0: number,
	X1: number,
	Y1: number,
	ScaledInvZ1: number,
	X2: number,
	Y2: number,
	ScaledInvZ2: number,
	PackedColor: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: buffer
)
	MathModule.RasterizeTriangleSpan(
		X0,
		Y0,
		ScaledInvZ0,
		X1,
		Y1,
		ScaledInvZ1,
		X2,
		Y2,
		ScaledInvZ2,
		PackedColor,
		WIDTH,
		HEIGHT,
		WIDTH * 4,
		PixelBuffer,
		ZBuffer
	)
end

function RenderMath.DrawTriangleBatch(
	RenderBuffer: buffer,
	ByteCount: number,
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
		const TriMinY: number, TriMaxY: number = MathModule.RasterizeTriangleSpan(
			buffer.readi16(RenderBuffer, ReadOffset),
			buffer.readi16(RenderBuffer, ReadOffset + 2),
			buffer.readf32(RenderBuffer, ReadOffset + 4),
			buffer.readi16(RenderBuffer, ReadOffset + 8),
			buffer.readi16(RenderBuffer, ReadOffset + 10),
			buffer.readf32(RenderBuffer, ReadOffset + 12),
			buffer.readi16(RenderBuffer, ReadOffset + 16),
			buffer.readi16(RenderBuffer, ReadOffset + 18),
			buffer.readf32(RenderBuffer, ReadOffset + 20),
			buffer.readu32(RenderBuffer, ReadOffset + 24),
			WIDTH,
			HEIGHT,
			RowStride,
			PixelBuffer,
			ZBuffer
		)

		if TriMinY < DirtyMinY then
			DirtyMinY = TriMinY
		end
		if TriMaxY > DirtyMaxY then
			DirtyMaxY = TriMaxY
		end

		ReadOffset += BUFFER_LAYOUT_SIZE
	end

	return DirtyMinY, DirtyMaxY
end

return RenderMath
