--!strict
--!native
--!optimize 2

--[=[
	@class RenderInstanceMethods
	Instance methods for OOP RenderService objects, orchestrating self-created ScreenGui
	initialization, entity transformation, dynamic worker partitioning, and frame rendering.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")
const ControllerFolder = RenderRoot:WaitForChild("Controller")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const VerticeFile = require(RenderRoot:WaitForChild("Core"):WaitForChild("VerticeFile"))
const RenderMath = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderMath"))
const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderControllerHelper = require(ControllerFolder:WaitForChild("RenderControllerHelper"))
const WorkerPartitionHelper = require(ControllerFolder:WaitForChild("WorkerPartitionHelper"))
const RenderWorkerGateway = require(ControllerFolder:WaitForChild("RenderWorkerGateway"))

-- Configs --
const SUN_DIRECTION = SystemsConfigs.SunDirection :: Vector3
const SUN_VEC = vector.create(SUN_DIRECTION.X, SUN_DIRECTION.Y, SUN_DIRECTION.Z)
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string
const ECS_COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const ECS_DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const ECS_VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const ECS_PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const TEXTURE_STUDS_PER_TILE = SystemsConfigs.TextureStudsPerTile :: number
const INV_TEXTURE_STUDS_PER_TILE = if TEXTURE_STUDS_PER_TILE > 0 then 1 / TEXTURE_STUDS_PER_TILE else 0 :: number
const FRAME_IN_FLIGHT_TIMEOUT = 0.25 :: number

-- Tables --
local RenderInstanceMethods = {}

-- Functions --
-- ============================================================================
-- 1. OOP RENDER SERVICE INSTANCE METHODS
-- ============================================================================

--[=[
	Creates the renderer's own ScreenGui/ImageLabel/EditableImage, initializes workers, and activates its CameraObject.
	@param self any -- Target OOP RenderObject instance.
	@param TargetParent Instance? -- Optional GUI parent container (defaults to LocalPlayer.PlayerGui).
	@param BindWorkers boolean? -- Optional worker Actor bind toggle (defaults to true).
]=]
function RenderInstanceMethods.Init(self: any, TargetParent: Instance?, BindWorkers: boolean?)
	if self.Initialized then
		return
	end

	const ShouldBindWorkers = (BindWorkers ~= false) :: boolean
	const Width = self.Width :: number
	const Height = self.Height :: number
	const ImageSize = self.ImageSize :: Vector2
	const FinalPixel = self.FinalPixel :: buffer

	const ScreenGui, ImageLabel, EditableImg =
		RenderWorkerGateway.CreateDisplayGui(TargetParent, Width, Height, self.GuiName :: string)
	self.ScreenGui = ScreenGui
	self.ImageLabel = ImageLabel
	self.EditableImage = EditableImg

	self.WorkerActors = RenderWorkerGateway.InitializeWorkers(
		Width,
		Height,
		self.WorkerBufferCapacity :: number,
		FinalPixel,
		self.BufferTable,
		self.WorkerOffsets,
		self.BandStarts,
		self.BandEnds,
		EditableImg,
		ShouldBindWorkers,
		function(_FrameId: number, BoundImage: EditableImage)
			self.Received += 1
			if self.Received >= self.ExpectedWorkers then
				BoundImage:WritePixelsBuffer(Vector2.zero, ImageSize, FinalPixel)
				self.Received = 0
				self.FrameInFlight = false
			end
		end,
		function(): number
			return self.CurrentFrame :: number
		end
	)

	if ShouldBindWorkers then
		const BoundCamera = self.Camera :: CameraService.CameraObject
		BoundCamera:SetCameraHost(nil)
		BoundCamera:SetCameraView(DEFAULT_CAMERA_VIEW)
	end

	self.LastTextureVersion = TextureTable.GetVersion()
	self.LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
	self.PendingTextureSyncFrames = 3
	self.Initialized = true
end

--[=[
	Gathers visible entities using the OOP camera's per-frame cached vectors and dispatches worker scanline bands.
	@param self any -- Target OOP RenderObject instance.
	@return boolean -- True when a frame was dispatched; false if the previous frame is still in flight.
]=]
function RenderInstanceMethods.DrawFrame(self: any): boolean
	if not self.Initialized then
		RenderInstanceMethods.Init(self, nil, true)
	end

	const NowClock = os.clock() :: number
	if self.FrameInFlight and (NowClock - (self.LastDispatchClock :: number)) < FRAME_IN_FLIGHT_TIMEOUT then
		return false
	end

	const Storage = self.Storage :: ECSMain.ECSStorage
	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const ECSPositionBuffer = Storage.PositionData.GetData() :: buffer
	const ECSSizeBuffer = Storage.SizeData.GetData() :: buffer
	const ECSDirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const ECSVisualBuffer = Storage.VisualData.GetData() :: buffer
	const ECSPropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	const BoundCamera = self.Camera :: CameraService.CameraObject
	const Width = self.Width :: number
	const Height = self.Height :: number
	RenderControllerHelper.SyncCameraCache(
		self,
		BoundCamera.CameraCFrame :: CFrame,
		BoundCamera.CameraFOV :: number,
		Width,
		Height
	)
	const CamPosVec = self.CachedCameraPosVec :: vector
	const CamRightVec = self.CachedCameraRightVec :: vector
	const CamUpVec = self.CachedCameraUpVec :: vector
	const CamLookVec = self.CachedCameraLookVec :: vector
	const FocalLength = self.CachedFocalLength :: number
	const GuardBandX = self.CachedGuardBandX :: number
	const GuardBandY = self.CachedGuardBandY :: number

	const WorkerActors = self.WorkerActors :: { Actor }
	const ExpectedWorkers = #WorkerActors :: number
	self.CurrentFrame = (self.CurrentFrame :: number) + 1
	self.Received = 0
	self.ExpectedWorkers = ExpectedWorkers
	self.FrameInFlight = ExpectedWorkers > 0
	if ExpectedWorkers > 0 then
		self.LastDispatchClock = NowClock
	end

	const CurrentTextureVersion = TextureTable.GetVersion() :: number
	if CurrentTextureVersion ~= self.LastTextureVersion then
		self.LastTextureVersion = CurrentTextureVersion
		self.LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
		self.PendingTextureSyncFrames = 3
	end
	if (self.PendingTextureSyncFrames :: number) > 0 and self.LoadedTextureBuffers then
		self.PendingTextureSyncFrames = (self.PendingTextureSyncFrames :: number) - 1
		RenderWorkerGateway.BroadcastTextures(WorkerActors, self.LoadedTextureBuffers :: { [number]: buffer })
	end

	const WorkerOffsets = self.WorkerOffsets :: { number }
	const BufferTable = self.BufferTable :: { buffer }
	const WorkerCapacity = self.WorkerBufferCapacity :: number
	const ActiveWorkerCount = if ExpectedWorkers > 0 then ExpectedWorkers else ACTOR_COUNT :: number
	for i = 1, ActiveWorkerCount do
		WorkerOffsets[i] = 0
		if not BufferTable[i] then
			BufferTable[i] = buffer.create(WorkerCapacity)
		end
	end

	const ScreenVertices = self.ScreenVertices :: buffer
	const ProjectedVertices = self.ProjectedVertices :: buffer
	const ClipBufferA = self.ClipBufferA :: buffer
	const ClipBufferB = self.ClipBufferB :: buffer
	const StagedTriangles = self.StagedTriangles :: buffer
	const StagedBounds = self.StagedBounds :: buffer
	const RowWorkDiff = self.RowWorkDiff :: buffer
	const StagedCapacity = self.StagedTriangleCapacity :: number

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
				StagedTriangles, StagedBounds, StagedTriangleCount, StagedCapacity, RowWorkDiff,
				Face.V0ByteOffset, Face.V1ByteOffset, Face.V2ByteOffset, Face.V3ByteOffset,
				ScaleU, ScaleV, Color, EntityTextureId, FocalLength, GuardBandX, GuardBandY
			)
		end
	end

	const BandStarts = self.BandStarts :: { number }
	const BandEnds = self.BandEnds :: { number }
	WorkerPartitionHelper.PartitionWorkerBands(RowWorkDiff, self.CumulativeWork, self.RowToWorker, Height, ActiveWorkerCount, BandStarts, BandEnds)
	if StagedTriangleCount > 0 and ExpectedWorkers > 0 then
		WorkerPartitionHelper.DispatchStagedTriangles(
			StagedTriangles, StagedBounds, StagedTriangleCount, self.RowToWorker, WorkerOffsets, BufferTable, WorkerCapacity
		)
	end
	RenderWorkerGateway.DispatchWorkerBatches(WorkerActors, BufferTable, WorkerOffsets, WorkerCapacity, BandStarts, BandEnds, self.CurrentFrame)
	return true
end

--[=[
	Binds a custom OOP CameraObject to this RenderObject instance.
	@param self any -- Target OOP RenderObject instance.
	@param CameraObj CameraService.CameraObject -- Target CameraObject to render from.
]=]
function RenderInstanceMethods.SetCamera(self: any, CameraObj: CameraService.CameraObject)
	self.Camera = CameraObj
	self.CachedCameraCFrame = nil
	self.CachedCameraFOV = -1
end

--[=[
	Replaces the ECSStorage container used by this RenderObject instance.
	@param self any -- Target OOP RenderObject instance.
	@param Storage ECSMain.ECSStorage -- Target ECS storage container.
]=]
function RenderInstanceMethods.SetStorage(self: any, Storage: ECSMain.ECSStorage)
	self.Storage = Storage
end

--[=[
	Enables or disables the self-created ScreenGui owned by this RenderObject instance.
	@param self any -- Target OOP RenderObject instance.
	@param Enabled boolean -- Visibility toggle state.
]=]
function RenderInstanceMethods.SetEnabled(self: any, Enabled: boolean)
	const Gui = self.ScreenGui :: ScreenGui?
	if Gui then
		Gui.Enabled = Enabled
	end
end

--[=[
	Returns the self-created ScreenGui owned by this RenderObject instance (or nil if uninitialized).
	@param self any -- Target OOP RenderObject instance.
	@return ScreenGui? -- Owned ScreenGui instance.
]=]
function RenderInstanceMethods.GetScreenGui(self: any): ScreenGui?
	return self.ScreenGui
end

--[=[
	Returns the full-screen ImageLabel owned by this RenderObject instance (or nil if uninitialized).
	@param self any -- Target OOP RenderObject instance.
	@return ImageLabel? -- Owned ImageLabel instance.
]=]
function RenderInstanceMethods.GetImageLabel(self: any): ImageLabel?
	return self.ImageLabel
end

--[=[
	Returns the bound EditableImage receiving composited pixels for this RenderObject (or nil if uninitialized).
	@param self any -- Target OOP RenderObject instance.
	@return EditableImage? -- Owned EditableImage instance.
]=]
function RenderInstanceMethods.GetEditableImage(self: any): EditableImage?
	return self.EditableImage
end

--[=[
	Destroys the renderer's self-created ScreenGui and EditableImage resources.
	@param self any -- Target OOP RenderObject instance.
]=]
function RenderInstanceMethods.Destroy(self: any)
	self.Initialized = false
	self.FrameInFlight = false
	if self.ScreenGui then
		self.ScreenGui:Destroy()
		self.ScreenGui = nil
		self.ImageLabel = nil
	end
	if self.EditableImage then
		self.EditableImage:Destroy()
		self.EditableImage = nil
	end
end

return RenderInstanceMethods
