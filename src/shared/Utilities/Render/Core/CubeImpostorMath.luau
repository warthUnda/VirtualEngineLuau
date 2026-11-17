--!strict
--!native
--!optimize 2

--[=[
	@class CubeImpostorMath
	Perspective Cube-to-Plane impostor classifier and SIMD camera-space vertex writer.
	Collapses Cubes (ShapeId = 0) viewed head-on, as thin slabs, or at sub-pixel grazing
	angles into a single 4-vertex Plane quad (skipping 50% of vertex transforms and 5 faces).
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent.BufferHelper)

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const NEAR_CLIP_SQ = NEAR_CLIP * NEAR_CLIP :: number

-- Tables --
local CubeImpostorMath = {}

-- Functions --
-- ============================================================================
-- 1. CUBE-TO-PLANE PERSPECTIVE IMPOSTOR CLASSIFICATION & VERTEX WRITING
-- ============================================================================

--[=[
	Classifies how a Cube should be rendered from the current camera perspective.
	Returns 0 (inside/culled), 1..6 (single-quad Plane impostor on +Z, -Z, -Y, +Y, -X, +X),
	or 7 (full 8-vertex, multi-face 3D Cube).
	@param LocalCamX number -- Camera X in the Cube's local orthonormal basis.
	@param LocalCamY number -- Camera Y in the Cube's local orthonormal basis.
	@param LocalCamZ number -- Camera Z in the Cube's local orthonormal basis.
	@param SizeX number -- Cube full world X extent.
	@param SizeY number -- Cube full world Y extent.
	@param SizeZ number -- Cube full world Z extent.
	@param FocalLength number -- Camera focal length in pixels.
	@param MaxImpostorPixels number -- Maximum side-face pixel thickness for Plane impostor collapse.
	@return number -- Render mode (0 = culled, 1..6 = Plane impostor face, 7 = full Cube).
]=]
function CubeImpostorMath.SelectCubeRenderMode(
	LocalCamX: number, LocalCamY: number, LocalCamZ: number,
	SizeX: number, SizeY: number, SizeZ: number,
	FocalLength: number, MaxImpostorPixels: number
): number
	const OverhangX = math.abs(LocalCamX) - SizeX * 0.5 :: number
	const OverhangY = math.abs(LocalCamY) - SizeY * 0.5 :: number
	const OverhangZ = math.abs(LocalCamZ) - SizeZ * 0.5 :: number

	const FrontX = OverhangX > -1e-3 :: boolean
	const FrontY = OverhangY > -1e-3 :: boolean
	const FrontZ = OverhangZ > -1e-3 :: boolean
	if not FrontX and not FrontY and not FrontZ then
		return 0
	end

	-- Exact lossless 1-face perspective (standing on floor, facing wall, or head-on view)
	if FrontZ and not FrontX and not FrontY then
		return if LocalCamZ >= 0 then 1 else 2
	end
	if FrontY and not FrontX and not FrontZ then
		return if LocalCamY >= 0 then 4 else 3
	end
	if FrontX and not FrontY and not FrontZ then
		return if LocalCamX >= 0 then 6 else 5
	end
	if MaxImpostorPixels <= 0 then
		return 7
	end

	const ClampedX = if OverhangX > 0 then OverhangX else 0 :: number
	const ClampedY = if OverhangY > 0 then OverhangY else 0 :: number
	const ClampedZ = if OverhangZ > 0 then OverhangZ else 0 :: number
	const ClosestDistSq = ClampedX * ClampedX + ClampedY * ClampedY + ClampedZ * ClampedZ :: number
	if ClosestDistSq <= NEAR_CLIP_SQ then
		return 7
	end

	const InvDistSq = 1 / ClosestDistSq :: number
	const FocalOverDist = FocalLength * math.sqrt(InvDistSq) :: number
	const FocalOverDistSq = FocalLength * InvDistSq :: number

	const ThicknessX = if FrontX then math.min(math.min(SizeY, SizeZ) * FocalOverDist, ClampedX * math.max(SizeY, SizeZ) * FocalOverDistSq) else 0 :: number
	const ThicknessY = if FrontY then math.min(math.min(SizeX, SizeZ) * FocalOverDist, ClampedY * math.max(SizeX, SizeZ) * FocalOverDistSq) else 0 :: number
	const ThicknessZ = if FrontZ then math.min(math.min(SizeX, SizeY) * FocalOverDist, ClampedZ * math.max(SizeX, SizeY) * FocalOverDistSq) else 0 :: number

	const SigCount = (if ThicknessX > MaxImpostorPixels then 1 else 0)
		+ (if ThicknessY > MaxImpostorPixels then 1 else 0)
		+ (if ThicknessZ > MaxImpostorPixels then 1 else 0) :: number
	if SigCount >= 2 then
		return 7
	end

	if ThicknessZ >= ThicknessX and ThicknessZ >= ThicknessY and FrontZ then
		return if LocalCamZ >= 0 then 1 else 2
	end
	if ThicknessY >= ThicknessX and ThicknessY >= ThicknessZ and FrontY then
		return if LocalCamY >= 0 then 4 else 3
	end
	return if LocalCamX >= 0 then 6 else 5
end

--[=[
	Writes only the 4 camera-space quad corners of a single visible Cube face into ScreenVertices[0..36]
	in the exact winding and UV order of VerticeHelper.BuildCubeMesh.
	@param Mode number -- Plane impostor face mode (1..6).
	@param ScreenVertices buffer -- Destination camera-space vertex buffer.
	@param Center vector -- Camera-space OBB center.
	@param RightAxis vector -- Scaled camera-space Right half-axis.
	@param UpAxis vector -- Scaled camera-space Up half-axis.
	@param LookAxis vector -- Scaled camera-space Look half-axis.
]=]
function CubeImpostorMath.WriteImpostorQuadVertices(
	Mode: number, ScreenVertices: buffer,
	Center: vector, RightAxis: vector, UpAxis: vector, LookAxis: vector
)
	if Mode == 1 then
		const FaceCenter = Center + LookAxis
		BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter - RightAxis - UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter - RightAxis + UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter + RightAxis + UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter + RightAxis - UpAxis)
		return
	end
	if Mode == 2 then
		const FaceCenter = Center - LookAxis
		BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter - RightAxis - UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter + RightAxis - UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter + RightAxis + UpAxis)
		BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter - RightAxis + UpAxis)
		return
	end
	if Mode == 3 then
		const FaceCenter = Center - UpAxis
		BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter - RightAxis + LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter + RightAxis + LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter + RightAxis - LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter - RightAxis - LookAxis)
		return
	end
	if Mode == 4 then
		const FaceCenter = Center + UpAxis
		BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter + RightAxis + LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter - RightAxis + LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter - RightAxis - LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter + RightAxis - LookAxis)
		return
	end
	if Mode == 5 then
		const FaceCenter = Center - RightAxis
		BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter - UpAxis + LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter - UpAxis - LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter + UpAxis - LookAxis)
		BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter + UpAxis + LookAxis)
		return
	end
	const FaceCenter = Center + RightAxis
	BufferHelper.WriteVec3(ScreenVertices, 0, FaceCenter - UpAxis + LookAxis)
	BufferHelper.WriteVec3(ScreenVertices, 12, FaceCenter + UpAxis + LookAxis)
	BufferHelper.WriteVec3(ScreenVertices, 24, FaceCenter + UpAxis - LookAxis)
	BufferHelper.WriteVec3(ScreenVertices, 36, FaceCenter - UpAxis - LookAxis)
end

--[=[
	Returns the directional sun dot product and UV tile scales for a Cube-to-Plane impostor mode (1..6).
	@param Mode number -- Plane impostor face mode (1..6).
	@param LocalSun vector -- Sun direction in the Cube's local basis.
	@param TileScaleX number -- X-axis UV repeat count.
	@param TileScaleY number -- Y-axis UV repeat count.
	@param TileScaleZ number -- Z-axis UV repeat count.
	@return (number, number, number) -- (DiffuseDot, ScaleU, ScaleV).
]=]
function CubeImpostorMath.GetImpostorShadingAndUV(
	Mode: number, LocalSun: vector, TileScaleX: number, TileScaleY: number, TileScaleZ: number
): (number, number, number)
	if Mode == 1 then
		return math.max(0, LocalSun.z), TileScaleX, TileScaleY
	end
	if Mode == 2 then
		return math.max(0, -LocalSun.z), TileScaleX, TileScaleY
	end
	if Mode == 3 then
		return math.max(0, -LocalSun.y), TileScaleX, TileScaleZ
	end
	if Mode == 4 then
		return math.max(0, LocalSun.y), TileScaleX, TileScaleZ
	end
	if Mode == 5 then
		return math.max(0, -LocalSun.x), TileScaleZ, TileScaleY
	end
	return math.max(0, LocalSun.x), TileScaleZ, TileScaleY
end

--[=[
	Frustum-tests a Cube OBB and transforms either 4 camera-space vertices (when collapsible to a Plane
	impostor, Mode 1..6) or all 8 camera-space vertices (when multiple faces are visible, Mode 7).
	@param PositionBuffer buffer -- Entity position component buffer.
	@param DirectionsBuffer buffer -- Entity basis directions buffer.
	@param SizeBuffer buffer -- Entity size component buffer.
	@param ComponentOffset number -- Byte offset in position/size buffers.
	@param DirectionOffset number -- Byte offset in directions buffer.
	@param ScreenVertices buffer -- Destination camera-space vertex buffer.
	@param CamPos vector -- Camera world position.
	@param CamRight vector -- Camera RightVector.
	@param CamUp vector -- Camera UpVector.
	@param CamLook vector -- Camera LookVector.
	@param SunVec vector -- Normalized world-space sun direction.
	@param FocalLength number -- Camera focal length in pixels.
	@param MaxImpostorPixels number -- Maximum side-face pixel thickness for Plane impostor collapse.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@return (number, vector, vector, vector) -- (Mode, LocalCameraPos, HalfSize, LocalSun).
]=]
function CubeImpostorMath.TransformCubeOrPlaneImpostor(
	PositionBuffer: buffer, DirectionsBuffer: buffer, SizeBuffer: buffer,
	ComponentOffset: number, DirectionOffset: number, ScreenVertices: buffer,
	CamPos: vector, CamRight: vector, CamUp: vector, CamLook: vector, SunVec: vector,
	FocalLength: number, MaxImpostorPixels: number, GuardBandX: number, GuardBandY: number
): (number, vector, vector, vector)
	const PartPosition = BufferHelper.ReadVec3(PositionBuffer, ComponentOffset)
	const FullSize = BufferHelper.ReadVec3(SizeBuffer, ComponentOffset)
	const HalfSize = FullSize * 0.5
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
		return 0, vector.zero, vector.zero, vector.zero
	end

	const CameraSpaceCenter = vector.create(vector.dot(RelativePosition, CamRight), vector.dot(RelativePosition, CamUp), CameraSpaceCenterZ)
	const CameraSpaceRightAxis = vector.create(vector.dot(WorldRightAxis, CamRight), vector.dot(WorldRightAxis, CamUp), RightAxisCameraZ)
	const CameraSpaceUpAxis = vector.create(vector.dot(WorldUpAxis, CamRight), vector.dot(WorldUpAxis, CamUp), UpAxisCameraZ)
	const CameraSpaceLookAxis = vector.create(vector.dot(WorldLookAxis, CamRight), vector.dot(WorldLookAxis, CamUp), LookAxisCameraZ)

	const MaxDepth = math.max(CameraSpaceCenterZ + CameraSpaceExtentZ, NEAR_CLIP) :: number
	const ExtentX = math.abs(CameraSpaceRightAxis.X) + math.abs(CameraSpaceUpAxis.X) + math.abs(CameraSpaceLookAxis.X) :: number
	const HalfFrustumX = MaxDepth * GuardBandX :: number
	if CameraSpaceCenter.X + ExtentX < -HalfFrustumX or CameraSpaceCenter.X - ExtentX > HalfFrustumX then
		return 0, vector.zero, vector.zero, vector.zero
	end

	const ExtentY = math.abs(CameraSpaceRightAxis.Y) + math.abs(CameraSpaceUpAxis.Y) + math.abs(CameraSpaceLookAxis.Y) :: number
	const HalfFrustumY = MaxDepth * GuardBandY :: number
	if CameraSpaceCenter.Y + ExtentY < -HalfFrustumY or CameraSpaceCenter.Y - ExtentY > HalfFrustumY then
		return 0, vector.zero, vector.zero, vector.zero
	end

	const LocalCamX = -vector.dot(RelativePosition, RightAxis) :: number
	const LocalCamY = -vector.dot(RelativePosition, UpAxis) :: number
	const LocalCamZ = -vector.dot(RelativePosition, LookAxis) :: number
	const Mode = CubeImpostorMath.SelectCubeRenderMode(
		LocalCamX, LocalCamY, LocalCamZ, FullSize.x, FullSize.y, FullSize.z, FocalLength, MaxImpostorPixels
	)
	if Mode == 0 then
		return 0, vector.zero, vector.zero, vector.zero
	end

	const LocalCameraPos = vector.create(LocalCamX, LocalCamY, LocalCamZ)
	const LocalSun = vector.create(vector.dot(RightAxis, SunVec), vector.dot(UpAxis, SunVec), vector.dot(LookAxis, SunVec))

	if Mode <= 6 then
		CubeImpostorMath.WriteImpostorQuadVertices(
			Mode, ScreenVertices, CameraSpaceCenter, CameraSpaceRightAxis, CameraSpaceUpAxis, CameraSpaceLookAxis
		)
		return Mode, LocalCameraPos, HalfSize, LocalSun
	end

	const PlusZ = CameraSpaceCenter + CameraSpaceLookAxis
	const MinusZ = CameraSpaceCenter - CameraSpaceLookAxis
	const RightPlusUp = CameraSpaceRightAxis + CameraSpaceUpAxis
	const RightMinusUp = CameraSpaceRightAxis - CameraSpaceUpAxis
	BufferHelper.WriteVec3(ScreenVertices, 0, PlusZ - RightPlusUp)
	BufferHelper.WriteVec3(ScreenVertices, 12, PlusZ + RightMinusUp)
	BufferHelper.WriteVec3(ScreenVertices, 24, PlusZ + RightPlusUp)
	BufferHelper.WriteVec3(ScreenVertices, 36, PlusZ - RightMinusUp)
	BufferHelper.WriteVec3(ScreenVertices, 48, MinusZ - RightPlusUp)
	BufferHelper.WriteVec3(ScreenVertices, 60, MinusZ + RightMinusUp)
	BufferHelper.WriteVec3(ScreenVertices, 72, MinusZ + RightPlusUp)
	BufferHelper.WriteVec3(ScreenVertices, 84, MinusZ - RightMinusUp)

	return 7, LocalCameraPos, HalfSize, LocalSun
end

return CubeImpostorMath
