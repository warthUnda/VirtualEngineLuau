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
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderControllerHelper = require(script.Parent.RenderControllerHelper)

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const IMAGE_SIZE = Vector2.new(WIDTH, HEIGHT) :: Vector2
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const BAND_HEIGHT = math.ceil(HEIGHT / ACTOR_COUNT) :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const WORKER_BUFFER_CAPACITY = WIDTH * HEIGHT * WORKER_BUFFER_MULTIPLIER :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const SCRIPTABLE_CAMERA_PARK_POSITION = SystemsConfigs.ScriptableCameraParkPosition :: Vector3
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const TEXTURE_SYNC_REMOTE_EVENT_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string

-- Tables --
local RenderWorkerGateway = {}

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer

-- Functions --
-- ============================================================================
-- 1. WORKER ACTOR GATEWAY - DISPLAY BINDING, SYNC & PARALLEL DISPATCH
-- ============================================================================

--[=[
	Initializes the ScreenGui EditableImage, worker Actor band ranges, return-pixel listener, and texture sync listener.
	@param FinalPixel buffer -- Full-screen RGBA destination buffer.
	@param BufferTable { buffer } -- Per-worker triangle command buffers.
	@param WorkerOffsets { number } -- Per-worker byte write offsets.
	@param BandStarts { number } -- Per-worker dynamic band start Y array.
	@param BandEnds { number } -- Per-worker dynamic band end Y array.
	@param OnWorkerReturned (FrameId: number, EditableImage: EditableImage) -> () -- Callback invoked after compositing a valid frame band.
	@param GetCurrentFrame () -> number -- Accessor returning the active frame ID.
	@param OnTexturesDecoded (UpdatedBuffers: { [number]: buffer }) -> () -- Callback invoked when synced textures finish decoding.
	@return ({ Actor }, EditableImage) -- Resolved WorkerActors array and bound EditableImage.
]=]
function RenderWorkerGateway.InitializeGateway(
	FinalPixel: buffer,
	BufferTable: { buffer },
	WorkerOffsets: { number },
	BandStarts: { number },
	BandEnds: { number },
	OnWorkerReturned: (FrameId: number, EditableImage: EditableImage) -> (),
	GetCurrentFrame: () -> number,
	OnTexturesDecoded: (UpdatedBuffers: { [number]: buffer }) -> ()
): ({ Actor }, EditableImage)
	const ScreenGui = PlayerGui:WaitForChild("ScreenGui") :: ScreenGui
	ScreenGui.ResetOnSpawn = false
	const ImageLabel = ScreenGui:WaitForChild("ImageLabel") :: ImageLabel
	const SelfActor = PlayerScripts:WaitForChild("Controller") :: Actor
	const WorkerActors = (PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: any) :: { Actor }

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

	const EditableImage = AssetService:CreateEditableImage({ Size = IMAGE_SIZE }) :: EditableImage
	ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

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
			DirtyMaxY: number
		)
			if FrameId ~= GetCurrentFrame() then
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
			OnWorkerReturned(FrameId, EditableImage)
		end
	)

	const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
	const TextureSyncEvent = CoreEvents:WaitForChild(TEXTURE_SYNC_REMOTE_EVENT_NAME) :: RemoteEvent
	TextureSyncEvent.OnClientEvent:Connect(function(Entries: any)
		RenderControllerHelper.ApplySyncedTextures(Entries, OnTexturesDecoded)
	end)
	TextureSyncEvent:FireServer()

	return WorkerActors, EditableImage
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
	@param BandStarts { number } -- Per-worker band start Y array.
	@param BandEnds { number } -- Per-worker band end Y array.
	@param FrameId number -- Monotonic render frame ID.
]=]
function RenderWorkerGateway.DispatchWorkerBatches(
	WorkerActors: { Actor },
	BufferTable: { buffer },
	WorkerOffsets: { number },
	BandStarts: { number },
	BandEnds: { number },
	FrameId: number
)
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
			FrameId,
			BandStarts[i],
			BandEnds[i]
		)
	end
end

return RenderWorkerGateway
