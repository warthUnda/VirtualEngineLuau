--!strict
--!native
--!optimize 2

--[=[
	@class RenderEntityStageHelper
	Entity gather and dual-stream (32B untextured / 64B textured) triangle staging helper,
	runnable both on raw component buffer slices inside parallel Worker Actors and synchronously
	on ECSStorage for isolated unit tests. Uses Cube fast-path and single-projection AllInside path.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const VerticeFile = require(RenderRoot:WaitForChild("Core"):WaitForChild("VerticeFile"))
const RenderMath = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderMath"))
const RenderControllerHelper = require(script.Parent:WaitForChild("RenderControllerHelper"))
const RenderCubeStageHelper = require(script.Parent:WaitForChild("RenderCubeStageHelper"))

-- Configs --
const SUN_DIRECTION = SystemsConfigs.SunDirection :: Vector3
const SUN_VEC = vector.create(SUN_DIRECTION.X, SUN_DIRECTION.Y, SUN_DIRECTION.Z)
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number
const ECS_COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const ECS_DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const ECS_VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const ECS_PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const TEXTURE_STUDS_PER_TILE = SystemsConfigs.TextureStudsPerTile :: number
const INV_TEXTURE_STUDS_PER_TILE = if TEXTURE_STUDS_PER_TILE > 0 then 1 / TEXTURE_STUDS_PER_TILE else 0 :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number
const UNTEXTURED_STRIDE = (SystemsConfigs.UntexturedBufferLayoutSize or 32) :: number
const TEXTURED_STRIDE = (SystemsConfigs.RenderBufferLayoutSize or 64) :: number

-- Buffers
const ProjectedShapeVerts = buffer.create(VerticeFile.MaxShapeVertices * 12) :: buffer

-- Tables --
local RenderEntityStageHelper = {}

-- Functions --
-- ============================================================================
-- 1. DUAL-STREAM PARALLEL-READY ENTITY SLICE STAGING & ECS STORAGE FACADE
-- ============================================================================

--[=[
	Transforms and stages a contiguous slice of entities `[0 .. EntityCount - 1]` from raw ECS component
	buffers into dual 32-byte untextured and 64-byte textured triangle buffers.
	@return (number, number) -- (UntexTriangleCount, TexTriangleCount).
]=]
function RenderEntityStageHelper.StageEntitySlice(
	EntityCount: number,
	PosBuf: buffer,
	SizeBuf: buffer,
	DirBuf: buffer,
	VisBuf: buffer,
	PropBuf: buffer,
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	UntexTris: buffer,
	UntexBounds: buffer,
	MaxUntex: number,
	TexTris: buffer,
	TexBounds: buffer,
	MaxTex: number,
	RowWorkDiff: buffer,
	CamPosVec: vector,
	CamRightVec: vector,
	CamUpVec: vector,
	CamLookVec: vector,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	ViewportWidth: number,
	ViewportHeight: number,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): (number, number)
	const HalfW = ViewportWidth * 0.5 :: number
	const HalfH = ViewportHeight * 0.5 :: number
	const MaxW = ViewportWidth - 1 :: number
	const MaxH = ViewportHeight - 1 :: number
	const ShapeTable = VerticeFile.ShapeData
	const DefaultShape = ShapeTable[0]
	const StageCube = RenderCubeStageHelper.StageCubeDual
	const EmitQuad = RenderCubeStageHelper.EmitProjectedQuadDual
	const SubmitDual = RenderControllerHelper.SubmitFaceDual
	const TransformShape = RenderMath.TransformShapeCameraVertices

	local UntexCount = 0 :: number
	local TexCount = 0 :: number

	for idx = 0, EntityCount - 1 do
		const PropReg = buffer.readu32(PropBuf, idx * ECS_PROPERTIES_STRIDE) :: number
		if not bit32.btest(PropReg, FLAG_IS_VISIBLE) then
			continue
		end

		const CompOff = idx * ECS_COMPONENT_STRIDE :: number
		const DirOff = idx * ECS_DIRECTION_STRIDE :: number
		const ShapeId = bit32.band(bit32.rshift(PropReg, 13), 7) :: number
		const TextureId = bit32.band(bit32.rshift(PropReg, 5), 255) :: number
		const VisOff = idx * ECS_VISUAL_STRIDE :: number
		const PartR = if TextureId == 0 then buffer.readu8(VisBuf, VisOff) else 255 :: number
		const PartG = if TextureId == 0 then buffer.readu8(VisBuf, VisOff + 1) else 255 :: number
		const PartB = if TextureId == 0 then buffer.readu8(VisBuf, VisOff + 2) else 255 :: number

		const HasTiling = TextureId > 0 and INV_TEXTURE_STUDS_PER_TILE > 0
		const TileX = if HasTiling then math.clamp(math.floor(buffer.readf32(SizeBuf, CompOff) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileY = if HasTiling then math.clamp(math.floor(buffer.readf32(SizeBuf, CompOff + 4) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileZ = if HasTiling then math.clamp(math.floor(buffer.readf32(SizeBuf, CompOff + 8) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number

		if ShapeId == 0 then
			UntexCount, TexCount = StageCube(
				PosBuf, SizeBuf, DirBuf, CompOff, DirOff,
				PartR, PartG, PartB, TextureId, TileX, TileY, TileZ,
				CamPosVec, CamRightVec, CamUpVec, CamLookVec, SUN_VEC,
				FocalLength, GuardBandX, GuardBandY, PlaneLeft, PlaneRight, PlaneBottom, PlaneTop,
				ViewportWidth, ViewportHeight, HalfW, HalfH,
				ScreenVertices, ProjectedVertices, ClipBufferA, ClipBufferB,
				UntexTris, UntexBounds, UntexCount, MaxUntex,
				TexTris, TexBounds, TexCount, MaxTex, RowWorkDiff
			)
			continue
		end

		const ShapeMesh = ShapeTable[ShapeId] or DefaultShape
		const IsVisible: boolean, LocalCam: vector, HalfSize: vector, LocalSun: vector, AllInside: boolean =
			TransformShape(
				PosBuf, DirBuf, SizeBuf, CompOff, DirOff,
				ShapeMesh.LocalVertices, ShapeMesh.VertexCount, ScreenVertices,
				CamPosVec, CamRightVec, CamUpVec, CamLookVec, SUN_VEC, GuardBandX, GuardBandY
			)
		if not IsVisible then
			continue
		end

		if AllInside then
			-- Project every unique shape vertex ONCE instead of per-face
			for VIdx = 0, ShapeMesh.VertexCount - 1 do
				const VOff = VIdx * 12 :: number
				const IZ = 1 / buffer.readf32(ScreenVertices, VOff + 8) :: number
				const Sc = IZ * FocalLength :: number
				buffer.writef32(ProjectedShapeVerts, VOff, math.floor(buffer.readf32(ScreenVertices, VOff) * Sc + HalfW))
				buffer.writef32(ProjectedShapeVerts, VOff + 4, math.floor(-buffer.readf32(ScreenVertices, VOff + 4) * Sc + HalfH))
				buffer.writef32(ProjectedShapeVerts, VOff + 8, IZ)
			end
		end

		const IsUniform = ShapeMesh.IsAxisAligned or (math.abs(HalfSize.x - HalfSize.y) < 1e-4 and math.abs(HalfSize.y - HalfSize.z) < 1e-4) :: boolean
		const InvHalfSize = if not IsUniform then vector.create(if HalfSize.x > 1e-4 then 1 / HalfSize.x else 1, if HalfSize.y > 1e-4 then 1 / HalfSize.y else 1, if HalfSize.z > 1e-4 then 1 / HalfSize.z else 1) else vector.zero
		const Faces = ShapeMesh.Faces
		const FaceCount = #Faces :: number

		for f = 1, FaceCount do
			const Face = Faces[f]
			const TestNormal = if IsUniform then Face.Normal else Face.Normal * InvHalfSize
			if vector.dot(LocalCam - Face.PointOnFace * HalfSize, TestNormal) <= -1e-3 then
				continue
			end

			const UnitNormal = if IsUniform then Face.Normal else vector.normalize(TestNormal)
			const Illum = AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, vector.dot(UnitNormal, LocalSun)) :: number
			const Color = bit32.bor(math.floor(PartR * Illum), bit32.lshift(math.floor(PartG * Illum), 8), bit32.lshift(math.floor(PartB * Illum), 16), 0xFF000000) :: number
			const ScaleU = if Face.UAxisIndex == 1 then TileX elseif Face.UAxisIndex == 2 then TileY else TileZ :: number
			const ScaleV = if Face.VAxisIndex == 1 then TileX elseif Face.VAxisIndex == 2 then TileY else TileZ :: number

			if AllInside then
				const O0, O1, O2, O3 = Face.V0ByteOffset, Face.V1ByteOffset, Face.V2ByteOffset, Face.V3ByteOffset
				const X0, Y0, IZ0 = buffer.readf32(ProjectedShapeVerts, O0), buffer.readf32(ProjectedShapeVerts, O0 + 4), buffer.readf32(ProjectedShapeVerts, O0 + 8)
				const X1, Y1, IZ1 = buffer.readf32(ProjectedShapeVerts, O1), buffer.readf32(ProjectedShapeVerts, O1 + 4), buffer.readf32(ProjectedShapeVerts, O1 + 8)
				const X2, Y2, IZ2 = buffer.readf32(ProjectedShapeVerts, O2), buffer.readf32(ProjectedShapeVerts, O2 + 4), buffer.readf32(ProjectedShapeVerts, O2 + 8)
				if O3 >= 0 then
					const X3, Y3, IZ3 = buffer.readf32(ProjectedShapeVerts, O3), buffer.readf32(ProjectedShapeVerts, O3 + 4), buffer.readf32(ProjectedShapeVerts, O3 + 8)
					UntexCount, TexCount = EmitQuad(
						X0, Y0, IZ0, X1, Y1, IZ1, X2, Y2, IZ2, X3, Y3, IZ3,
						ScaleU, ScaleV, Color, TextureId, ViewportWidth, ViewportHeight,
						UntexTris, UntexBounds, UntexCount, MaxUntex, TexTris, TexBounds, TexCount, MaxTex, RowWorkDiff
					)
				else
					const Area = (X2 - X0) * (Y1 - Y0) - (Y2 - Y0) * (X1 - X0) :: number
					if Area > MIN_TRIANGLE_AREA then
						const MinX, MaxX = math.max(0, math.min(X0, X1, X2)), math.min(MaxW, math.max(X0, X1, X2))
						const MinY, MaxY = math.max(0, math.min(Y0, Y1, Y2)), math.min(MaxH, math.max(Y0, Y1, Y2))
						if MinX <= MaxX and MinY <= MaxY then
							const InvA = 1 / Area :: number
							const SZ0, SZ1, SZ2 = IZ0 * InvA, IZ1 * InvA, IZ2 * InvA
							const HalfSpan = (MaxX - MinX + 1) * 0.5 :: number
							if TextureId == 0 then
								if UntexCount < MaxUntex then
									const Off = UntexCount * UNTEXTURED_STRIDE :: number
									buffer.writei16(UntexTris, Off, X0); buffer.writei16(UntexTris, Off + 2, Y0); buffer.writef32(UntexTris, Off + 4, SZ0)
									buffer.writei16(UntexTris, Off + 8, X1); buffer.writei16(UntexTris, Off + 10, Y1); buffer.writef32(UntexTris, Off + 12, SZ1)
									buffer.writei16(UntexTris, Off + 16, X2); buffer.writei16(UntexTris, Off + 18, Y2); buffer.writef32(UntexTris, Off + 20, SZ2)
									buffer.writeu32(UntexTris, Off + 24, Color)
									const BOff = UntexCount * 4 :: number
									buffer.writeu16(UntexBounds, BOff, MinY); buffer.writeu16(UntexBounds, BOff + 2, MaxY)
									const Cost = math.floor(HalfSpan + 28) :: number
									const SOff, EOff = MinY * 4, (MaxY + 1) * 4
									buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
									buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
									UntexCount += 1
								end
							elseif TexCount < MaxTex then
								const Off = TexCount * TEXTURED_STRIDE :: number
								buffer.writei16(TexTris, Off, X0); buffer.writei16(TexTris, Off + 2, Y0); buffer.writef32(TexTris, Off + 4, SZ0); buffer.writef32(TexTris, Off + 8, 0); buffer.writef32(TexTris, Off + 12, SZ0 * ScaleV)
								buffer.writei16(TexTris, Off + 16, X1); buffer.writei16(TexTris, Off + 18, Y1); buffer.writef32(TexTris, Off + 20, SZ1); buffer.writef32(TexTris, Off + 24, 0); buffer.writef32(TexTris, Off + 28, 0)
								buffer.writei16(TexTris, Off + 32, X2); buffer.writei16(TexTris, Off + 34, Y2); buffer.writef32(TexTris, Off + 36, SZ2); buffer.writef32(TexTris, Off + 40, SZ2 * ScaleU); buffer.writef32(TexTris, Off + 44, SZ2 * ScaleV)
								buffer.writeu32(TexTris, Off + 48, Color); buffer.writeu32(TexTris, Off + 52, TextureId)
								const BOff = TexCount * 4 :: number
								buffer.writeu16(TexBounds, BOff, MinY); buffer.writeu16(TexBounds, BOff + 2, MaxY)
								const Cost = math.floor(HalfSpan * 2 + 20) :: number
								const SOff, EOff = MinY * 4, (MaxY + 1) * 4
								buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
								buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
								TexCount += 1
							end
						end
					end
				end
			else
				UntexCount, TexCount = SubmitDual(
					ScreenVertices, ProjectedVertices, ClipBufferA, ClipBufferB,
					UntexTris, UntexBounds, UntexCount, MaxUntex,
					TexTris, TexBounds, TexCount, MaxTex, RowWorkDiff,
					Face.V0ByteOffset, Face.V1ByteOffset, Face.V2ByteOffset, Face.V3ByteOffset,
					ScaleU, ScaleV, Color, TextureId, FocalLength, GuardBandX, GuardBandY,
					ViewportWidth, ViewportHeight, PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
				)
			end
		end
	end

	return UntexCount, TexCount
end

--[=[
	Convenience wrapper staging all entities in an ECSStorage synchronously into dual 32B/64B buffers.
	@return (number, number) -- (UntexTriangleCount, TexTriangleCount).
]=]
function RenderEntityStageHelper.StageEntitiesDual(
	Storage: ECSMain.ECSStorage,
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	UntexTris: buffer,
	UntexBounds: buffer,
	MaxUntex: number,
	TexTris: buffer,
	TexBounds: buffer,
	MaxTex: number,
	RowWorkDiff: buffer,
	CamPosVec: vector,
	CamRightVec: vector,
	CamUpVec: vector,
	CamLookVec: vector,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	ViewportWidth: number,
	ViewportHeight: number,
	PlaneLeft: vector?,
	PlaneRight: vector?,
	PlaneBottom: vector?,
	PlaneTop: vector?
): (number, number)
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if EntityCount <= 0 then
		return 0, 0
	end
	return RenderEntityStageHelper.StageEntitySlice(
		EntityCount,
		Storage.PositionData.GetData(),
		Storage.SizeData.GetData(),
		Storage.DirectionsData.GetData(),
		Storage.VisualData.GetData(),
		Storage.PropertiesData.GetData(),
		ScreenVertices, ProjectedVertices, ClipBufferA, ClipBufferB,
		UntexTris, UntexBounds, MaxUntex, TexTris, TexBounds, MaxTex, RowWorkDiff,
		CamPosVec, CamRightVec, CamUpVec, CamLookVec,
		FocalLength, GuardBandX, GuardBandY, ViewportWidth, ViewportHeight,
		PlaneLeft, PlaneRight, PlaneBottom, PlaneTop
	)
end

return RenderEntityStageHelper
