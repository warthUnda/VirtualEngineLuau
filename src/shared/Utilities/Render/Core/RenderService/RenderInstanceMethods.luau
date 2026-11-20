--!strict
--!native
--!optimize 2

--[=[
	@class RenderInstanceMethods
	Instance methods for OOP RenderService objects, orchestrating 2-pass parallel geometry
	staging and 2D 32x32 tile rasterization with direct per-band EditableImage uploads.
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
const RenderingRep =
	require(ControllerTheoryFolder:WaitForChild("ControllerReps"):WaitForChild("RenderingRep"))
const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))
const BufferHelper = require(RenderRoot:WaitForChild("Core"):WaitForChild("BufferHelper"))
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderControllerHelper = require(ControllerFolder:WaitForChild("RenderControllerHelper"))
const RenderEntityStageHelper = require(ControllerFolder:WaitForChild("RenderEntityStageHelper"))
const RenderWorkerGateway = require(ControllerFolder:WaitForChild("RenderWorkerGateway"))
const RenderResolutionHelper = require(script.Parent:WaitForChild("RenderResolutionHelper"))
const RenderFrameDispatchHelper = require(script.Parent:WaitForChild("RenderFrameDispatchHelper"))

-- Configs --
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string
const FRAME_IN_FLIGHT_TIMEOUT = 0.25 :: number

-- Tables --
local RenderInstanceMethods = {}

-- Functions --
-- ============================================================================
-- 1. OOP RENDER SERVICE INSTANCE METHODS (2-PASS PARALLEL PIPELINE)
-- ============================================================================

--[=[
	Creates the renderer's own ScreenGui/ImageLabel/EditableImage, initializes 2-pass parallel
	worker callbacks, and activates its CameraObject.
]=]
function RenderInstanceMethods.Init(self: any, TargetParent: Instance?, BindWorkers: boolean?)
	if self.Initialized then
		return
	end

	const ShouldBindWorkers = (BindWorkers ~= false) :: boolean
	const ScreenGui, ImageLabel, EditableImg =
		RenderWorkerGateway.CreateDisplayGui(TargetParent, self.Width :: number, self.Height :: number, self.GuiName :: string)
	self.ScreenGui = ScreenGui
	self.ImageLabel = ImageLabel
	self.EditableImage = EditableImg

	self.WorkerActors = RenderWorkerGateway.InitializeWorkers(
		ShouldBindWorkers,
		function(
			ChunkIdx: number, FrameId: number,
			UntexTris: buffer, UntexBounds: buffer, UntexCount: number,
			TexTris: buffer, TexBounds: buffer, TexCount: number,
			ChunkRowDiff: buffer, StageElapsed: number
		)
			RenderFrameDispatchHelper.HandleStageChunkReturned(
				self, ChunkIdx, FrameId,
				UntexTris, UntexBounds, UntexCount,
				TexTris, TexBounds, TexCount,
				ChunkRowDiff, StageElapsed
			)
		end,
		function(FrameId: number, WorkerCpuTime: number, UploadCpuTime: number, BandStartY: number?, BandEndY: number?)
			RenderFrameDispatchHelper.HandleBandReturned(self, FrameId, WorkerCpuTime, UploadCpuTime, BandStartY, BandEndY)
		end,
		function(): (number, EditableImage?)
			return self.CurrentFrame :: number, self.EditableImage :: EditableImage?
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
	Dispatches Pass 1 (parallel entity geometry staging across WorkerActors) or executes synchronously
	when BindWorkers is false for isolated specs.
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
		self, BoundCamera.CameraCFrame :: CFrame, BoundCamera.CameraFOV :: number, Width, Height
	)

	const WorkerActors = self.WorkerActors :: { Actor }
	const ExpectedWorkers = #WorkerActors :: number
	const FrameId = (self.CurrentFrame :: number) + 1 :: number
	self.CurrentFrame = FrameId
	self.ActiveFrameWidth = Width
	self.ActiveFrameHeight = Height
	self.Received = 0
	self.StagedReceived = 0
	self.ExpectedWorkers = ExpectedWorkers
	self.LastDispatchClock = NowClock
	self.LastGatherCpuTime = 0
	self.MaxStageCpuTime = 0
	self.MaxWorkerCpuTime = 0
	self.UploadCpuTime = 0
	self.LastStagedTriangleCount = 0

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

	if ExpectedWorkers == 0 then
		buffer.fill(self.RowWorkDiff, 0, 0, (Height + 1) * 4)
		const UCount: number, TCount: number = RenderEntityStageHelper.StageEntitiesDual(
			Storage,
			self.ScreenVertices, self.ProjectedVertices, self.ClipBufferA, self.ClipBufferB,
			self.StagedUntexTris, self.StagedUntexBounds, self.StagedTriangleCapacity,
			self.StagedTexTris, self.StagedTexBounds, self.StagedTriangleCapacity,
			self.RowWorkDiff,
			self.CachedCameraPosVec, self.CachedCameraRightVec, self.CachedCameraUpVec, self.CachedCameraLookVec,
			self.CachedFocalLength, self.CachedGuardBandX, self.CachedGuardBandY, Width, Height,
			self.CachedPlaneLeft, self.CachedPlaneRight, self.CachedPlaneBottom, self.CachedPlaneTop
		)
		self.LastStagedTriangleCount = UCount + TCount
		const ActiveLabel = self.ImageLabel :: ImageLabel?
		const ActiveImageSize = self.ImageSize :: Vector2
		if ActiveLabel and ActiveLabel.ImageRectSize ~= ActiveImageSize then
			ActiveLabel.ImageRectOffset = Vector2.zero
			ActiveLabel.ImageRectSize = ActiveImageSize
		end
		RenderingRep.ReportFeedback(os.clock() - NowClock)
		return true
	end

	const EntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	if EntityCount <= 0 then
		const ActiveImg = self.EditableImage :: EditableImage?
		const ActiveImageSize = self.ImageSize :: Vector2
		if ActiveImg then
			ActiveImg:WritePixelsBuffer(Vector2.zero, ActiveImageSize, BufferHelper.EnsureClearTemplate(Width * Height * 4))
		end
		const ActiveLabel = self.ImageLabel :: ImageLabel?
		if ActiveLabel and ActiveLabel.ImageRectSize ~= ActiveImageSize then
			ActiveLabel.ImageRectOffset = Vector2.zero
			ActiveLabel.ImageRectSize = ActiveImageSize
		end
		RenderingRep.ReportFeedback(os.clock() - NowClock)
		return true
	end

	buffer.fill(self.RowWorkDiff, 0, 0, (Height + 1) * 4)
	const DispatchedChunks = RenderWorkerGateway.DispatchStageChunks(
		WorkerActors, Storage, EntityCount,
		self.CachedCameraPosVec, self.CachedCameraRightVec, self.CachedCameraUpVec, self.CachedCameraLookVec,
		self.CachedFocalLength, self.CachedGuardBandX, self.CachedGuardBandY,
		self.CachedPlaneLeft, self.CachedPlaneRight, self.CachedPlaneBottom, self.CachedPlaneTop,
		Width, Height, FrameId
	) :: number
	self.ExpectedStageChunks = DispatchedChunks
	self.FrameInFlight = DispatchedChunks > 0
	self.LastGatherCpuTime = os.clock() - NowClock
	return true
end

function RenderInstanceMethods.SetCamera(self: any, CameraObj: CameraService.CameraObject)
	self.Camera = CameraObj
	self.CachedCameraCFrame = nil
	self.CachedCameraFOV = -1
end

function RenderInstanceMethods.SetStorage(self: any, Storage: ECSMain.ECSStorage)
	self.Storage = Storage
end

function RenderInstanceMethods.SetEnabled(self: any, Enabled: boolean)
	const Gui = self.ScreenGui :: ScreenGui?
	if Gui then
		Gui.Enabled = Enabled
	end
end

function RenderInstanceMethods.GetScreenGui(self: any): ScreenGui?
	return self.ScreenGui
end

function RenderInstanceMethods.GetImageLabel(self: any): ImageLabel?
	return self.ImageLabel
end

function RenderInstanceMethods.GetEditableImage(self: any): EditableImage?
	return self.EditableImage
end

function RenderInstanceMethods.SetResolution(self: any, NewWidth: number, NewHeight: number)
	RenderResolutionHelper.ResizeRenderer(self, NewWidth, NewHeight)
end

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
