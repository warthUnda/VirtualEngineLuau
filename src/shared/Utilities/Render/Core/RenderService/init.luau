--!strict
--!native
--!optimize 2

--[=[
	@class RenderService
	OOP software rendering service managing isolated pre-allocated staging/partition buffers,
	2-pass parallel worker Actor pipelines, self-created GUI viewports, and direct per-band upload.
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
const CameraService = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraService"))
const RenderInstanceMethods = require(script.RenderInstanceMethods)

-- Storage --
const RenderECSStorage = require(RenderRoot:WaitForChild("ECSStorage"))

-- Configs --
const DEFAULT_WIDTH = SystemsConfigs.RenderWidth :: number
const DEFAULT_HEIGHT = SystemsConfigs.RenderHeight :: number
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const UNTEXTURED_STRIDE = SystemsConfigs.UntexturedBufferLayoutSize :: number
const TEXTURED_STRIDE = SystemsConfigs.RenderBufferLayoutSize :: number
const DEFAULT_GUI_NAME = SystemsConfigs.RendererScreenGuiName :: string

export type RenderOptions = {
	Width: number?,
	Height: number?,
	GuiName: string?,
	Storage: ECSMain.ECSStorage?,
	Camera: CameraService.CameraObject?,
}

export type RenderObject = {
	ClassName: string,
	BaseWidth: number,
	BaseHeight: number,
	Width: number,
	Height: number,
	ImageSize: Vector2,
	GuiName: string,
	Storage: ECSMain.ECSStorage,
	Camera: CameraService.CameraObject,
	CachedCameraCFrame: CFrame?,
	CachedCameraPosVec: vector,
	CachedCameraRightVec: vector,
	CachedCameraUpVec: vector,
	CachedCameraLookVec: vector,
	CachedCameraFOV: number,
	CachedProjWidth: number,
	CachedProjHeight: number,
	CachedFocalLength: number,
	CachedGuardBandX: number,
	CachedGuardBandY: number,
	CachedPlaneLeft: vector,
	CachedPlaneRight: vector,
	CachedPlaneBottom: vector,
	CachedPlaneTop: vector,
	ScreenGui: ScreenGui?,
	ImageLabel: ImageLabel?,
	EditableImage: EditableImage?,
	Initialized: boolean,
	Received: number,
	ExpectedWorkers: number,
	StagedReceived: number,
	ExpectedStageChunks: number,
	CurrentFrame: number,
	ActiveFrameWidth: number,
	ActiveFrameHeight: number,
	FrameInFlight: boolean,
	LastDispatchClock: number,
	LastGatherCpuTime: number,
	MaxStageCpuTime: number,
	MaxWorkerCpuTime: number,
	UploadCpuTime: number,
	PendingTextureSyncFrames: number,
	LastTextureVersion: number,
	LoadedTextureBuffers: { [number]: buffer }?,
	LastStagedTriangleCount: number,
	StagedTriangleCapacity: number,
	WorkerActors: { Actor },
	BandStarts: { number },
	BandEnds: { number },
	ChunkUntexTris: { buffer },
	ChunkUntexBounds: { buffer },
	ChunkUntexCounts: { number },
	ChunkTexTris: { buffer },
	ChunkTexBounds: { buffer },
	ChunkTexCounts: { number },
	WorkerUntexSlices: { buffer },
	WorkerUntexBytes: { number },
	WorkerTexSlices: { buffer },
	WorkerTexBytes: { number },
	FinalPixel: buffer,
	StagedTriangles: buffer,
	StagedUntexTris: buffer,
	StagedUntexBounds: buffer,
	StagedTexTris: buffer,
	StagedTexBounds: buffer,
	RowWorkDiff: buffer,
	CumulativeWork: buffer,
	RowToWorker: buffer,
	ScreenVertices: buffer,
	ProjectedVertices: buffer,
	ClipBufferA: buffer,
	ClipBufferB: buffer,
	Init: (self: RenderObject, TargetParent: Instance?, BindWorkers: boolean?) -> (),
	DrawFrame: (self: RenderObject) -> boolean,
	SetCamera: (self: RenderObject, CameraObj: CameraService.CameraObject) -> (),
	SetStorage: (self: RenderObject, Storage: ECSMain.ECSStorage) -> (),
	SetResolution: (self: RenderObject, NewWidth: number, NewHeight: number) -> (),
	SetEnabled: (self: RenderObject, Enabled: boolean) -> (),
	GetScreenGui: (self: RenderObject) -> ScreenGui?,
	GetImageLabel: (self: RenderObject) -> ImageLabel?,
	GetEditableImage: (self: RenderObject) -> EditableImage?,
	Destroy: (self: RenderObject) -> (),
}

-- Tables --
local RenderService = {
	Init = RenderInstanceMethods.Init,
	DrawFrame = RenderInstanceMethods.DrawFrame,
	SetCamera = RenderInstanceMethods.SetCamera,
	SetStorage = RenderInstanceMethods.SetStorage,
	SetResolution = RenderInstanceMethods.SetResolution,
	SetEnabled = RenderInstanceMethods.SetEnabled,
	GetScreenGui = RenderInstanceMethods.GetScreenGui,
	GetImageLabel = RenderInstanceMethods.GetImageLabel,
	GetEditableImage = RenderInstanceMethods.GetEditableImage,
	Destroy = RenderInstanceMethods.Destroy,
}
RenderService.__index = RenderService

-- Functions --
-- ============================================================================
-- 1. OOP RENDER SERVICE CONSTRUCTOR
-- ============================================================================

--[=[
	Constructs a new OOP RenderService instance with isolated pre-allocated dual-stream and tile-band buffers.
]=]
function RenderService.New(Options: RenderOptions?): RenderObject
	const Opts: RenderOptions = Options or {}
	const Width = math.clamp(math.floor((Opts.Width or DEFAULT_WIDTH) :: number), 1, DEFAULT_WIDTH) :: number
	const Height = math.clamp(math.floor((Opts.Height or DEFAULT_HEIGHT) :: number), 1, DEFAULT_HEIGHT) :: number
	const MaxTotalPixels = DEFAULT_WIDTH * DEFAULT_HEIGHT :: number
	const StagedCapacity = math.max(64, (MaxTotalPixels * WORKER_BUFFER_MULTIPLIER) // TEXTURED_STRIDE) :: number
	const UntexStagingBuf = buffer.create(StagedCapacity * UNTEXTURED_STRIDE)

	const RawRenderer = {
		ClassName = "RenderService",
		BaseWidth = Width,
		BaseHeight = Height,
		Width = Width,
		Height = Height,
		ImageSize = Vector2.new(Width, Height),
		GuiName = Opts.GuiName or DEFAULT_GUI_NAME,
		Storage = Opts.Storage or RenderECSStorage,
		Camera = Opts.Camera or CameraService.GetActiveCamera(),
		CachedCameraCFrame = nil :: CFrame?,
		CachedCameraPosVec = vector.zero,
		CachedCameraRightVec = vector.create(1, 0, 0),
		CachedCameraUpVec = vector.create(0, 1, 0),
		CachedCameraLookVec = vector.create(0, 0, -1),
		CachedCameraFOV = -1,
		CachedProjWidth = -1,
		CachedProjHeight = -1,
		CachedFocalLength = 0,
		CachedGuardBandX = 0,
		CachedGuardBandY = 0,
		CachedPlaneLeft = vector.create(1, 0, 1),
		CachedPlaneRight = vector.create(-1, 0, 1),
		CachedPlaneBottom = vector.create(0, 1, 1),
		CachedPlaneTop = vector.create(0, -1, 1),
		ScreenGui = nil :: ScreenGui?,
		ImageLabel = nil :: ImageLabel?,
		EditableImage = nil :: EditableImage?,
		Initialized = false,
		Received = 0,
		ExpectedWorkers = 0,
		StagedReceived = 0,
		ExpectedStageChunks = 0,
		CurrentFrame = 0,
		ActiveFrameWidth = Width,
		ActiveFrameHeight = Height,
		FrameInFlight = false,
		LastDispatchClock = 0,
		LastGatherCpuTime = 0,
		MaxStageCpuTime = 0,
		MaxWorkerCpuTime = 0,
		UploadCpuTime = 0,
		PendingTextureSyncFrames = 0,
		LastTextureVersion = -1,
		LoadedTextureBuffers = nil :: { [number]: buffer }?,
		LastStagedTriangleCount = 0,
		StagedTriangleCapacity = StagedCapacity,
		WorkerActors = {} :: { Actor },
		BandStarts = table.create(ACTOR_COUNT, 0) :: { number },
		BandEnds = table.create(ACTOR_COUNT, 0) :: { number },
		ChunkUntexTris = {} :: { buffer },
		ChunkUntexBounds = {} :: { buffer },
		ChunkUntexCounts = table.create(ACTOR_COUNT, 0) :: { number },
		ChunkTexTris = {} :: { buffer },
		ChunkTexBounds = {} :: { buffer },
		ChunkTexCounts = table.create(ACTOR_COUNT, 0) :: { number },
		WorkerUntexSlices = {} :: { buffer },
		WorkerUntexBytes = table.create(ACTOR_COUNT, 0) :: { number },
		WorkerTexSlices = {} :: { buffer },
		WorkerTexBytes = table.create(ACTOR_COUNT, 0) :: { number },
		FinalPixel = buffer.create(Width * Height * 4),
		StagedTriangles = UntexStagingBuf,
		StagedUntexTris = UntexStagingBuf,
		StagedUntexBounds = buffer.create(StagedCapacity * 4),
		StagedTexTris = buffer.create(StagedCapacity * TEXTURED_STRIDE),
		StagedTexBounds = buffer.create(StagedCapacity * 4),
		RowWorkDiff = buffer.create((DEFAULT_HEIGHT + 1) * 4),
		CumulativeWork = buffer.create(DEFAULT_HEIGHT * 4),
		RowToWorker = buffer.create(DEFAULT_HEIGHT),
		ScreenVertices = buffer.create(VerticeFile.MaxShapeVertices * 12),
		ProjectedVertices = buffer.create(12 * 24),
		ClipBufferA = buffer.create(12 * 24),
		ClipBufferB = buffer.create(12 * 24),
	}

	const UntypedRenderer: any = setmetatable(RawRenderer, RenderService)
	return UntypedRenderer :: RenderObject
end

return RenderService
