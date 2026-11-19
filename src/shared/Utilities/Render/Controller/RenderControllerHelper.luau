--!strict
--!native
--!optimize 2

--[=[
	@class RenderControllerHelper
	Helper module for RenderService/RenderController providing camera/guardband-plane caching,
	color shading, and dual-stream (32B untextured / 64B textured) polygon clipping & face staging.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const HALF_WIDTH = WIDTH * 0.5 :: number
const HALF_HEIGHT = HEIGHT * 0.5 :: number
const UNTEXTURED_STRIDE = (SystemsConfigs.UntexturedBufferLayoutSize or 32) :: number
const TEXTURED_STRIDE = (SystemsConfigs.RenderBufferLayoutSize or 64) :: number
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number

-- Tables --
local RenderControllerHelper = {}

-- Functions --
-- ============================================================================
-- 1. DIRECTION READING, COLOR SHADING & DUAL-STREAM FACE STAGING
-- ============================================================================

--[=[
	Reads a 3-component float direction vector from the directions buffer into a SIMD vector.
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
	Clips a face polygon using outcode-masked frustum clipping and stages resulting triangles directly
	into either the 32-byte untextured stream or the 64-byte textured stream with inline RowWorkDiff updates.
	@return (number, number) -- Updated (UntexCount, TexCount).
]=]
function RenderControllerHelper.SubmitFaceDual(
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	UntexTris: buffer,
	UntexBounds: buffer,
	UntexCount: number,
	MaxUntex: number,
	TexTris: buffer,
	TexBounds: buffer,
	TexCount: number,
	MaxTex: number,
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
	GuardBandY: number,
	ViewportWidth: number?,
	ViewportHeight: number?,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): (number, number)
	if TextureId == 0 and UntexCount >= MaxUntex then
		return UntexCount, TexCount
	end
	if TextureId > 0 and TexCount >= MaxTex then
		return UntexCount, TexCount
	end

	const ActiveWidth = (ViewportWidth or WIDTH) :: number
	const ActiveHeight = (ViewportHeight or HEIGHT) :: number
	const ActiveHalfWidth = if ViewportWidth then ViewportWidth * 0.5 else HALF_WIDTH :: number
	const ActiveHalfHeight = if ViewportHeight then ViewportHeight * 0.5 else HALF_HEIGHT :: number

	const ClippedVertexCount = if V3ByteOffset >= 0
		then RenderMath.ClipAndProjectQuad(
			ScreenVertices, V0ByteOffset, V1ByteOffset, V2ByteOffset, V3ByteOffset,
			ScaleU, ScaleV, ProjectedVertices, ClipBufferA, ClipBufferB,
			FocalLength, GuardBandX, GuardBandY, ActiveHalfWidth, ActiveHalfHeight,
			PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
		)
		else RenderMath.ClipAndProjectTriangleUV(
			ScreenVertices, V0ByteOffset, V1ByteOffset, V2ByteOffset,
			ScaleU, ScaleV, ProjectedVertices, ClipBufferA, ClipBufferB,
			FocalLength, GuardBandX, GuardBandY, ActiveHalfWidth, ActiveHalfHeight,
			PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
		) :: number

	if ClippedVertexCount < 3 then
		return UntexCount, TexCount
	end

	const MaxW = ActiveWidth - 1 :: number
	const MaxH = ActiveHeight - 1 :: number
	const V0X = buffer.readf32(ProjectedVertices, 0) :: number
	const V0Y = buffer.readf32(ProjectedVertices, 4) :: number
	const IZ0 = buffer.readf32(ProjectedVertices, 8) :: number
	local NextUntex = UntexCount :: number
	local NextTex = TexCount :: number

	if TextureId == 0 then
		for TriIdx = 2, ClippedVertexCount - 1 do
			if NextUntex >= MaxUntex then
				break
			end
			const V1Off = (TriIdx - 1) * 24 :: number
			const V2Off = V1Off + 24 :: number
			const V1X = buffer.readf32(ProjectedVertices, V1Off) :: number
			const V1Y = buffer.readf32(ProjectedVertices, V1Off + 4) :: number
			const V2X = buffer.readf32(ProjectedVertices, V2Off) :: number
			const V2Y = buffer.readf32(ProjectedVertices, V2Off + 4) :: number

			const Area = (V2X - V0X) * (V1Y - V0Y) - (V2Y - V0Y) * (V1X - V0X) :: number
			if Area <= MIN_TRIANGLE_AREA then
				continue
			end
			const MinX = math.max(0, math.min(V0X, V1X, V2X)) :: number
			const MaxX = math.min(MaxW, math.max(V0X, V1X, V2X)) :: number
			const MinY = math.max(0, math.min(V0Y, V1Y, V2Y)) :: number
			const MaxY = math.min(MaxH, math.max(V0Y, V1Y, V2Y)) :: number
			if MinX > MaxX or MinY > MaxY then
				continue
			end

			const InvA = 1 / Area :: number
			const Off = NextUntex * UNTEXTURED_STRIDE :: number
			buffer.writei16(UntexTris, Off, V0X); buffer.writei16(UntexTris, Off + 2, V0Y); buffer.writef32(UntexTris, Off + 4, IZ0 * InvA)
			buffer.writei16(UntexTris, Off + 8, V1X); buffer.writei16(UntexTris, Off + 10, V1Y); buffer.writef32(UntexTris, Off + 12, buffer.readf32(ProjectedVertices, V1Off + 8) * InvA)
			buffer.writei16(UntexTris, Off + 16, V2X); buffer.writei16(UntexTris, Off + 18, V2Y); buffer.writef32(UntexTris, Off + 20, buffer.readf32(ProjectedVertices, V2Off + 8) * InvA)
			buffer.writeu32(UntexTris, Off + 24, PackedColor)

			const BOff = NextUntex * 4 :: number
			buffer.writeu16(UntexBounds, BOff, MinY); buffer.writeu16(UntexBounds, BOff + 2, MaxY)
			const Cost = math.floor((MaxX - MinX + 1) * 0.5 + 28) :: number
			const SOff, EOff = MinY * 4, (MaxY + 1) * 4
			buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
			buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
			NextUntex += 1
		end
		return NextUntex, NextTex
	end

	const U0 = buffer.readf32(ProjectedVertices, 12) :: number
	const V0 = buffer.readf32(ProjectedVertices, 16) :: number
	for TriIdx = 2, ClippedVertexCount - 1 do
		if NextTex >= MaxTex then
			break
		end
		const V1Off = (TriIdx - 1) * 24 :: number
		const V2Off = V1Off + 24 :: number
		const V1X = buffer.readf32(ProjectedVertices, V1Off) :: number
		const V1Y = buffer.readf32(ProjectedVertices, V1Off + 4) :: number
		const V2X = buffer.readf32(ProjectedVertices, V2Off) :: number
		const V2Y = buffer.readf32(ProjectedVertices, V2Off + 4) :: number

		const Area = (V2X - V0X) * (V1Y - V0Y) - (V2Y - V0Y) * (V1X - V0X) :: number
		if Area <= MIN_TRIANGLE_AREA then
			continue
		end
		const MinX = math.max(0, math.min(V0X, V1X, V2X)) :: number
		const MaxX = math.min(MaxW, math.max(V0X, V1X, V2X)) :: number
		const MinY = math.max(0, math.min(V0Y, V1Y, V2Y)) :: number
		const MaxY = math.min(MaxH, math.max(V0Y, V1Y, V2Y)) :: number
		if MinX > MaxX or MinY > MaxY then
			continue
		end

		const InvA = 1 / Area :: number
		const SZ0 = IZ0 * InvA :: number
		const SZ1 = buffer.readf32(ProjectedVertices, V1Off + 8) * InvA :: number
		const SZ2 = buffer.readf32(ProjectedVertices, V2Off + 8) * InvA :: number
		const Off = NextTex * TEXTURED_STRIDE :: number
		buffer.writei16(TexTris, Off, V0X); buffer.writei16(TexTris, Off + 2, V0Y); buffer.writef32(TexTris, Off + 4, SZ0); buffer.writef32(TexTris, Off + 8, SZ0 * U0); buffer.writef32(TexTris, Off + 12, SZ0 * V0)
		buffer.writei16(TexTris, Off + 16, V1X); buffer.writei16(TexTris, Off + 18, V1Y); buffer.writef32(TexTris, Off + 20, SZ1); buffer.writef32(TexTris, Off + 24, SZ1 * buffer.readf32(ProjectedVertices, V1Off + 12)); buffer.writef32(TexTris, Off + 28, SZ1 * buffer.readf32(ProjectedVertices, V1Off + 16))
		buffer.writei16(TexTris, Off + 32, V2X); buffer.writei16(TexTris, Off + 34, V2Y); buffer.writef32(TexTris, Off + 36, SZ2); buffer.writef32(TexTris, Off + 40, SZ2 * buffer.readf32(ProjectedVertices, V2Off + 12)); buffer.writef32(TexTris, Off + 44, SZ2 * buffer.readf32(ProjectedVertices, V2Off + 16))
		buffer.writeu32(TexTris, Off + 48, PackedColor); buffer.writeu32(TexTris, Off + 52, TextureId)

		const BOff = NextTex * 4 :: number
		buffer.writeu16(TexBounds, BOff, MinY); buffer.writeu16(TexBounds, BOff + 2, MaxY)
		const Cost = math.floor((MaxX - MinX + 1) + 20) :: number
		const SOff, EOff = MinY * 4, (MaxY + 1) * 4
		buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
		buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
		NextTex += 1
	end

	return NextUntex, NextTex
end

--[=[
	Updates cached camera basis SIMD vectors, projection scalars, and precomputed guardband clip plane vectors.
]=]
function RenderControllerHelper.SyncCameraCache(
	RendererObj: any,
	CamCF: CFrame,
	CamFOV: number,
	Width: number,
	Height: number
)
	if CamCF ~= RendererObj.CachedCameraCFrame then
		const Pos = CamCF.Position :: Vector3
		const Right = CamCF.RightVector :: Vector3
		const Up = CamCF.UpVector :: Vector3
		const Look = CamCF.LookVector :: Vector3
		RendererObj.CachedCameraCFrame = CamCF
		RendererObj.CachedCameraPosVec = vector.create(Pos.X, Pos.Y, Pos.Z)
		RendererObj.CachedCameraRightVec = vector.create(Right.X, Right.Y, Right.Z)
		RendererObj.CachedCameraUpVec = vector.create(Up.X, Up.Y, Up.Z)
		RendererObj.CachedCameraLookVec = vector.create(Look.X, Look.Y, Look.Z)
	end

	if
		CamFOV ~= RendererObj.CachedCameraFOV
		or Width ~= RendererObj.CachedProjWidth
		or Height ~= RendererObj.CachedProjHeight
	then
		const Focal: number, GuardX: number, GuardY: number =
			RenderMath.GetProjectionParameters(CamFOV, Width, Height)
		RendererObj.CachedFocalLength = Focal
		RendererObj.CachedGuardBandX = GuardX
		RendererObj.CachedGuardBandY = GuardY
		RendererObj.CachedPlaneLeft = vector.create(1, 0, GuardX)
		RendererObj.CachedPlaneRight = vector.create(-1, 0, GuardX)
		RendererObj.CachedPlaneBottom = vector.create(0, 1, GuardY)
		RendererObj.CachedPlaneTop = vector.create(0, -1, GuardY)
		RendererObj.CachedCameraFOV = CamFOV
		RendererObj.CachedProjWidth = Width
		RendererObj.CachedProjHeight = Height
	end
end

return RenderControllerHelper
