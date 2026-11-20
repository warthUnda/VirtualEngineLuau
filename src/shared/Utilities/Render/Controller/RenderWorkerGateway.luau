--!strict
--!native
--!optimize 2

--[=[
	@class RenderWorkerGateway
	Actor transport gateway for display GUI creation, worker message binding, weighted front-to-back
	Pass-1 stage chunk dispatch (with slice buffer reuse), and Pass-2 tile band dispatch/upload.
]=]

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const AssetService = game:GetService("AssetService")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const WorkerPartitionHelper = require(script.Parent:WaitForChild("WorkerPartitionHelper"))

-- Configs --
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const SCRIPTABLE_CAMERA_PARK_POSITION = SystemsConfigs.ScriptableCameraParkPosition :: Vector3
const IMAGE_LABEL_NAME = SystemsConfigs.RendererImageLabelName :: string
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

-- Tables --
const StageChunkCounts = table.create(16, 0) :: { number }
const CachedStageChunkCap = table.create(16, 0) :: { number }
const CachedPosSlices = {} :: { buffer }
const CachedSizeSlices = {} :: { buffer }
const CachedDirSlices = {} :: { buffer }
const CachedVisSlices = {} :: { buffer }
const CachedPropSlices = {} :: { buffer }
local RenderWorkerGateway = {}

-- Functions --
-- ============================================================================
-- 1. DISPLAY GUI CREATION & PARALLEL WORKER ACTOR TRANSPORT
-- ============================================================================

--[=[
	Creates the renderer `ScreenGui`, `ImageLabel`, and `EditableImage` viewport target.
]=]
function RenderWorkerGateway.CreateDisplayGui(
	TargetParent: Instance?,
	Width: number,
	Height: number,
	GuiName: string
): (ScreenGui, ImageLabel, EditableImage)
	const LocalPlayer = Players.LocalPlayer :: Player
	const ResolvedParent: Instance = TargetParent or LocalPlayer:WaitForChild("PlayerGui")

	if TargetParent == nil then
		const LegacyGui = ResolvedParent:FindFirstChild("ScreenGui")
		if LegacyGui and LegacyGui:IsA("ScreenGui") then
			LegacyGui.Enabled = false
		end
	end

	const CreatedGui = Instance.new("ScreenGui")
	CreatedGui.Name = GuiName
	CreatedGui.IgnoreGuiInset = true
	CreatedGui.ResetOnSpawn = false
	CreatedGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	CreatedGui.Enabled = true

	const CreatedLabel = Instance.new("ImageLabel")
	CreatedLabel.Name = IMAGE_LABEL_NAME
	CreatedLabel.AnchorPoint = Vector2.zero
	CreatedLabel.Position = UDim2.fromScale(0, 0)
	CreatedLabel.Size = UDim2.fromScale(1, 1)
	CreatedLabel.BackgroundTransparency = 1
	CreatedLabel.BorderSizePixel = 0
	CreatedLabel.ImageRectOffset = Vector2.zero
	CreatedLabel.ImageRectSize = Vector2.new(Width, Height)
	CreatedLabel.Parent = CreatedGui

	const EditableImg = AssetService:CreateEditableImage({ Size = Vector2.new(Width, Height) }) :: EditableImage
	CreatedLabel.ImageContent = Content.fromObject(EditableImg) :: Content
	CreatedGui.Parent = ResolvedParent

	return CreatedGui, CreatedLabel, EditableImg
end

--[=[
	Binds `Controller` Actor message listeners for Pass-1 staged geometry and Pass-2 rendered bands.
]=]
function RenderWorkerGateway.InitializeWorkers(
	BindWorkers: boolean,
	OnStageReturned: (
		ChunkIdx: number,
		FrameId: number,
		UntexTris: buffer,
		UntexBounds: buffer,
		UntexCount: number,
		TexTris: buffer,
		TexBounds: buffer,
		TexCount: number,
		RowWorkDiff: buffer,
		StageElapsed: number
	) -> (),
	OnBandReturned: (FrameId: number, WorkerCpuTime: number, UploadCpuTime: number, BandStartY: number?, BandEndY: number?) -> (),
	GetActiveFrameAndImage: () -> (number, EditableImage?)
): { Actor }
	if not BindWorkers then
		return {}
	end

	const LocalPlayer = Players.LocalPlayer :: Player
	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
	const SelfActor = PlayerScripts:WaitForChild("Controller") :: Actor
	const WorkerActors = (PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: any) :: { Actor }

	task.spawn(function()
		const ActiveCamera = workspace.CurrentCamera
		if ActiveCamera then
			ActiveCamera.CameraType = Enum.CameraType.Scriptable
			ActiveCamera.CFrame = CFrame.new(SCRIPTABLE_CAMERA_PARK_POSITION)
		end
	end)

	SelfActor:BindToMessage("Return Staged Geometry", OnStageReturned)

	SelfActor:BindToMessage(
		"Return Render Calculations",
		function(
			BandPixelSlice: buffer,
			FrameId: number,
			BandStartY: number,
			BandEndY: number,
			BandWidth: number,
			WorkerComputeSeconds: number?
		)
			const ActiveFrameId: number, ActiveImg: EditableImage? = GetActiveFrameAndImage()
			if FrameId ~= ActiveFrameId then
				return
			end

			const UploadStart = os.clock() :: number
			if ActiveImg and BandStartY <= BandEndY and buffer.len(BandPixelSlice) > 0 then
				const BandHeight = BandEndY - BandStartY + 1 :: number
				ActiveImg:WritePixelsBuffer(Vector2.new(0, BandStartY), Vector2.new(BandWidth, BandHeight), BandPixelSlice)
			end
			const UploadElapsed = (os.clock() - UploadStart) :: number
			OnBandReturned(FrameId, (WorkerComputeSeconds or 0) :: number, UploadElapsed, BandStartY, BandEndY)
		end
	)

	return WorkerActors
end

--[=[
	Broadcasts decoded texture buffers to all parallel worker Actors.
]=]
function RenderWorkerGateway.BroadcastTextures(
	WorkerActors: { Actor },
	LoadedTextureBuffers: { [number]: buffer }
)
	for _, TargetActor: Actor in ipairs(WorkerActors) do
		TargetActor:SendMessage("Set Texture Table", LoadedTextureBuffers, TEXTURE_SIZE, TEXTURE_SIZE)
	end
end

--[=[
	Dispatches weighted contiguous front-to-back ECS entity chunks across parallel workers for Pass 1.
]=]
function RenderWorkerGateway.DispatchStageChunks(
	WorkerActors: { Actor },
	Storage: ECSMain.ECSStorage,
	EntityCount: number,
	CamPosVec: vector,
	CamRightVec: vector,
	CamUpVec: vector,
	CamLookVec: vector,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number,
	PlaneLeft: vector,
	PlaneRight: vector,
	PlaneBottom: vector,
	PlaneTop: vector,
	ActiveWidth: number,
	ActiveHeight: number,
	FrameId: number
): number
	const WorkerCount = #WorkerActors :: number
	if WorkerCount <= 0 or EntityCount <= 0 then
		return 0
	end

	const PosBuf = Storage.PositionData.GetData() :: buffer
	const SizeBuf = Storage.SizeData.GetData() :: buffer
	const DirBuf = Storage.DirectionsData.GetData() :: buffer
	const VisBuf = Storage.VisualData.GetData() :: buffer
	const PropBuf = Storage.PropertiesData.GetData() :: buffer

	const DispatchedChunks = WorkerPartitionHelper.ComputeStageChunkCounts(EntityCount, WorkerCount, StageChunkCounts) :: number
	local StartIdx = 0 :: number

	for i = 1, DispatchedChunks do
		const ChunkCount = StageChunkCounts[i] :: number
		const CompBytes = ChunkCount * COMPONENT_STRIDE :: number
		const DirBytes = ChunkCount * DIRECTION_STRIDE :: number
		const VisBytes = ChunkCount * VISUAL_STRIDE :: number
		const PropBytes = ChunkCount * PROPERTIES_STRIDE :: number

		if CachedStageChunkCap[i] ~= ChunkCount then
			CachedStageChunkCap[i] = ChunkCount
			CachedPosSlices[i] = buffer.create(CompBytes)
			CachedSizeSlices[i] = buffer.create(CompBytes)
			CachedDirSlices[i] = buffer.create(DirBytes)
			CachedVisSlices[i] = buffer.create(VisBytes)
			CachedPropSlices[i] = buffer.create(PropBytes)
		end
		const PosSlice = CachedPosSlices[i]
		const SizeSlice = CachedSizeSlices[i]
		const DirSlice = CachedDirSlices[i]
		const VisSlice = CachedVisSlices[i]
		const PropSlice = CachedPropSlices[i]

		buffer.copy(PosSlice, 0, PosBuf, StartIdx * COMPONENT_STRIDE, CompBytes)
		buffer.copy(SizeSlice, 0, SizeBuf, StartIdx * COMPONENT_STRIDE, CompBytes)
		buffer.copy(DirSlice, 0, DirBuf, StartIdx * DIRECTION_STRIDE, DirBytes)
		buffer.copy(VisSlice, 0, VisBuf, StartIdx * VISUAL_STRIDE, VisBytes)
		buffer.copy(PropSlice, 0, PropBuf, StartIdx * PROPERTIES_STRIDE, PropBytes)

		WorkerActors[i]:SendMessage(
			"Stage Entities",
			i,
			PosSlice, SizeSlice, DirSlice, VisSlice, PropSlice, ChunkCount,
			CamPosVec, CamRightVec, CamUpVec, CamLookVec,
			FocalLength, GuardBandX, GuardBandY,
			PlaneLeft, PlaneRight, PlaneBottom, PlaneTop,
			ActiveWidth, ActiveHeight, FrameId
		)
		StartIdx += ChunkCount
	end

	return DispatchedChunks
end

--[=[
	Dispatches scattered dual-stream triangle slices and equal-cost screen bands to parallel workers.
]=]
function RenderWorkerGateway.DispatchTileBands(
	WorkerActors: { Actor },
	UntexSlices: { buffer },
	UntexBytes: { number },
	TexSlices: { buffer },
	TexBytes: { number },
	BandStarts: { number },
	BandEnds: { number },
	FrameId: number,
	ActiveWidth: number,
	ActiveHeight: number
)
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		TargetActor:SendMessage(
			"Execute Rendering",
			UntexSlices[i],
			UntexBytes[i],
			TexSlices[i],
			TexBytes[i],
			FrameId,
			BandStarts[i],
			BandEnds[i],
			ActiveWidth,
			ActiveHeight
		)
	end
end

return RenderWorkerGateway
