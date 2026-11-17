--!strict
--!native
--!optimize 2

--[=[
	@class RenderWorkerGateway
	Roblox boundary gateway managing self-created ScreenGui/ImageLabel/EditableImage allocation,
	parallel worker Actor messaging, texture broadcasting, and triangle batch dispatching.
]=]

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const AssetService = game:GetService("AssetService")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const BufferHelper = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("BufferHelper"))

-- Configs --
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const SCRIPTABLE_CAMERA_PARK_POSITION = SystemsConfigs.ScriptableCameraParkPosition :: Vector3
const IMAGE_LABEL_NAME = SystemsConfigs.RendererImageLabelName :: string

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer

-- Tables --
local RenderWorkerGateway = {}

-- Functions --
-- ============================================================================
-- 1. SELF-CONTAINED SCREENGUI CREATION & PARALLEL WORKER ACTOR GATEWAY
-- ============================================================================

--[=[
	Creates a self-contained ScreenGui, full-screen ImageLabel, and bound EditableImage for a RenderService instance.
	@param TargetParent Instance? -- Optional parent container (defaults to LocalPlayer.PlayerGui).
	@param Width number -- Horizontal pixel resolution.
	@param Height number -- Vertical pixel resolution.
	@param GuiName string -- Name assigned to the created ScreenGui.
	@return (ScreenGui, ImageLabel, EditableImage) -- Created ScreenGui, ImageLabel, and EditableImage.
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
	Initializes worker Actor command buffers, initial horizontal band ranges, and the pixel-return listener.
	@param Width number -- Viewport width in pixels.
	@param Height number -- Viewport height in pixels.
	@param WorkerCapacity number -- Per-worker command buffer byte capacity.
	@param FinalPixel buffer -- Full-screen RGBA destination buffer.
	@param BufferTable { buffer } -- Per-worker triangle command buffers.
	@param WorkerOffsets { number } -- Per-worker byte write offsets.
	@param BandStarts { number } -- Per-worker dynamic band start Y array.
	@param BandEnds { number } -- Per-worker dynamic band end Y array.
	@param EditableImg EditableImage -- Bound EditableImage receiving composited frames.
	@param BindWorkers boolean -- True to bind Controller Actor worker messaging; false for isolated GUI specs.
	@param OnWorkerReturned (FrameId: number, WorkerCpuTime: number, CompositeCpuTime: number) -> () -- Frame-band completion callback.
	@param GetCurrentFrameState () -> (number, number, buffer) -- Accessor returning live (FrameId, Width, FinalPixel).
	@return { Actor } -- Resolved parallel worker Actors (empty when BindWorkers is false).
]=]
function RenderWorkerGateway.InitializeWorkers(
	Width: number,
	Height: number,
	WorkerCapacity: number,
	_FinalPixel: buffer,
	BufferTable: { buffer },
	WorkerOffsets: { number },
	BandStarts: { number },
	BandEnds: { number },
	_EditableImg: EditableImage,
	BindWorkers: boolean,
	OnWorkerReturned: (FrameId: number, WorkerCpuTime: number, CompositeCpuTime: number) -> (),
	GetCurrentFrameState: () -> (number, number, buffer)
): { Actor }
	if not BindWorkers then
		for i = 1, ACTOR_COUNT do
			BufferTable[i] = buffer.create(WorkerCapacity)
			WorkerOffsets[i] = 0
			BandStarts[i] = 0
			BandEnds[i] = Height - 1
		end
		return {}
	end

	const LocalPlayer = Players.LocalPlayer :: Player
	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
	const SelfActor = PlayerScripts:WaitForChild("Controller") :: Actor
	const WorkerActors = (PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: any) :: { Actor }
	const BandHeight = math.ceil(Height / math.max(1, ACTOR_COUNT)) :: number

	const WorkerPoolSize = math.max(ACTOR_COUNT, #WorkerActors) :: number
	for i = 1, WorkerPoolSize do
		BufferTable[i] = buffer.create(WorkerCapacity)
		WorkerOffsets[i] = 0
		BandStarts[i] = 0
		BandEnds[i] = Height - 1
	end

	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const BandStartY = (i - 1) * BandHeight :: number
		const BandEndY = math.min(i * BandHeight - 1, Height - 1) :: number
		BandStarts[i] = BandStartY
		BandEnds[i] = BandEndY
		TargetActor:SendMessage("Set Band Range", BandStartY, BandEndY)
	end

	task.spawn(function()
		const ActiveCamera = workspace.CurrentCamera
		if ActiveCamera then
			ActiveCamera.CameraType = Enum.CameraType.Scriptable
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
			DirtyMaxY: number,
			WorkerComputeSeconds: number?
		)
			const ActiveFrameId: number, ActiveWidth: number, ActiveFinalPixel: buffer = GetCurrentFrameState()
			if FrameId ~= ActiveFrameId then
				return
			end

			const CompositeStart = os.clock() :: number
			BufferHelper.CompositeWorkerBand(
				ActiveFinalPixel,
				WorkerPixelBuffer,
				ActiveWidth,
				BandStartY,
				BandEndY,
				DirtyMinY,
				DirtyMaxY,
				true
			)
			const CompositeElapsed = (os.clock() - CompositeStart) :: number
			OnWorkerReturned(FrameId, (WorkerComputeSeconds or 0) :: number, CompositeElapsed)
		end
	)

	return WorkerActors
end

--[=[
	Broadcasts decoded 64x64 RGBA texture tables to all parallel worker Actors.
	@param WorkerActors { Actor } -- Active worker Actor list.
	@param LoadedTextureBuffers { [number]: buffer } -- Cached RGBA buffers keyed by TextureId.
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
	Dispatches compact triangle command slices and dynamic scanline band ranges to each worker Actor.
	@param WorkerActors { Actor } -- Active worker Actor list.
	@param BufferTable { buffer } -- Per-worker triangle command buffers.
	@param WorkerOffsets { number } -- Per-worker active byte counts.
	@param WorkerCapacity number -- Per-worker command buffer byte capacity.
	@param BandStarts { number } -- Per-worker band start Y array.
	@param BandEnds { number } -- Per-worker band end Y array.
	@param FrameId number -- Monotonic render frame ID.
	@param ActiveWidth number? -- Optional active viewport width override.
	@param ActiveHeight number? -- Optional active viewport height override.
]=]
function RenderWorkerGateway.DispatchWorkerBatches(
	WorkerActors: { Actor },
	BufferTable: { buffer },
	WorkerOffsets: { number },
	WorkerCapacity: number,
	BandStarts: { number },
	BandEnds: { number },
	FrameId: number,
	ActiveWidth: number?,
	ActiveHeight: number?
)
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const ByteCount = WorkerOffsets[i] :: number
		local PayloadBuffer = EmptyPayload :: buffer
		if ByteCount > 0 then
			if ByteCount < WorkerCapacity then
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
			FrameId,
			BandStarts[i],
			BandEnds[i],
			ActiveWidth,
			ActiveHeight
		)
	end
end

return RenderWorkerGateway
