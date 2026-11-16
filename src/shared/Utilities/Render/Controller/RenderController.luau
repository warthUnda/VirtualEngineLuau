--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const AssetService = game:GetService("AssetService")

-- Static References --
const Player = Players.LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const VerticeFile = require(ReplicatedStorage.Shared.Utilities.Render.Core.VerticeFile)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)
const RenderControllerHelper = require(script.Parent.RenderControllerHelper)
const WorkerPartitionHelper = require(script.Parent.WorkerPartitionHelper)

const CameraStore = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraStore")
)

const CameraService = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraService")
)

-- Storage --
-- The controller renders from the active Render ECSStorage populated by RendererCleaner.
const ECSStorage = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("ECSStorage")
)
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
const SCRIPTABLE_CAMERA_PARK_POSITION = SystemsConfigs.ScriptableCameraParkPosition :: Vector3
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string

const ECS_COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const ECS_DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const ECS_VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const ECS_PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const BAND_HEIGHT = math.ceil(HEIGHT / ACTOR_COUNT) :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const TEXTURE_STUDS_PER_TILE = SystemsConfigs.TextureStudsPerTile :: number
const INV_TEXTURE_STUDS_PER_TILE = if TEXTURE_STUDS_PER_TILE > 0 then 1 / TEXTURE_STUDS_PER_TILE else 0 :: number
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const TEXTURE_SYNC_REMOTE_EVENT_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string
const RENDER_TARGET_FPS = SystemsConfigs.RenderTargetFPS :: number
const RENDER_FRAME_INTERVAL = if RENDER_TARGET_FPS > 0 then 1 / RENDER_TARGET_FPS else 0 :: number
const FRAME_IN_FLIGHT_TIMEOUT = 0.25 :: number

-- Tables --
local Initialized = false :: boolean
local Received = 0 :: number
local ExpectedWorkers = 0 :: number
local CurrentFrame = 0 :: number
local FrameInFlight = false :: boolean
local LastDispatchClock = 0 :: number
local RenderAccumulator = 0 :: number
local PendingTextureSyncFrames = 0 :: number
local LoadedTextureBuffers: { [number]: buffer }? = nil

local WorkerActors = {} :: { Actor }
local WorkerOffsets = table.create(ACTOR_COUNT, 0) :: { number }
local BandStarts = table.create(ACTOR_COUNT, 0) :: { number }
local BandEnds = table.create(ACTOR_COUNT, 0) :: { number }
local BufferTable = {} :: { buffer }

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
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
local ScreenVertices = buffer.create(VerticeFile.MaxShapeVertices * 12) :: buffer
local ProjectedVertices = buffer.create(12 * 20) :: buffer
local ClipBufferA = buffer.create(12 * 20) :: buffer
local ClipBufferB = buffer.create(12 * 20) :: buffer

local Renderer = {}

-- ============================================================================
-- 1. INITIALIZATION & WORKER MESSAGE LISTENER
-- ============================================================================

--[=[
	Initializes the client software renderer, worker scanline band ranges, EditableImage binding, and texture sync listener.
]=]
function Renderer.Init()
	if Initialized then
		return
	end

	const ScreenGui = PlayerGui:WaitForChild("ScreenGui") :: ScreenGui
	ScreenGui.ResetOnSpawn = false
	const ImageLabel = ScreenGui:WaitForChild("ImageLabel") :: ImageLabel
	const SelfActor = PlayerScripts:WaitForChild("Controller") :: Actor
	WorkerActors = (PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: any) :: { Actor }

	const WorkerPoolSize = math.max(ACTOR_COUNT, #WorkerActors) :: number
	for i = 1, WorkerPoolSize do
		BufferTable[i] = buffer.create(WORKER_BUFFER_CAPACITY)
		WorkerOffsets[i] = 0
		BandStarts[i] = 0
		BandEnds[i] = HEIGHT - 1
	end

	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const BandStartY = (i - 1) * BAND_HEIGHT :: number
		const BandEndY = math.min(i * BAND_HEIGHT - 1, HEIGHT - 1) :: number
		BandStarts[i] = BandStartY
		BandEnds[i] = BandEndY
		TargetActor:SendMessage("Set Band Range", BandStartY, BandEndY)
	end

	-- Connecting Editable image to ImageLabel --
	const EditableImage = AssetService:CreateEditableImage({ Size = IMAGE_SIZE }) :: EditableImage
	ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

	CameraService:SetCameraHost()
	CameraService:SetCameraView(DEFAULT_CAMERA_VIEW)

	-- Wait for the camera to initialize
	task.spawn(function()
		const ActiveCamera = workspace.CurrentCamera
		if ActiveCamera then
			-- Switch camera to scriptable so default controls don't override it
			ActiveCamera.CameraType = Enum.CameraType.Scriptable

			-- Set position: Y = -50000 (underground) or 50000 (sky)
			-- Looking straight ahead or down
			ActiveCamera.CFrame = CFrame.new(SCRIPTABLE_CAMERA_PARK_POSITION)
		end
	end)

	SelfActor:BindToMessage(
		"Return Render Calculations",
		function(
			WorkerPixelBuffer: buffer,
			FrameId: number,
			BandStartY: number,
			BandEndY: number,
			DirtyMinY: number,
			DirtyMaxY: number
		)
			if FrameId ~= CurrentFrame then -- ignore stale frames
				return
			end

			BufferHelper.CompositeWorkerBand(
				FinalPixel,
				WorkerPixelBuffer,
				WIDTH,
				BandStartY,
				BandEndY,
				DirtyMinY,
				DirtyMaxY,
				true
			)

			Received += 1

			-- If all workers have returned their data, write it to the image
			if Received >= ExpectedWorkers then
				EditableImage:WritePixelsBuffer(Vector2.zero, IMAGE_SIZE, FinalPixel)
				Received = 0
				FrameInFlight = false
			end
		end
	)

	-- Sync TextureTable entries from the server's public TextureTable hashmap and decode into 64x64 buffers
	const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
	const TextureSyncEvent = CoreEvents:WaitForChild(TEXTURE_SYNC_REMOTE_EVENT_NAME) :: RemoteEvent

	TextureSyncEvent.OnClientEvent:Connect(function(Entries: any)
		RenderControllerHelper.ApplySyncedTextures(Entries, function(UpdatedBuffers: { [number]: buffer })
			LoadedTextureBuffers = UpdatedBuffers
			PendingTextureSyncFrames = 3
		end)
	end)
	TextureSyncEvent:FireServer()

	LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
	PendingTextureSyncFrames = 3

	Initialized = true
end

-- ============================================================================
-- 2. GATHER DATA - DYNAMICALLY PARTITION & SEND DATA TO WORKERS
-- ============================================================================

--[=[
	Gathers visible ECS entities, stages clipped faces, dynamically balances worker scanline bands, and dispatches rasterization at RenderTargetFPS.
	@param DeltaTime number -- Elapsed client frame delta time in seconds.
	@return boolean -- True when a render frame was dispatched, or false when throttled or in-flight.
]=]
function Renderer.DrawFrame(DeltaTime: number): boolean
	if not Initialized then
		Renderer.Init()
	end

	const NowClock = os.clock() :: number
	const IsFrameBlocked = FrameInFlight and (NowClock - LastDispatchClock) < FRAME_IN_FLIGHT_TIMEOUT :: boolean

	if CurrentFrame > 0 then
		local ShouldDraw = false :: boolean
		ShouldDraw, RenderAccumulator = RenderControllerHelper.StepFrameAccumulator(
			RenderAccumulator,
			DeltaTime,
			RENDER_FRAME_INTERVAL,
			IsFrameBlocked
		)
		if not ShouldDraw then
			return false
		end
	elseif IsFrameBlocked then
		return false
	end

	-- Active Entity Count --
	local EntityCount = ECSData.GetCounts().EntityECSCount :: number

	const CamTable = CameraStore.GetCameraTable()

	const CamPosition = CameraStore.GetCameraPosition() :: Vector3
	const CamRight = CameraStore.GetCameraRight() :: Vector3
	const CamUp = CameraStore.GetCameraUp() :: Vector3
	const CamLook = CameraStore.GetCameraLook() :: Vector3

	const CamPosVec = vector.create(CamPosition.X, CamPosition.Y, CamPosition.Z)
	const CamRightVec = vector.create(CamRight.X, CamRight.Y, CamRight.Z)
	const CamUpVec = vector.create(CamUp.X, CamUp.Y, CamUp.Z)
	const CamLookVec = vector.create(CamLook.X, CamLook.Y, CamLook.Z)

	-- Projection Parameters --
	const CamFOV = CamTable.CameraFOV :: number
	const FocalLength: number, GuardBandX: number, GuardBandY: number =
		RenderMath.GetProjectionParameters(CamFOV, WIDTH, HEIGHT)

	-- Pre-Loop State Reset --
	CurrentFrame += 1
	Received = 0
	ExpectedWorkers = #WorkerActors
	if ExpectedWorkers > 0 then
		FrameInFlight = true
		LastDispatchClock = NowClock
	else
		FrameInFlight = false
	end

	if PendingTextureSyncFrames > 0 and LoadedTextureBuffers then
		PendingTextureSyncFrames -= 1
		for _, TargetActor: Actor in ipairs(WorkerActors) do
			TargetActor:SendMessage(
				"Set Texture Table",
				LoadedTextureBuffers :: { [number]: buffer },
				TEXTURE_SIZE,
				TEXTURE_SIZE
			)
		end
	end

	const ActiveWorkerCount = if ExpectedWorkers > 0 then ExpectedWorkers else ACTOR_COUNT :: number
	for i = 1, ActiveWorkerCount do
		WorkerOffsets[i] = 0
		if not BufferTable[i] then
			BufferTable[i] = buffer.create(WORKER_BUFFER_CAPACITY)
		end
	end

	local StagedTriangleCount = 0 :: number

	-- Loop through all parts
	for i = 1, EntityCount do
		const ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		const DirectionOffset = (i - 1) * ECS_DIRECTION_STRIDE :: number
		const VisualOffset = (i - 1) * ECS_VISUAL_STRIDE :: number
		const PropertiesOffset = (i - 1) * ECS_PROPERTIES_STRIDE :: number

		const PropertiesRegister = buffer.readu32(ECSPropertiesBuffer, PropertiesOffset) :: number
		if not ECSMain.IsEntityVisible(PropertiesRegister) then
			continue
		end

		const EntityShapeId = ECSMain.GetEntityShapeId(PropertiesRegister) :: number
		const EntityTextureId = ECSMain.GetEntityTextureId(PropertiesRegister) :: number
		const ShapeMesh = VerticeFile.ShapeData[EntityShapeId] or VerticeFile.ShapeData[0]

		-- If untextured (EntityTextureId == 0), shade with the part's color; if textured, use white base so the decal's colors are preserved
		local PartColorR = 255 :: number
		local PartColorG = 255 :: number
		local PartColorB = 255 :: number
		if EntityTextureId == 0 then
			PartColorR = buffer.readu8(ECSVisualBuffer, VisualOffset) :: number
			PartColorG = buffer.readu8(ECSVisualBuffer, VisualOffset + 1) :: number
			PartColorB = buffer.readu8(ECSVisualBuffer, VisualOffset + 2) :: number
		end

		local TileScaleX = 1 :: number
		local TileScaleY = 1 :: number
		local TileScaleZ = 1 :: number
		if EntityTextureId > 0 and INV_TEXTURE_STUDS_PER_TILE > 0 then
			TileScaleX = math.clamp(
				math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset) * INV_TEXTURE_STUDS_PER_TILE + 0.5),
				1,
				8
			)
			TileScaleY = math.clamp(
				math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 4) * INV_TEXTURE_STUDS_PER_TILE + 0.5),
				1,
				8
			)
			TileScaleZ = math.clamp(
				math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 8) * INV_TEXTURE_STUDS_PER_TILE + 0.5),
				1,
				8
			)
		end

		const IsVisible: boolean, LocalCameraPos: vector, HalfSize: vector, LocalSun: vector =
			RenderMath.TransformShapeCameraVertices(
				ECSPositionBuffer,
				ECSDirectionsBuffer,
				ECSSizeBuffer,
				ComponentOffset,
				DirectionOffset,
				ShapeMesh.LocalVertices,
				ShapeMesh.VertexCount,
				ScreenVertices,
				CamPosVec,
				CamRightVec,
				CamUpVec,
				CamLookVec,
				SUN_VEC,
				GuardBandX,
				GuardBandY
			)

		if not IsVisible then
			continue
		end

		if ShapeMesh.IsAxisAligned then
			for _, Face in ipairs(ShapeMesh.Faces) do
				const ScaledPoint = Face.PointOnFace * HalfSize
				if vector.dot(LocalCameraPos - ScaledPoint, Face.Normal) <= -1e-3 then
					continue
				end

				const FaceSunDot = vector.dot(Face.Normal, LocalSun) :: number
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, FaceSunDot)
				)
				const ScaleU = if Face.UAxisIndex == 1
					then TileScaleX
					elseif Face.UAxisIndex == 2 then TileScaleY
					else TileScaleZ
				const ScaleV = if Face.VAxisIndex == 1
					then TileScaleX
					elseif Face.VAxisIndex == 2 then TileScaleY
					else TileScaleZ

				StagedTriangleCount = RenderControllerHelper.SubmitFace(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					StagedTriangles,
					StagedBounds,
					StagedTriangleCount,
					STAGED_TRIANGLE_CAPACITY,
					RowWorkDiff,
					Face.V0ByteOffset,
					Face.V1ByteOffset,
					Face.V2ByteOffset,
					Face.V3ByteOffset,
					ScaleU,
					ScaleV,
					Color,
					EntityTextureId,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			end
		else
			const IsUniformScale = math.abs(HalfSize.x - HalfSize.y) < 1e-4
				and math.abs(HalfSize.y - HalfSize.z) < 1e-4 :: boolean
			const InvHalfSize = if not IsUniformScale
				then vector.create(
					if HalfSize.x > 1e-4 then 1 / HalfSize.x else 1,
					if HalfSize.y > 1e-4 then 1 / HalfSize.y else 1,
					if HalfSize.z > 1e-4 then 1 / HalfSize.z else 1
				)
				else vector.zero

			for _, Face in ipairs(ShapeMesh.Faces) do
				const ScaledPoint = Face.PointOnFace * HalfSize
				const ScaledLocalNormal = if IsUniformScale then Face.Normal else Face.Normal * InvHalfSize
				if vector.dot(LocalCameraPos - ScaledPoint, ScaledLocalNormal) <= -1e-3 then
					continue
				end

				const WorldSpaceLocalNormal = if IsUniformScale
					then Face.Normal
					else vector.normalize(ScaledLocalNormal)
				const FaceSunDot = vector.dot(WorldSpaceLocalNormal, LocalSun) :: number
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, FaceSunDot)
				)
				const ScaleU = if Face.UAxisIndex == 1
					then TileScaleX
					elseif Face.UAxisIndex == 2 then TileScaleY
					else TileScaleZ
				const ScaleV = if Face.VAxisIndex == 1
					then TileScaleX
					elseif Face.VAxisIndex == 2 then TileScaleY
					else TileScaleZ

				StagedTriangleCount = RenderControllerHelper.SubmitFace(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					StagedTriangles,
					StagedBounds,
					StagedTriangleCount,
					STAGED_TRIANGLE_CAPACITY,
					RowWorkDiff,
					Face.V0ByteOffset,
					Face.V1ByteOffset,
					Face.V2ByteOffset,
					Face.V3ByteOffset,
					ScaleU,
					ScaleV,
					Color,
					EntityTextureId,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			end
		end
	end

	-- Dynamically partition scanline bands to equalize per-worker raster work and zero RowWorkDiff
	WorkerPartitionHelper.PartitionWorkerBands(
		RowWorkDiff,
		CumulativeWork,
		RowToWorker,
		HEIGHT,
		ActiveWorkerCount,
		BandStarts,
		BandEnds
	)

	if StagedTriangleCount > 0 and ExpectedWorkers > 0 then
		WorkerPartitionHelper.DispatchStagedTriangles(
			StagedTriangles,
			StagedBounds,
			StagedTriangleCount,
			RowToWorker,
			WorkerOffsets,
			BufferTable,
			WORKER_BUFFER_CAPACITY
		)
	end

	-- Sends compact triangle slices and dynamic band bounds to all workers
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const ByteCount = WorkerOffsets[i] :: number
		local PayloadBuffer = EmptyPayload :: buffer
		if ByteCount > 0 then
			if ByteCount < WORKER_BUFFER_CAPACITY then
				const CompactSlice = buffer.create(ByteCount) :: buffer
				buffer.copy(CompactSlice, 0, BufferTable[i], 0, ByteCount)
				PayloadBuffer = CompactSlice
			else
				PayloadBuffer = BufferTable[i]
			end
		end

		TargetActor:SendMessage(
			"Execute Rendering",
			PayloadBuffer,
			ByteCount,
			CurrentFrame,
			BandStarts[i],
			BandEnds[i]
		)
	end

	return true
end

Renderer.RenderFrame = Renderer.DrawFrame

return Renderer
