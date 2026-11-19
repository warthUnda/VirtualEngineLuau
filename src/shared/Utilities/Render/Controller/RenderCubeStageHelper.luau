--!strict
--!native
--!optimize 2

--[=[
	@class RenderCubeStageHelper
	Specialized fast path for Cube entities (ShapeId == 0): computes all 8 camera-space corners
	via pure add/sub vector tree (zero multiplies/loops), performs 6 scalar backface checks,
	projects each unique corner once when AllInside, and emits directly into dual 28B/56B buffers.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const RenderControllerHelper = require(script.Parent:WaitForChild("RenderControllerHelper"))
const RenderQuadEmitHelper = require(script.Parent:WaitForChild("RenderQuadEmitHelper"))

-- Configs --
const NEAR_CLIP = SystemsConfigs.RenderNearClip :: number
const FAR_CLIP = SystemsConfigs.RenderFarClip :: number
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number

-- Tables --
local RenderCubeStageHelper = {
	EmitProjectedQuadDual = RenderQuadEmitHelper.EmitProjectedQuadDual,
}

-- Functions --
-- ============================================================================
-- 1. CUBE FAST-PATH TRANSFORM, ALL-INSIDE SINGLE PROJECTION & DUAL STAGING
-- ============================================================================

--[=[
	Fast-path OBB transform, 6-face scalar backface cull, and dual-stream staging for Cube entities (ShapeId == 0).
]=]
function RenderCubeStageHelper.StageCubeDual(
	PosBuf: buffer, SizeBuf: buffer, DirBuf: buffer,
	CompOff: number, DirOff: number,
	PartR: number, PartG: number, PartB: number,
	TextureId: number, TileX: number, TileY: number, TileZ: number,
	CamPos: vector, CamRight: vector, CamUp: vector, CamLook: vector, SunVec: vector,
	Focal: number, GuardX: number, GuardY: number,
	PlaneL: vector?, PlaneR: vector?, PlaneB: vector?, PlaneT: vector?,
	Width: number, Height: number, HalfW: number, HalfH: number,
	ScreenVerts: buffer, ProjVerts: buffer, ClipA: buffer, ClipB: buffer,
	UntexTris: buffer, UntexBounds: buffer, UntexCount: number, MaxUntex: number,
	TexTris: buffer, TexBounds: buffer, TexCount: number, MaxTex: number,
	RowWorkDiff: buffer
): (number, number)
	const PartPos = vector.create(buffer.readf32(PosBuf, CompOff), buffer.readf32(PosBuf, CompOff + 4), buffer.readf32(PosBuf, CompOff + 8))
	const HX = buffer.readf32(SizeBuf, CompOff) * 0.5 :: number
	const HY = buffer.readf32(SizeBuf, CompOff + 4) * 0.5 :: number
	const HZ = buffer.readf32(SizeBuf, CompOff + 8) * 0.5 :: number
	const Rel = PartPos - CamPos
	const CenterZ = vector.dot(Rel, CamLook) :: number

	const LookA = vector.create(buffer.readf32(DirBuf, DirOff), buffer.readf32(DirBuf, DirOff + 4), buffer.readf32(DirBuf, DirOff + 8))
	const UpA = vector.create(buffer.readf32(DirBuf, DirOff + 12), buffer.readf32(DirBuf, DirOff + 16), buffer.readf32(DirBuf, DirOff + 20))
	const RightA = vector.create(buffer.readf32(DirBuf, DirOff + 24), buffer.readf32(DirBuf, DirOff + 28), buffer.readf32(DirBuf, DirOff + 32))

	const WR, WU, WL = RightA * HX, UpA * HY, LookA * HZ
	const RZ, UZ, LZ = vector.dot(WR, CamLook), vector.dot(WU, CamLook), vector.dot(WL, CamLook)
	const ExtZ = math.abs(RZ) + math.abs(UZ) + math.abs(LZ) :: number
	const MaxZ, MinZ = CenterZ + ExtZ, CenterZ - ExtZ
	if MaxZ < NEAR_CLIP or MinZ > FAR_CLIP then
		return UntexCount, TexCount
	end

	const CenterX, CenterY = vector.dot(Rel, CamRight), vector.dot(Rel, CamUp)
	const CamR = vector.create(vector.dot(WR, CamRight), vector.dot(WR, CamUp), RZ)
	const CamU = vector.create(vector.dot(WU, CamRight), vector.dot(WU, CamUp), UZ)
	const CamL = vector.create(vector.dot(WL, CamRight), vector.dot(WL, CamUp), LZ)

	const ClampedMaxZ = math.max(MaxZ, NEAR_CLIP) :: number
	const ExtX = math.abs(CamR.x) + math.abs(CamU.x) + math.abs(CamL.x) :: number
	const HalfFX = ClampedMaxZ * GuardX :: number
	if CenterX + ExtX < -HalfFX or CenterX - ExtX > HalfFX then
		return UntexCount, TexCount
	end
	const ExtY = math.abs(CamR.y) + math.abs(CamU.y) + math.abs(CamL.y) :: number
	const HalfFY = ClampedMaxZ * GuardY :: number
	if CenterY + ExtY < -HalfFY or CenterY - ExtY > HalfFY then
		return UntexCount, TexCount
	end

	const CamC = vector.create(CenterX, CenterY, CenterZ)
	const CM, CP = CamC - CamR, CamC + CamR
	const CMM, CMP, CPM, CPP = CM - CamU, CM + CamU, CP - CamU, CP + CamU
	const V1, V2, V3, V4 = CMM + CamL, CPM + CamL, CPP + CamL, CMP + CamL
	const V5, V6, V7, V8 = CMM - CamL, CPM - CamL, CPP - CamL, CMP - CamL

	const LCamX, LCamY, LCamZ = -vector.dot(Rel, RightA), -vector.dot(Rel, UpA), -vector.dot(Rel, LookA)
	const SunX, SunY, SunZ = vector.dot(RightA, SunVec), vector.dot(UpA, SunVec), vector.dot(LookA, SunVec)
	const AllInside = (
		MinZ >= NEAR_CLIP and MaxZ <= FAR_CLIP
		and (math.abs(CenterX) + ExtX) <= MinZ * GuardX
		and (math.abs(CenterY) + ExtY) <= MinZ * GuardY
	) :: boolean

	local NextUntex, NextTex = UntexCount, TexCount
	if AllInside then
		const IZ1 = 1 / V1.z; const S1 = IZ1 * Focal; const X1, Y1 = math.floor(V1.x * S1 + HalfW), math.floor(-V1.y * S1 + HalfH)
		const IZ2 = 1 / V2.z; const S2 = IZ2 * Focal; const X2, Y2 = math.floor(V2.x * S2 + HalfW), math.floor(-V2.y * S2 + HalfH)
		const IZ3 = 1 / V3.z; const S3 = IZ3 * Focal; const X3, Y3 = math.floor(V3.x * S3 + HalfW), math.floor(-V3.y * S3 + HalfH)
		const IZ4 = 1 / V4.z; const S4 = IZ4 * Focal; const X4, Y4 = math.floor(V4.x * S4 + HalfW), math.floor(-V4.y * S4 + HalfH)
		const IZ5 = 1 / V5.z; const S5 = IZ5 * Focal; const X5, Y5 = math.floor(V5.x * S5 + HalfW), math.floor(-V5.y * S5 + HalfH)
		const IZ6 = 1 / V6.z; const S6 = IZ6 * Focal; const X6, Y6 = math.floor(V6.x * S6 + HalfW), math.floor(-V6.y * S6 + HalfH)
		const IZ7 = 1 / V7.z; const S7 = IZ7 * Focal; const X7, Y7 = math.floor(V7.x * S7 + HalfW), math.floor(-V7.y * S7 + HalfH)
		const IZ8 = 1 / V8.z; const S8 = IZ8 * Focal; const X8, Y8 = math.floor(V8.x * S8 + HalfW), math.floor(-V8.y * S8 + HalfH)
		const EmitQuad = RenderQuadEmitHelper.EmitProjectedQuadDual

		if LCamZ > HZ - 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunZ)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X1, Y1, IZ1, X4, Y4, IZ4, X3, Y3, IZ3, X2, Y2, IZ2, TileX, TileY, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		elseif LCamZ < -HZ + 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunZ)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X5, Y5, IZ5, X6, Y6, IZ6, X7, Y7, IZ7, X8, Y8, IZ8, TileX, TileY, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		end
		if LCamY > HY - 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunY)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X3, Y3, IZ3, X4, Y4, IZ4, X8, Y8, IZ8, X7, Y7, IZ7, TileX, TileZ, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		elseif LCamY < -HY + 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunY)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X1, Y1, IZ1, X2, Y2, IZ2, X6, Y6, IZ6, X5, Y5, IZ5, TileX, TileZ, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		end
		if LCamX > HX - 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunX)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X2, Y2, IZ2, X3, Y3, IZ3, X7, Y7, IZ7, X6, Y6, IZ6, TileZ, TileY, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		elseif LCamX < -HX + 1e-3 then
			const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunX)
			const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
			NextUntex, NextTex = EmitQuad(X1, Y1, IZ1, X5, Y5, IZ5, X8, Y8, IZ8, X4, Y4, IZ4, TileZ, TileY, Col, TextureId, Width, Height, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff)
		end
		return NextUntex, NextTex
	end

	buffer.writef32(ScreenVerts, 0, V1.x); buffer.writef32(ScreenVerts, 4, V1.y); buffer.writef32(ScreenVerts, 8, V1.z)
	buffer.writef32(ScreenVerts, 12, V2.x); buffer.writef32(ScreenVerts, 16, V2.y); buffer.writef32(ScreenVerts, 20, V2.z)
	buffer.writef32(ScreenVerts, 24, V3.x); buffer.writef32(ScreenVerts, 28, V3.y); buffer.writef32(ScreenVerts, 32, V3.z)
	buffer.writef32(ScreenVerts, 36, V4.x); buffer.writef32(ScreenVerts, 40, V4.y); buffer.writef32(ScreenVerts, 44, V4.z)
	buffer.writef32(ScreenVerts, 48, V5.x); buffer.writef32(ScreenVerts, 52, V5.y); buffer.writef32(ScreenVerts, 56, V5.z)
	buffer.writef32(ScreenVerts, 60, V6.x); buffer.writef32(ScreenVerts, 64, V6.y); buffer.writef32(ScreenVerts, 68, V6.z)
	buffer.writef32(ScreenVerts, 72, V7.x); buffer.writef32(ScreenVerts, 76, V7.y); buffer.writef32(ScreenVerts, 80, V7.z)
	buffer.writef32(ScreenVerts, 84, V8.x); buffer.writef32(ScreenVerts, 88, V8.y); buffer.writef32(ScreenVerts, 92, V8.z)
	const SubmitDual = RenderControllerHelper.SubmitFaceDual

	if LCamZ > HZ - 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunZ)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 0, 36, 24, 12, TileX, TileY, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	elseif LCamZ < -HZ + 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunZ)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 48, 60, 72, 84, TileX, TileY, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	end
	if LCamY > HY - 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunY)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 24, 36, 84, 72, TileX, TileZ, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	elseif LCamY < -HY + 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunY)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 0, 12, 60, 48, TileX, TileZ, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	end
	if LCamX > HX - 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, SunX)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 12, 24, 72, 60, TileZ, TileY, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	elseif LCamX < -HX + 1e-3 then
		const L = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -SunX)
		const Col = bit32.bor(math.floor(PartR * L), bit32.lshift(math.floor(PartG * L), 8), bit32.lshift(math.floor(PartB * L), 16), 0xFF000000)
		NextUntex, NextTex = SubmitDual(ScreenVerts, ProjVerts, ClipA, ClipB, UntexTris, UntexBounds, NextUntex, MaxUntex, TexTris, TexBounds, NextTex, MaxTex, RowWorkDiff, 0, 48, 84, 36, TileZ, TileY, Col, TextureId, Focal, GuardX, GuardY, Width, Height, PlaneL, PlaneR, PlaneB, PlaneT)
	end

	return NextUntex, NextTex
end

return RenderCubeStageHelper
