--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const AssetService = game:GetService("AssetService") :: AssetService

-- Static References --
const Player = Players.LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

const Camera = workspace.CurrentCamera :: Camera

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)

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

-- Configs --
const WIDTH = SystemsConfigs.RenderWidth :: number
const HEIGHT = SystemsConfigs.RenderHeight :: number
const HALF_WIDTH = WIDTH * 0.5 :: number
const HALF_HEIGHT = HEIGHT * 0.5 :: number
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
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number
const SCRIPTABLE_CAMERA_PARK_POSITION = SystemsConfigs.ScriptableCameraParkPosition :: Vector3
const DEFAULT_CAMERA_VIEW = SystemsConfigs.DefaultCameraView :: string

const ECS_COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const ECS_DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

local Initialized = false :: boolean
local Received = 0 :: number
local CurrentFrame = 0 :: number

-- Tables --
local WorkerActors = {} :: { Actor }
local WorkerOffsets = table.create(ACTOR_COUNT, 0) :: { number }
local WorkerScores = table.create(ACTOR_COUNT, 0) :: { number }
local BufferTable = {} :: { buffer }

-- Buffers
const EmptyPayload = buffer.create(0) :: buffer
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const FinalZ = buffer.create(TOTAL_PIXELS * 4) :: buffer
const ECSPositionBuffer = PositionData.GetData() :: buffer
const ECSSizeBuffer = SizeData.GetData() :: buffer
const ECSDirectionsBuffer = DirectionsData.GetData() :: buffer
const ECSVisualBuffer = VisualData.GetData() :: buffer
local ScreenVertices = buffer.create(8 * 12) :: buffer
local ProjectedVertices = buffer.create(12 * 12) :: buffer
local ClipBufferA = buffer.create(12 * 12) :: buffer
local ClipBufferB = buffer.create(12 * 12) :: buffer

local Renderer = {}

local function ReadDirectionVec(Offset: number): vector
	return vector.create(
		buffer.readf32(ECSDirectionsBuffer, Offset),
		buffer.readf32(ECSDirectionsBuffer, Offset + 4),
		buffer.readf32(ECSDirectionsBuffer, Offset + 8)
	)
end

local function PackShadedColor(R: number, G: number, B: number, Illumination: number): number
	return bit32.bor(
		math.floor(R * Illumination),
		bit32.lshift(math.floor(G * Illumination), 8),
		bit32.lshift(math.floor(B * Illumination), 16),
		0xFF000000
	)
end

local function SubmitFaceQuad(
	V0ByteOffset: number,
	V1ByteOffset: number,
	V2ByteOffset: number,
	V3ByteOffset: number,
	PackedColor: number,
	FocalLength: number,
	GuardBandX: number,
	GuardBandY: number
)
	const ClippedVertexCount = RenderMath.ClipAndProjectQuad(
		ScreenVertices,
		V0ByteOffset,
		V1ByteOffset,
		V2ByteOffset,
		V3ByteOffset,
		ProjectedVertices,
		ClipBufferA,
		ClipBufferB,
		FocalLength,
		GuardBandX,
		GuardBandY,
		HALF_WIDTH,
		HALF_HEIGHT
	) :: number

	if ClippedVertexCount < 3 then
		return
	end

	const X0 = buffer.readf32(ProjectedVertices, 0) :: number
	const Y0 = buffer.readf32(ProjectedVertices, 4) :: number
	const InvZ0 = buffer.readf32(ProjectedVertices, 8) :: number

	for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
		const V1Offset = (ClippedTriangleIndex - 1) * 12 :: number
		const V2Offset = V1Offset + 12 :: number

		const X1 = buffer.readf32(ProjectedVertices, V1Offset) :: number
		const Y1 = buffer.readf32(ProjectedVertices, V1Offset + 4) :: number
		const InvZ1 = buffer.readf32(ProjectedVertices, V1Offset + 8) :: number

		const X2 = buffer.readf32(ProjectedVertices, V2Offset) :: number
		const Y2 = buffer.readf32(ProjectedVertices, V2Offset + 4) :: number
		const InvZ2 = buffer.readf32(ProjectedVertices, V2Offset + 8) :: number

		const Area = (X2 - X0) * (Y1 - Y0) - (Y2 - Y0) * (X1 - X0) :: number
		if Area <= MIN_TRIANGLE_AREA then
			continue
		end

		const MinX = math.max(0, math.min(X0, X1, X2)) :: number
		const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
		const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
		const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

		if MinX > MaxX or MinY > MaxY then
			continue
		end

		const SpanY = MaxY - MinY + 1 :: number
		const TriangleCost = Area * 0.5 + SpanY * 6 + 24 :: number

		local SmallestScore = WorkerScores[1] :: number
		local BestWorkerIdx = 1 :: number

		for WorkerIdx = 2, ACTOR_COUNT do
			const CandidateScore = WorkerScores[WorkerIdx] :: number
			if CandidateScore < SmallestScore then
				SmallestScore = CandidateScore
				BestWorkerIdx = WorkerIdx
			end
		end

		const RBOffset = WorkerOffsets[BestWorkerIdx] :: number
		if RBOffset + RENDER_BUFFER_LAYOUT_SIZE > WORKER_BUFFER_CAPACITY then
			continue
		end

		WorkerScores[BestWorkerIdx] = SmallestScore + TriangleCost
		WorkerOffsets[BestWorkerIdx] = RBOffset + RENDER_BUFFER_LAYOUT_SIZE

		const RenderBuffer = BufferTable[BestWorkerIdx] :: buffer
		const InvArea = 1 / Area :: number

		buffer.writei16(RenderBuffer, RBOffset, X0)
		buffer.writei16(RenderBuffer, RBOffset + 2, Y0)
		buffer.writef32(RenderBuffer, RBOffset + 4, InvZ0 * InvArea)

		buffer.writei16(RenderBuffer, RBOffset + 8, X1)
		buffer.writei16(RenderBuffer, RBOffset + 10, Y1)
		buffer.writef32(RenderBuffer, RBOffset + 12, InvZ1 * InvArea)

		buffer.writei16(RenderBuffer, RBOffset + 16, X2)
		buffer.writei16(RenderBuffer, RBOffset + 18, Y2)
		buffer.writef32(RenderBuffer, RBOffset + 20, InvZ2 * InvArea)

		buffer.writeu32(RenderBuffer, RBOffset + 24, PackedColor)
	end
end

-- ============================================================================
-- 1. INITIALIZATION & WORKER MESSAGE LISTENER
-- ============================================================================

-- Starter function
function Renderer.Init()
	if Initialized then
		return
	end

	const ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel
	const SelfActor = PlayerScripts:WaitForChild("Controller") :: Actor
	WorkerActors = PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: { Actor }

	-- Create Information Data for workers
	for i = 1, ACTOR_COUNT do
		BufferTable[i] = buffer.create(WORKER_BUFFER_CAPACITY)
		WorkerScores[i] = 0
		WorkerOffsets[i] = 0
	end

	-- Connecting Editable image to ImageLabel --
	const EditableImage = AssetService:CreateEditableImage({ Size = IMAGE_SIZE }) :: EditableImage
	ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

	CameraService:SetCameraHost()
	CameraService:SetCameraView(DEFAULT_CAMERA_VIEW)

	-- Wait for the camera to initialize
	task.spawn(function()
		-- Switch camera to scriptable so default controls don't override it
		Camera.CameraType = Enum.CameraType.Scriptable

		-- Set position: Y = -50000 (underground) or 50000 (sky)
		-- Looking straight ahead or down
		Camera.CFrame = CFrame.new(SCRIPTABLE_CAMERA_PARK_POSITION)
	end)

	SelfActor:BindToMessage(
		"Return Render Calculations",
		function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number)
			if FrameId ~= CurrentFrame then -- ignore stale frames
				return
			end

			if Received == 0 then
				buffer.copy(FinalPixel, 0, PixelBuffer, 0, TOTAL_PIXELS * 4)
				buffer.copy(FinalZ, 0, ZBuffer, 0, TOTAL_PIXELS * 4)
			else
				for i = 0, (TOTAL_PIXELS - 1) * 4, 4 do -- Overwrites the FinalZ and FinalPixel buffers
					const IncomingInvZ = buffer.readf32(ZBuffer, i) :: number
					if IncomingInvZ > buffer.readf32(FinalZ, i) then
						buffer.writef32(FinalZ, i, IncomingInvZ)
						buffer.writeu32(FinalPixel, i, buffer.readu32(PixelBuffer, i))
					end
				end
			end

			Received += 1

			-- If all workers have returned their data, write it to the image
			if Received == ACTOR_COUNT then
				EditableImage:WritePixelsBuffer(Vector2.zero, IMAGE_SIZE, FinalPixel)
				Received = 0
			end
		end
	)

	Initialized = true
end

-- ============================================================================
-- 2. GATHER DATA - SEND DATA TO WORKERS
-- ============================================================================

function Renderer.DrawFrame()
	if not Initialized then
		Renderer.Init()
	end

	-- Tables
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

	-- Configs
	const CamFOV = CamTable.CameraFOV :: number
	const FocalLength: number, GuardBandX: number, GuardBandY: number =
		RenderMath.GetProjectionParameters(CamFOV, WIDTH, HEIGHT)

	-- Pre loop Updates --
	CurrentFrame += 1
	Received = 0

	for i = 1, ACTOR_COUNT do
		WorkerScores[i] = 0
		WorkerOffsets[i] = 0
	end

	-- Loop through all parts
	for i = 1, EntityCount do
		const ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		const DirectionOffset = (i - 1) * ECS_DIRECTION_STRIDE :: number

		const FaceMask = RenderMath.GetPartCameraVertices(
			ECSPositionBuffer,
			ECSDirectionsBuffer,
			ECSSizeBuffer,
			ComponentOffset,
			DirectionOffset,
			ScreenVertices,
			CamPosVec,
			CamRightVec,
			CamUpVec,
			CamLookVec
		) :: number

		if FaceMask == 0 then
			continue
		end

		const PartColorR = buffer.readu8(ECSVisualBuffer, ComponentOffset) :: number
		const PartColorG = buffer.readu8(ECSVisualBuffer, ComponentOffset + 1) :: number
		const PartColorB = buffer.readu8(ECSVisualBuffer, ComponentOffset + 2) :: number

		-- Back (+Look, bit 0) or Front (-Look, bit 1)
		if bit32.btest(FaceMask, 3) then
			const DotL = vector.dot(ReadDirectionVec(DirectionOffset), SUN_VEC) :: number
			if bit32.btest(FaceMask, 1) then
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotL)
				)
				SubmitFaceQuad(0, 36, 24, 12, Color, FocalLength, GuardBandX, GuardBandY)
			else
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotL)
				)
				SubmitFaceQuad(48, 60, 72, 84, Color, FocalLength, GuardBandX, GuardBandY)
			end
		end

		-- Bottom (-Up, bit 2) or Top (+Up, bit 3)
		if bit32.btest(FaceMask, 12) then
			const DotU = vector.dot(ReadDirectionVec(DirectionOffset + 12), SUN_VEC) :: number
			if bit32.btest(FaceMask, 4) then
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotU)
				)
				SubmitFaceQuad(0, 12, 60, 48, Color, FocalLength, GuardBandX, GuardBandY)
			else
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotU)
				)
				SubmitFaceQuad(24, 36, 84, 72, Color, FocalLength, GuardBandX, GuardBandY)
			end
		end

		-- Left (-Right, bit 4) or Right (+Right, bit 5)
		if bit32.btest(FaceMask, 48) then
			const DotR = vector.dot(ReadDirectionVec(DirectionOffset + 24), SUN_VEC) :: number
			if bit32.btest(FaceMask, 16) then
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotR)
				)
				SubmitFaceQuad(0, 48, 84, 36, Color, FocalLength, GuardBandX, GuardBandY)
			else
				const Color = PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotR)
				)
				SubmitFaceQuad(12, 24, 72, 60, Color, FocalLength, GuardBandX, GuardBandY)
			end
		end
	end

	-- Sends the information to all workers
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const ByteCount = WorkerOffsets[i] :: number
		local PayloadBuffer = EmptyPayload
		if ByteCount > 0 then
			PayloadBuffer = buffer.create(ByteCount)
			buffer.copy(PayloadBuffer, 0, BufferTable[i], 0, ByteCount)
		end

		TargetActor:SendMessage(
			"Execute Rendering",
			PayloadBuffer,
			ByteCount,
			CurrentFrame
		)
	end
end

Renderer.RenderFrame = Renderer.DrawFrame

return Renderer
