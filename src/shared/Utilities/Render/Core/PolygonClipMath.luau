--!strict
--!native
--!optimize 2

--[=[
	@class PolygonClipMath
	Frustum quad and triangle UV clipping with 6-bit outcode trivial rejection,
	active-plane masking, early exits, and precomputed guardband plane normals.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
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
-- 1. OUTCODE FRUSTUM QUAD & TRIANGLE CLIPPING AND PROJECTION
-- ============================================================================

--[=[
	Runs masked Sutherland-Hodgman plane clipping over the active planes in PlaneMask and projects output vertices.
]=]
function PolygonClipMath.RunMaskedClipAndProject(
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	InitialCount: number,
	PlaneMask: number,
	ProjectedVertices: buffer,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	HalfWidth: number,
	HalfHeight: number,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): number
	const ClipUV = MathModule.ClipPolygonUV
	local Src = ClipBufferA :: buffer
	local Dst = ClipBufferB :: buffer
	local Count = InitialCount :: number

	if bit32.btest(PlaneMask, 1) then
		Count = ClipUV(Src, Count, Dst, PLANE_NEAR, -NEAR_CLIP)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end
	if bit32.btest(PlaneMask, 2) then
		Count = ClipUV(Src, Count, Dst, PLANE_FAR, FAR_CLIP)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end
	if bit32.btest(PlaneMask, 4) then
		Count = ClipUV(Src, Count, Dst, PlaneLeft or vector.create(1, 0, GuardBandX), 0)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end
	if bit32.btest(PlaneMask, 8) then
		Count = ClipUV(Src, Count, Dst, PlaneRight or vector.create(-1, 0, GuardBandX), 0)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end
	if bit32.btest(PlaneMask, 16) then
		Count = ClipUV(Src, Count, Dst, PlaneBottom or vector.create(0, 1, GuardBandY), 0)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end
	if bit32.btest(PlaneMask, 32) then
		Count = ClipUV(Src, Count, Dst, PlaneTop or vector.create(0, -1, GuardBandY), 0)
		if Count < 3 then return 0 end
		Src, Dst = Dst, Src
	end

	for i = 0, Count - 1 do
		const Off = i * 24 :: number
		const Vx = buffer.readf32(Src, Off) :: number
		const Vy = buffer.readf32(Src, Off + 4) :: number
		const InvZ = 1 / buffer.readf32(Src, Off + 8) :: number
		const Scale = InvZ * FocalLength :: number
		buffer.writef32(ProjectedVertices, Off, math.floor(Vx * Scale + HalfWidth))
		buffer.writef32(ProjectedVertices, Off + 4, math.floor(-Vy * Scale + HalfHeight))
		buffer.writef32(ProjectedVertices, Off + 8, InvZ)
		buffer.writef32(ProjectedVertices, Off + 12, buffer.readf32(Src, Off + 12))
		buffer.writef32(ProjectedVertices, Off + 16, buffer.readf32(Src, Off + 16))
	end

	return Count
end

--[=[
	Clips a camera-space quad against frustum planes using 6-bit outcodes and projects vertices with UVs onto the screen.
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
	HalfHeight: number,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): number
	const X0, Y0, Z0 = buffer.readf32(CameraVertices, V0ByteOffset), buffer.readf32(CameraVertices, V0ByteOffset + 4), buffer.readf32(CameraVertices, V0ByteOffset + 8)
	const X1, Y1, Z1 = buffer.readf32(CameraVertices, V1ByteOffset), buffer.readf32(CameraVertices, V1ByteOffset + 4), buffer.readf32(CameraVertices, V1ByteOffset + 8)
	const X2, Y2, Z2 = buffer.readf32(CameraVertices, V2ByteOffset), buffer.readf32(CameraVertices, V2ByteOffset + 4), buffer.readf32(CameraVertices, V2ByteOffset + 8)
	const X3, Y3, Z3 = buffer.readf32(CameraVertices, V3ByteOffset), buffer.readf32(CameraVertices, V3ByteOffset + 4), buffer.readf32(CameraVertices, V3ByteOffset + 8)

	const C0 = (if Z0 < NEAR_CLIP then 1 else 0) + (if Z0 > FAR_CLIP then 2 else 0)
		+ (if X0 < -GuardBandX * Z0 then 4 else 0) + (if X0 > GuardBandX * Z0 then 8 else 0)
		+ (if Y0 < -GuardBandY * Z0 then 16 else 0) + (if Y0 > GuardBandY * Z0 then 32 else 0) :: number
	const C1 = (if Z1 < NEAR_CLIP then 1 else 0) + (if Z1 > FAR_CLIP then 2 else 0)
		+ (if X1 < -GuardBandX * Z1 then 4 else 0) + (if X1 > GuardBandX * Z1 then 8 else 0)
		+ (if Y1 < -GuardBandY * Z1 then 16 else 0) + (if Y1 > GuardBandY * Z1 then 32 else 0) :: number
	const C2 = (if Z2 < NEAR_CLIP then 1 else 0) + (if Z2 > FAR_CLIP then 2 else 0)
		+ (if X2 < -GuardBandX * Z2 then 4 else 0) + (if X2 > GuardBandX * Z2 then 8 else 0)
		+ (if Y2 < -GuardBandY * Z2 then 16 else 0) + (if Y2 > GuardBandY * Z2 then 32 else 0) :: number
	const C3 = (if Z3 < NEAR_CLIP then 1 else 0) + (if Z3 > FAR_CLIP then 2 else 0)
		+ (if X3 < -GuardBandX * Z3 then 4 else 0) + (if X3 > GuardBandX * Z3 then 8 else 0)
		+ (if Y3 < -GuardBandY * Z3 then 16 else 0) + (if Y3 > GuardBandY * Z3 then 32 else 0) :: number

	if bit32.band(C0, C1, C2, C3) ~= 0 then
		return 0
	end

	const UnionMask = bit32.bor(C0, C1, C2, C3) :: number
	if UnionMask == 0 then
		const IZ0 = 1 / Z0 :: number
		const S0 = IZ0 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 0, math.floor(X0 * S0 + HalfWidth))
		buffer.writef32(ProjectedVertices, 4, math.floor(-Y0 * S0 + HalfHeight))
		buffer.writef32(ProjectedVertices, 8, IZ0)
		buffer.writef32(ProjectedVertices, 12, 0)
		buffer.writef32(ProjectedVertices, 16, ScaleV)

		const IZ1 = 1 / Z1 :: number
		const S1 = IZ1 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 24, math.floor(X1 * S1 + HalfWidth))
		buffer.writef32(ProjectedVertices, 28, math.floor(-Y1 * S1 + HalfHeight))
		buffer.writef32(ProjectedVertices, 32, IZ1)
		buffer.writef32(ProjectedVertices, 36, 0)
		buffer.writef32(ProjectedVertices, 40, 0)

		const IZ2 = 1 / Z2 :: number
		const S2 = IZ2 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 48, math.floor(X2 * S2 + HalfWidth))
		buffer.writef32(ProjectedVertices, 52, math.floor(-Y2 * S2 + HalfHeight))
		buffer.writef32(ProjectedVertices, 56, IZ2)
		buffer.writef32(ProjectedVertices, 60, ScaleU)
		buffer.writef32(ProjectedVertices, 64, 0)

		const IZ3 = 1 / Z3 :: number
		const S3 = IZ3 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 72, math.floor(X3 * S3 + HalfWidth))
		buffer.writef32(ProjectedVertices, 76, math.floor(-Y3 * S3 + HalfHeight))
		buffer.writef32(ProjectedVertices, 80, IZ3)
		buffer.writef32(ProjectedVertices, 84, ScaleU)
		buffer.writef32(ProjectedVertices, 88, ScaleV)
		return 4
	end

	buffer.writef32(ClipBufferA, 0, X0); buffer.writef32(ClipBufferA, 4, Y0); buffer.writef32(ClipBufferA, 8, Z0); buffer.writef32(ClipBufferA, 12, 0); buffer.writef32(ClipBufferA, 16, ScaleV)
	buffer.writef32(ClipBufferA, 24, X1); buffer.writef32(ClipBufferA, 28, Y1); buffer.writef32(ClipBufferA, 32, Z1); buffer.writef32(ClipBufferA, 36, 0); buffer.writef32(ClipBufferA, 40, 0)
	buffer.writef32(ClipBufferA, 48, X2); buffer.writef32(ClipBufferA, 52, Y2); buffer.writef32(ClipBufferA, 56, Z2); buffer.writef32(ClipBufferA, 60, ScaleU); buffer.writef32(ClipBufferA, 64, 0)
	buffer.writef32(ClipBufferA, 72, X3); buffer.writef32(ClipBufferA, 76, Y3); buffer.writef32(ClipBufferA, 80, Z3); buffer.writef32(ClipBufferA, 84, ScaleU); buffer.writef32(ClipBufferA, 88, ScaleV)

	return PolygonClipMath.RunMaskedClipAndProject(
		ClipBufferA, ClipBufferB, 4, UnionMask, ProjectedVertices,
		FocalLength, GuardBandX, GuardBandY, HalfWidth, HalfHeight,
		PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
	)
end

--[=[
	Clips a camera-space triangle face against frustum planes using 6-bit outcodes and projects vertices with UVs.
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
	HalfHeight: number,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): number
	const X0, Y0, Z0 = buffer.readf32(CameraVertices, V0ByteOffset), buffer.readf32(CameraVertices, V0ByteOffset + 4), buffer.readf32(CameraVertices, V0ByteOffset + 8)
	const X1, Y1, Z1 = buffer.readf32(CameraVertices, V1ByteOffset), buffer.readf32(CameraVertices, V1ByteOffset + 4), buffer.readf32(CameraVertices, V1ByteOffset + 8)
	const X2, Y2, Z2 = buffer.readf32(CameraVertices, V2ByteOffset), buffer.readf32(CameraVertices, V2ByteOffset + 4), buffer.readf32(CameraVertices, V2ByteOffset + 8)

	const C0 = (if Z0 < NEAR_CLIP then 1 else 0) + (if Z0 > FAR_CLIP then 2 else 0)
		+ (if X0 < -GuardBandX * Z0 then 4 else 0) + (if X0 > GuardBandX * Z0 then 8 else 0)
		+ (if Y0 < -GuardBandY * Z0 then 16 else 0) + (if Y0 > GuardBandY * Z0 then 32 else 0) :: number
	const C1 = (if Z1 < NEAR_CLIP then 1 else 0) + (if Z1 > FAR_CLIP then 2 else 0)
		+ (if X1 < -GuardBandX * Z1 then 4 else 0) + (if X1 > GuardBandX * Z1 then 8 else 0)
		+ (if Y1 < -GuardBandY * Z1 then 16 else 0) + (if Y1 > GuardBandY * Z1 then 32 else 0) :: number
	const C2 = (if Z2 < NEAR_CLIP then 1 else 0) + (if Z2 > FAR_CLIP then 2 else 0)
		+ (if X2 < -GuardBandX * Z2 then 4 else 0) + (if X2 > GuardBandX * Z2 then 8 else 0)
		+ (if Y2 < -GuardBandY * Z2 then 16 else 0) + (if Y2 > GuardBandY * Z2 then 32 else 0) :: number

	if bit32.band(C0, C1, C2) ~= 0 then
		return 0
	end

	const UnionMask = bit32.bor(C0, C1, C2) :: number
	if UnionMask == 0 then
		const IZ0 = 1 / Z0 :: number
		const S0 = IZ0 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 0, math.floor(X0 * S0 + HalfWidth))
		buffer.writef32(ProjectedVertices, 4, math.floor(-Y0 * S0 + HalfHeight))
		buffer.writef32(ProjectedVertices, 8, IZ0)
		buffer.writef32(ProjectedVertices, 12, 0)
		buffer.writef32(ProjectedVertices, 16, ScaleV)

		const IZ1 = 1 / Z1 :: number
		const S1 = IZ1 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 24, math.floor(X1 * S1 + HalfWidth))
		buffer.writef32(ProjectedVertices, 28, math.floor(-Y1 * S1 + HalfHeight))
		buffer.writef32(ProjectedVertices, 32, IZ1)
		buffer.writef32(ProjectedVertices, 36, 0)
		buffer.writef32(ProjectedVertices, 40, 0)

		const IZ2 = 1 / Z2 :: number
		const S2 = IZ2 * FocalLength :: number
		buffer.writef32(ProjectedVertices, 48, math.floor(X2 * S2 + HalfWidth))
		buffer.writef32(ProjectedVertices, 52, math.floor(-Y2 * S2 + HalfHeight))
		buffer.writef32(ProjectedVertices, 56, IZ2)
		buffer.writef32(ProjectedVertices, 60, ScaleU)
		buffer.writef32(ProjectedVertices, 64, ScaleV)
		return 3
	end

	buffer.writef32(ClipBufferA, 0, X0); buffer.writef32(ClipBufferA, 4, Y0); buffer.writef32(ClipBufferA, 8, Z0); buffer.writef32(ClipBufferA, 12, 0); buffer.writef32(ClipBufferA, 16, ScaleV)
	buffer.writef32(ClipBufferA, 24, X1); buffer.writef32(ClipBufferA, 28, Y1); buffer.writef32(ClipBufferA, 32, Z1); buffer.writef32(ClipBufferA, 36, 0); buffer.writef32(ClipBufferA, 40, 0)
	buffer.writef32(ClipBufferA, 48, X2); buffer.writef32(ClipBufferA, 52, Y2); buffer.writef32(ClipBufferA, 56, Z2); buffer.writef32(ClipBufferA, 60, ScaleU); buffer.writef32(ClipBufferA, 64, ScaleV)

	return PolygonClipMath.RunMaskedClipAndProject(
		ClipBufferA, ClipBufferB, 3, UnionMask, ProjectedVertices,
		FocalLength, GuardBandX, GuardBandY, HalfWidth, HalfHeight,
		PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
	)
end

return PolygonClipMath
