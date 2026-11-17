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
const ControllerTheoryFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("ControllerTheory")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const ResourceController =
	require(ControllerTheoryFolder:WaitForChild("Controller"):WaitForChild("ResourceController"))
const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderControllerHelper = require(ControllerFolder:WaitForChild("RenderControllerHelper"))
const RenderEntityStageHelper = require(ControllerFolder:WaitForChild("RenderEntityStageHelper"))
const WorkerPartitionHelper = require(ControllerFolder:WaitForChild("WorkerPartitionHelper"))
const RenderWorkerGateway = require(ControllerFolder:WaitForChild("RenderWorkerGateway"))
const RenderResolutionHelper = require(script.Parent:WaitForChild("RenderResolutionHelper"))

-- Configs --
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string
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
		function(_FrameId: number, WorkerCpuTime: number, CompositeCpuTime: number)
			if WorkerCpuTime > (self.MaxWorkerCpuTime :: number) then
				self.MaxWorkerCpuTime = WorkerCpuTime
			end
			self.CompositeCpuTime = (self.CompositeCpuTime :: number) + CompositeCpuTime
			self.Received += 1
			if self.Received >= self.ExpectedWorkers then
				const UploadStart = os.clock() :: number
				const ActiveImg = self.EditableImage :: EditableImage?
				const ActiveImageSize = self.ImageSize :: Vector2
				if ActiveImg then
					ActiveImg:WritePixelsBuffer(Vector2.zero, ActiveImageSize, self.FinalPixel :: buffer)
				end
				const ActiveLabel = self.ImageLabel :: ImageLabel?
				if ActiveLabel and ActiveLabel.ImageRectSize ~= ActiveImageSize then
					ActiveLabel.ImageRectOffset = Vector2.zero
					ActiveLabel.ImageRectSize = ActiveImageSize
				end
				const UploadElapsed = (os.clock() - UploadStart) :: number
				const TotalRenderCpu = (self.LastGatherCpuTime :: number)
					+ (self.MaxWorkerCpuTime :: number)
					+ (self.CompositeCpuTime :: number)
					+ UploadElapsed :: number
				self.Received = 0
				self.FrameInFlight = false
				ResourceController.ReportRendererFeedback(TotalRenderCpu)
			end
		end,
		function(): (number, number, buffer)
			return self.CurrentFrame :: number, self.Width :: number, self.FinalPixel :: buffer
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
	if self.FrameInFlight then
		if (NowClock - (self.LastDispatchClock :: number)) < FRAME_IN_FLIGHT_TIMEOUT then
			return false
		end
		self.FrameInFlight = false
	end

	RenderResolutionHelper.SyncAdaptiveResolution(self)

	const Storage = self.Storage :: ECSMain.ECSStorage
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
	self.LastDispatchClock = NowClock
	self.MaxWorkerCpuTime = 0
	self.CompositeCpuTime = 0

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

	const StagedTriangles = self.StagedTriangles :: buffer
	const StagedBounds = self.StagedBounds :: buffer
	const RowWorkDiff = self.RowWorkDiff :: buffer
	const StagedTriangleCount = RenderEntityStageHelper.StageEntities(
		Storage,
		self.ScreenVertices :: buffer,
		self.ProjectedVertices :: buffer,
		self.ClipBufferA :: buffer,
		self.ClipBufferB :: buffer,
		StagedTriangles,
		StagedBounds,
		self.StagedTriangleCapacity :: number,
		RowWorkDiff,
		CamPosVec,
		CamRightVec,
		CamUpVec,
		CamLookVec,
		FocalLength,
		GuardBandX,
		GuardBandY,
		Width,
		Height
	)
	self.LastStagedTriangleCount = StagedTriangleCount

	const BandStarts = self.BandStarts :: { number }
	const BandEnds = self.BandEnds :: { number }
	WorkerPartitionHelper.PartitionWorkerBands(RowWorkDiff, self.CumulativeWork, self.RowToWorker, Height, ActiveWorkerCount, BandStarts, BandEnds)
	if StagedTriangleCount > 0 and ExpectedWorkers > 0 then
		WorkerPartitionHelper.DispatchStagedTriangles(
			StagedTriangles, StagedBounds, StagedTriangleCount, self.RowToWorker, WorkerOffsets, BufferTable, WorkerCapacity, Height
		)
	end
	RenderWorkerGateway.DispatchWorkerBatches(
		WorkerActors,
		BufferTable,
		WorkerOffsets,
		WorkerCapacity,
		BandStarts,
		BandEnds,
		self.CurrentFrame,
		Width,
		Height
	)
	const GatherElapsed = (os.clock() - NowClock) :: number
	self.LastGatherCpuTime = GatherElapsed
	if ExpectedWorkers == 0 then
		const ActiveLabel = self.ImageLabel :: ImageLabel?
		const ActiveImageSize = self.ImageSize :: Vector2
		if ActiveLabel and ActiveLabel.ImageRectSize ~= ActiveImageSize then
			ActiveLabel.ImageRectOffset = Vector2.zero
			ActiveLabel.ImageRectSize = ActiveImageSize
		end
		ResourceController.ReportRendererFeedback(GatherElapsed)
	end
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
	Dynamically resizes this RenderObject's viewport resolution within its BaseWidth x BaseHeight ceiling.
	@param self any -- Target OOP RenderObject instance.
	@param NewWidth number -- Desired viewport width in pixels.
	@param NewHeight number -- Desired viewport height in pixels.
]=]
function RenderInstanceMethods.SetResolution(self: any, NewWidth: number, NewHeight: number)
	RenderResolutionHelper.ResizeRenderer(self, NewWidth, NewHeight)
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
