--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const RenderRoot = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const VerticeFile = require(RenderRoot:WaitForChild("Core"):WaitForChild("VerticeFile"))
const RenderMath = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderMath"))
const BufferHelper = require(RenderRoot:WaitForChild("Core"):WaitForChild("BufferHelper"))
const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))
const CameraStore = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraStore"))
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderControllerHelper = require(script.Parent.RenderControllerHelper)
const WorkerPartitionHelper = require(script.Parent.WorkerPartitionHelper)
const RenderWorkerGateway = require(script.Parent.RenderWorkerGateway)

-- Storage --
const ECSStorage = require(RenderRoot:WaitForChild("ECSStorage"))
const ECSData = ECSStorage.ECSData
const PositionData = ECSStorage.PositionData
const SizeData = ECSStorage.SizeData
const DirectionsData = ECSStorage.DirectionsData
const VisualData = ECSStorage.VisualData
const PropertiesData = ECSStorage.PropertiesData

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const IMAGE_SIZE = Vector2.new(WIDTH, HEIGHT) :: Vector2
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const SUN_DIRECTION = SystemsConfigs.SunDirection :: Vector3
const SUN_VEC = vector.create(SUN_DIRECTION.X, SUN_DIRECTION.Y, SUN_DIRECTION.Z)
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const WORKER_BUFFER_CAPACITY = TOTAL_PIXELS * WORKER_BUFFER_MULTIPLIER :: number
const RENDER_BUFFER_LAYOUT_SIZE = BufferHelper.RenderBufferLayoutSize :: number
const STAGED_TRIANGLE_CAPACITY = (WORKER_BUFFER_CAPACITY * 2) // RENDER_BUFFER_LAYOUT_SIZE :: number
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string
const ECS_COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const ECS_DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const ECS_VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const ECS_PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const TEXTURE_STUDS_PER_TILE = SystemsConfigs.TextureStudsPerTile :: number
const INV_TEXTURE_STUDS_PER_TILE = if TEXTURE_STUDS_PER_TILE > 0 then 1 / TEXTURE_STUDS_PER_TILE else 0 :: number
const FRAME_IN_FLIGHT_TIMEOUT = 0.25 :: number

-- Variables --
local Initialized = false :: boolean
local Received = 0 :: number
local ExpectedWorkers = 0 :: number
local CurrentFrame = 0 :: number
local FrameInFlight = false :: boolean
local LastDispatchClock = 0 :: number
local PendingTextureSyncFrames = 0 :: number
local LoadedTextureBuffers: { [number]: buffer }? = nil

-- Tables --
local WorkerActors = {} :: { Actor }
local WorkerOffsets = table.create(ACTOR_COUNT, 0) :: { number }
local BandStarts = table.create(ACTOR_COUNT, 0) :: { number }
local BandEnds = table.create(ACTOR_COUNT, 0) :: { number }
local BufferTable = {} :: { buffer }
local Renderer = {}

-- Buffers
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ECSPositionBuffer = PositionData.GetData() :: buffer
const ECSSizeBuffer = SizeData.GetData() :: buffer
const ECSDirectionsBuffer = DirectionsData.GetData() :: buffer
const ECSVisualBuffer = VisualData.GetData() :: buffer
const ECSPropertiesBuffer = PropertiesData.GetData() :: buffer
const StagedTriangles = buffer.create(STAGED_TRIANGLE_CAPACITY * RENDER_BUFFER_LAYOUT_SIZE) :: buffer
const StagedBounds = buffer.create(STAGED_TRIANGLE_CAPACITY * 4) :: buffer
const RowWorkDiff = buffer.create((HEIGHT + 1) * 4) :: buffer
const CumulativeWork = buffer.create(HEIGHT * 4) :: buffer
const RowToWorker = buffer.create(HEIGHT) :: buffer
const ScreenVertices = buffer.create(VerticeFile.MaxShapeVertices * 12) :: buffer
const ProjectedVertices = buffer.create(12 * 20) :: buffer
const ClipBufferA = buffer.create(12 * 20) :: buffer
const ClipBufferB = buffer.create(12 * 20) :: buffer

-- Functions --
-- ============================================================================
-- 1. INITIALIZATION & ENTITY GATHER FACADE
-- ============================================================================

--[=[
	Initializes the client software renderer, worker gateway, camera view host, and texture cache sync.
]=]
function Renderer.Init()
	if Initialized then
		return
	end

	WorkerActors = RenderWorkerGateway.InitializeGateway(
		FinalPixel, BufferTable, WorkerOffsets, BandStarts, BandEnds,
		function(_FrameId: number, BoundImage: EditableImage)
			Received += 1
			if Received >= ExpectedWorkers then
				BoundImage:WritePixelsBuffer(Vector2.zero, IMAGE_SIZE, FinalPixel)
				Received = 0
				FrameInFlight = false
			end
		end,
		function(): number return CurrentFrame end,
		function(UpdatedBuffers: { [number]: buffer })
			LoadedTextureBuffers = UpdatedBuffers
			PendingTextureSyncFrames = 3
		end
	)

	CameraService:SetCameraHost()
	CameraService:SetCameraView(DEFAULT_CAMERA_VIEW)
	LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
	PendingTextureSyncFrames = 3
	Initialized = true
end

--[=[
	Gathers visible ECS entities, stages clipped faces, dynamically balances worker scanline bands, and dispatches rasterization.
	@return boolean -- True when a render frame was dispatched, or false when a previous frame is still in flight.
]=]
function Renderer.DrawFrame(): boolean
	if not Initialized then
		Renderer.Init()
	end

	const NowClock = os.clock() :: number
	if FrameInFlight and (NowClock - LastDispatchClock) < FRAME_IN_FLIGHT_TIMEOUT then
		return false
	end

	const EntityCount = ECSData.GetCounts().EntityECSCount :: number
	const CamTable = CameraStore.GetCameraTable()
	const CamPosition = CameraStore.GetCameraPosition() :: Vector3
	const CamRight = CameraStore.GetCameraRight() :: Vector3
	const CamUp = CameraStore.GetCameraUp() :: Vector3
	const CamLook = CameraStore.GetCameraLook() :: Vector3

	const CamPosVec = vector.create(CamPosition.X, CamPosition.Y, CamPosition.Z)
	const CamRightVec = vector.create(CamRight.X, CamRight.Y, CamRight.Z)
	const CamUpVec = vector.create(CamUp.X, CamUp.Y, CamUp.Z)
	const CamLookVec = vector.create(CamLook.X, CamLook.Y, CamLook.Z)
	const FocalLength: number, GuardBandX: number, GuardBandY: number =
		RenderMath.GetProjectionParameters(CamTable.CameraFOV :: number, WIDTH, HEIGHT)

	CurrentFrame += 1
	Received = 0
	ExpectedWorkers = #WorkerActors
	FrameInFlight = ExpectedWorkers > 0
	if FrameInFlight then
		LastDispatchClock = NowClock
	end

	if PendingTextureSyncFrames > 0 and LoadedTextureBuffers then
		PendingTextureSyncFrames -= 1
		RenderWorkerGateway.BroadcastTextures(WorkerActors, LoadedTextureBuffers :: { [number]: buffer })
	end

	const ActiveWorkerCount = if ExpectedWorkers > 0 then ExpectedWorkers else ACTOR_COUNT :: number
	for i = 1, ActiveWorkerCount do
		WorkerOffsets[i] = 0
		if not BufferTable[i] then
			BufferTable[i] = buffer.create(WORKER_BUFFER_CAPACITY)
		end
	end

	local StagedTriangleCount = 0 :: number
	for i = 1, EntityCount do
		const ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		const PropertiesRegister = buffer.readu32(ECSPropertiesBuffer, (i - 1) * ECS_PROPERTIES_STRIDE) :: number
		if not ECSMain.IsEntityVisible(PropertiesRegister) then
			continue
		end

		const EntityShapeId = ECSMain.GetEntityShapeId(PropertiesRegister) :: number
		const EntityTextureId = ECSMain.GetEntityTextureId(PropertiesRegister) :: number
		const ShapeMesh = VerticeFile.ShapeData[EntityShapeId] or VerticeFile.ShapeData[0]

		const IsVisible: boolean, LocalCameraPos: vector, HalfSize: vector, LocalSun: vector =
			RenderMath.TransformShapeCameraVertices(
				ECSPositionBuffer, ECSDirectionsBuffer, ECSSizeBuffer,
				ComponentOffset, (i - 1) * ECS_DIRECTION_STRIDE,
				ShapeMesh.LocalVertices, ShapeMesh.VertexCount, ScreenVertices,
				CamPosVec, CamRightVec, CamUpVec, CamLookVec,
				SUN_VEC, GuardBandX, GuardBandY
			)
		if not IsVisible then
			continue
		end

		const VisualOffset = (i - 1) * ECS_VISUAL_STRIDE :: number
		const PartColorR = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset) else 255 :: number
		const PartColorG = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset + 1) else 255 :: number
		const PartColorB = if EntityTextureId == 0 then buffer.readu8(ECSVisualBuffer, VisualOffset + 2) else 255 :: number

		const HasTiling = EntityTextureId > 0 and INV_TEXTURE_STUDS_PER_TILE > 0
		const TileScaleX = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileScaleY = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 4) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number
		const TileScaleZ = if HasTiling then math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 8) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8) else 1 :: number

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
				StagedTriangles, StagedBounds, StagedTriangleCount, STAGED_TRIANGLE_CAPACITY, RowWorkDiff,
				Face.V0ByteOffset, Face.V1ByteOffset, Face.V2ByteOffset, Face.V3ByteOffset,
				ScaleU, ScaleV, Color, EntityTextureId, FocalLength, GuardBandX, GuardBandY
			)
		end
	end

	WorkerPartitionHelper.PartitionWorkerBands(RowWorkDiff, CumulativeWork, RowToWorker, HEIGHT, ActiveWorkerCount, BandStarts, BandEnds)
	if StagedTriangleCount > 0 and ExpectedWorkers > 0 then
		WorkerPartitionHelper.DispatchStagedTriangles(
			StagedTriangles, StagedBounds, StagedTriangleCount, RowToWorker, WorkerOffsets, BufferTable, WORKER_BUFFER_CAPACITY
		)
	end
	RenderWorkerGateway.DispatchWorkerBatches(WorkerActors, BufferTable, WorkerOffsets, BandStarts, BandEnds, CurrentFrame)
	return true
end

Renderer.RenderFrame = Renderer.DrawFrame

return Renderer
