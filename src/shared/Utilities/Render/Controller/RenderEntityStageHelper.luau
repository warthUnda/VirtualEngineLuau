--!strict
--!native
--!optimize 2

--[=[
	@class RenderEntityStageHelper
	Per-frame ECS entity gather and face-staging helper for RenderService.
	Transforms visible entity OBBs into camera space, runs per-face backface culling,
	and stages clipped screen-space triangles for parallel rasterization.
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

-- Tables --
local RenderEntityStageHelper = {}

-- Functions --
-- ============================================================================
-- 1. ENTITY GATHER & MESH FACE STAGING
-- ============================================================================

--[=[
	Transforms and stages all visible entities in Storage into StagedTriangles.
	@param Storage ECSMain.ECSStorage -- Active render ECS storage.
	@param ScreenVertices buffer -- Scratch camera-space vertex buffer.
	@param ProjectedVertices buffer -- Scratch projected 2D vertex buffer.
	@param ClipBufferA buffer -- Primary polygon clipping scratch buffer.
	@param ClipBufferB buffer -- Secondary polygon clipping scratch buffer.
	@param StagedTriangles buffer -- Output staged 56-byte triangle buffer.
	@param StagedBounds buffer -- Output 4-byte scanline bounds buffer.
	@param StagedCapacity number -- Maximum triangle count in StagedTriangles.
	@param RowWorkDiff buffer -- Scanline row work difference buffer.
	@param CamPosVec vector -- Camera world position SIMD vector.
	@param CamRightVec vector -- Camera RightVector SIMD vector.
	@param CamUpVec vector -- Camera UpVector SIMD vector.
	@param CamLookVec vector -- Camera LookVector SIMD vector.
	@param FocalLength number -- Camera focal length in pixels.
	@param GuardBandX number -- Horizontal guardband slope factor.
	@param GuardBandY number -- Vertical guardband slope factor.
	@return number -- Total staged triangle count for the frame.
]=]
function RenderEntityStageHelper.StageEntities(
	Storage: ECSMain.ECSStorage,
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	StagedTriangles: buffer,
	StagedBounds: buffer,
	StagedCapacity: number,
	RowWorkDiff: buffer,
	CamPosVec: vector,
	CamRightVec: vector,
	CamUpVec: vector,
	CamLookVec: vector,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	ViewportWidth: number?,
	ViewportHeight: number?
): number
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const ECSPositionBuffer = Storage.PositionData.GetData() :: buffer
	const ECSSizeBuffer = Storage.SizeData.GetData() :: buffer
	const ECSDirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const ECSVisualBuffer = Storage.VisualData.GetData() :: buffer
	const ECSPropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	local StagedTriangleCount = 0 :: number
	for i = 1, EntityCount do
		const PropertiesRegister = buffer.readu32(ECSPropertiesBuffer, (i - 1) * ECS_PROPERTIES_STRIDE) :: number
		if not ECSMain.IsEntityVisible(PropertiesRegister) then
			continue
		end

		const ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		const DirectionOffset = (i - 1) * ECS_DIRECTION_STRIDE :: number
		const EntityShapeId = ECSMain.GetEntityShapeId(PropertiesRegister) :: number
		const EntityTextureId = ECSMain.GetEntityTextureId(PropertiesRegister) :: number
		const VisualOffset = (i - 1) * ECS_VISUAL_STRIDE :: number
		const PartColorR = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset) else 255 :: number
		const PartColorG = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset + 1) else 255 :: number
		const PartColorB = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset + 2) else 255 :: number

		const HasTiling = EntityTextureId > 0 and INV_TEXTURE_STUDS_PER_TILE > 0
		const TileScaleX = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileScaleY = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 4) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileScaleZ = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 8) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number

		const ShapeMesh = VerticeFile.ShapeData[EntityShapeId] or VerticeFile.ShapeData[0]
		const IsVisible: boolean, LocalCameraPos: vector, HalfSize: vector, LocalSun: vector =
			RenderMath.TransformShapeCameraVertices(
				ECSPositionBuffer, ECSDirectionsBuffer, ECSSizeBuffer,
				ComponentOffset, DirectionOffset,
				ShapeMesh.LocalVertices, ShapeMesh.VertexCount, ScreenVertices,
				CamPosVec, CamRightVec, CamUpVec, CamLookVec,
				SUN_VEC, GuardBandX, GuardBandY
			)
		if not IsVisible then
			continue
		end

		const IsUniform = ShapeMesh.IsAxisAligned or (math.abs(HalfSize.x - HalfSize.y) < 1e-4 and math.abs(HalfSize.y - HalfSize.z) < 1e-4) :: boolean
		const InvHalfSize = if not IsUniform then vector.create(if HalfSize.x > 1e-4 then 1 / HalfSize.x else 1, if HalfSize.y > 1e-4 then 1 / HalfSize.y else 1, if HalfSize.z > 1e-4 then 1 / HalfSize.z else 1) else vector.zero

		for _, Face in ipairs(ShapeMesh.Faces) do
			const TestNormal = if IsUniform then Face.Normal else Face.Normal * InvHalfSize
			if vector.dot(LocalCameraPos - Face.PointOnFace * HalfSize, TestNormal) <= -1e-3 then
				continue
			end

			const UnitNormal = if IsUniform then Face.Normal else vector.normalize(TestNormal)
			const Color = RenderControllerHelper.PackShadedColor(
				PartColorR, PartColorG, PartColorB,
				AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, vector.dot(UnitNormal, LocalSun))
			)
			const ScaleU = if Face.UAxisIndex == 1 then TileScaleX elseif Face.UAxisIndex == 2 then TileScaleY else TileScaleZ
			const ScaleV = if Face.VAxisIndex == 1 then TileScaleX elseif Face.VAxisIndex == 2 then TileScaleY else TileScaleZ

			StagedTriangleCount = RenderControllerHelper.SubmitFace(
				ScreenVertices, ProjectedVertices, ClipBufferA, ClipBufferB,
				StagedTriangles, StagedBounds, StagedTriangleCount, StagedCapacity, RowWorkDiff,
				Face.V0ByteOffset, Face.V1ByteOffset, Face.V2ByteOffset, Face.V3ByteOffset,
				ScaleU, ScaleV, Color, EntityTextureId, FocalLength, GuardBandX, GuardBandY,
				ViewportWidth, ViewportHeight
			)
		end
	end

	return StagedTriangleCount
end

return RenderEntityStageHelper
