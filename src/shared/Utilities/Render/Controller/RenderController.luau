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
const RenderConfigs = require(ReplicatedStorage.Shared.Utilities.Render.RenderConfigs)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const MathModule = require(ReplicatedStorage.Shared.Utilities.Render.Core.MathModule)

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
const WIDTH: number, HEIGHT: number = RenderConfigs.GetDimensions2D()
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const SUN_DIRECTION = SystemsConfigs.SunDirection :: Vector3
const SUN_X: number, SUN_Y: number, SUN_Z: number = SUN_DIRECTION.X, SUN_DIRECTION.Y, SUN_DIRECTION.Z
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number
const ACTOR_COUNT = RenderConfigs.GetActorCount() :: number
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
local OffsetBuffer = buffer.create(ACTOR_COUNT * 4) :: buffer
local BufferTable = {} :: { buffer }
local ScoreBuffer = buffer.create(ACTOR_COUNT * 4) :: buffer

const PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: buffer

-- Buffers
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const FinalZ = buffer.create(TOTAL_PIXELS * 4) :: buffer
local FaceIllumination = buffer.create(12 * 4) :: buffer
const ECSPositionBuffer = PositionData.GetData() :: buffer
const ECSSizeBuffer = SizeData.GetData() :: buffer
const ECSDirectionsBuffer = DirectionsData.GetData() :: buffer
const ECSVisualBuffer = VisualData.GetData() :: buffer
local ScreenVertices = buffer.create(8 * 12) :: buffer
local ProjectedVertices = buffer.create(12 * 12) :: buffer
local ClipBufferA = buffer.create(12 * 12) :: buffer
local ClipBufferB = buffer.create(12 * 12) :: buffer

local Renderer = {}

local function PackShadedColor(R: number, G: number, B: number, Illumination: number): number
	return bit32.bor(
		math.floor(R * Illumination),
		bit32.lshift(math.floor(G * Illumination), 8),
		bit32.lshift(math.floor(B * Illumination), 16),
		0xFF000000
	)
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
		buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
		buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
	end

	-- Connecting Editable image to ImageLabel --
	const EditableImage = AssetService:CreateEditableImage({ Size = Vector2.new(WIDTH, HEIGHT) }) :: EditableImage
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
				EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), FinalPixel)
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

	const CamPosX: number, CamPosY: number, CamPosZ: number = CamPosition.X, CamPosition.Y, CamPosition.Z
	const CamRightX: number, CamRightY: number, CamRightZ: number = CamRight.X, CamRight.Y, CamRight.Z
	const CamUpX: number, CamUpY: number, CamUpZ: number = CamUp.X, CamUp.Y, CamUp.Z
	const CamLookX: number, CamLookY: number, CamLookZ: number = CamLook.X, CamLook.Y, CamLook.Z

	-- Configs
	const CamFOV = CamTable.CameraFOV :: number
	const FocalLength: number, GuardBandX: number, GuardBandY: number =
		RenderMath.GetProjectionParameters(CamFOV, WIDTH, HEIGHT)

	-- Pre loop Updates --
	CurrentFrame += 1
	Received = 0

	for i = 1, ACTOR_COUNT do
		buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
	end

	-- Loop through all parts
	for i = 1, EntityCount do
		local ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		local DirectionOffset = (i - 1) * ECS_DIRECTION_STRIDE :: number

		const PosX = buffer.readf32(ECSPositionBuffer, ComponentOffset) :: number
		const PosY = buffer.readf32(ECSPositionBuffer, ComponentOffset + 4) :: number
		const PosZ = buffer.readf32(ECSPositionBuffer, ComponentOffset + 8) :: number

		const LookX = buffer.readf32(ECSDirectionsBuffer, DirectionOffset) :: number
		const LookY = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 4) :: number
		const LookZ = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 8) :: number

		const UpX = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 12) :: number
		const UpY = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 16) :: number
		const UpZ = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 20) :: number

		const RightX = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 24) :: number
		const RightY = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 28) :: number
		const RightZ = buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 32) :: number

		const SizeX = buffer.readf32(ECSSizeBuffer, ComponentOffset) :: number
		const SizeY = buffer.readf32(ECSSizeBuffer, ComponentOffset + 4) :: number
		const SizeZ = buffer.readf32(ECSSizeBuffer, ComponentOffset + 8) :: number

		-- 2.5 miliseconds part here:

		-- Updates
		if
			not RenderMath.GetPartCameraVertices(
				PosX,
				PosY,
				PosZ,
				LookX,
				LookY,
				LookZ,
				UpX,
				UpY,
				UpZ,
				RightX,
				RightY,
				RightZ,
				SizeX,
				SizeY,
				SizeZ,
				ScreenVertices,
				CamPosX,
				CamPosY,
				CamPosZ,
				CamRightX,
				CamRightY,
				CamRightZ,
				CamUpX,
				CamUpY,
				CamUpZ,
				CamLookX,
				CamLookY,
				CamLookZ
			)
		then
			continue
		end

		const PartColorR = buffer.readu8(ECSVisualBuffer, ComponentOffset) :: number
		const PartColorG = buffer.readu8(ECSVisualBuffer, ComponentOffset + 1) :: number
		const PartColorB = buffer.readu8(ECSVisualBuffer, ComponentOffset + 2) :: number

		const DotL = LookX * SUN_X + LookY * SUN_Y + LookZ * SUN_Z :: number
		const DotU = UpX * SUN_X + UpY * SUN_Y + UpZ * SUN_Z :: number
		const DotR = RightX * SUN_X + RightY * SUN_Y + RightZ * SUN_Z :: number

		const PackedBack =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotL))
		const PackedFront =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotL))
		const PackedBottom =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotU))
		const PackedTop =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotU))
		const PackedLeft =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -DotR))
		const PackedRight =
			PackShadedColor(PartColorR, PartColorG, PartColorB, AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, DotR))

		buffer.writeu32(FaceIllumination, 0, PackedBack)
		buffer.writeu32(FaceIllumination, 4, PackedBack)
		buffer.writeu32(FaceIllumination, 8, PackedFront)
		buffer.writeu32(FaceIllumination, 12, PackedFront)
		buffer.writeu32(FaceIllumination, 16, PackedBottom)
		buffer.writeu32(FaceIllumination, 20, PackedBottom)
		buffer.writeu32(FaceIllumination, 24, PackedTop)
		buffer.writeu32(FaceIllumination, 28, PackedTop)
		buffer.writeu32(FaceIllumination, 32, PackedLeft)
		buffer.writeu32(FaceIllumination, 36, PackedLeft)
		buffer.writeu32(FaceIllumination, 40, PackedRight)
		buffer.writeu32(FaceIllumination, 44, PackedRight)

		-- 2.5 miliseconds part here:

		-- Loop through all triangles
		-- 1.49 miliseconds part here:

		local MemoryOffset = 0 :: number

		for TriangleIndex = 1, 12 do
			local V0TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset) :: number
			MemoryOffset += 1
			local V1TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset) :: number
			MemoryOffset += 1
			local V2TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset) :: number
			MemoryOffset += 1

			local ClippedVertexCount = RenderMath.ClipAndProjectTriangle(
				ScreenVertices,
				V0TRI,
				V1TRI,
				V2TRI,
				ProjectedVertices,
				ClipBufferA,
				ClipBufferB,
				FocalLength,
				GuardBandX,
				GuardBandY,
				WIDTH,
				HEIGHT
			) :: number

			if ClippedVertexCount < 3 then
				continue
			end

			const PackedColor = buffer.readu32(FaceIllumination, (TriangleIndex - 1) * 4) :: number
			const X0 = buffer.readf32(ProjectedVertices, 0) :: number
			const Y0 = buffer.readf32(ProjectedVertices, 4) :: number
			const InvZ0 = buffer.readf32(ProjectedVertices, 8) :: number

			for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
				const V1Offset = (ClippedTriangleIndex - 1) * 12 :: number
				const V2Offset = V1Offset + 12 :: number

				-- Variables
				const X1 = buffer.readf32(ProjectedVertices, V1Offset) :: number
				const Y1 = buffer.readf32(ProjectedVertices, V1Offset + 4) :: number
				const InvZ1 = buffer.readf32(ProjectedVertices, V1Offset + 8) :: number

				const X2 = buffer.readf32(ProjectedVertices, V2Offset) :: number
				const Y2 = buffer.readf32(ProjectedVertices, V2Offset + 4) :: number
				const InvZ2 = buffer.readf32(ProjectedVertices, V2Offset + 8) :: number

				const MinX = math.max(0, math.min(X0, X1, X2)) :: number
				const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
				const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
				const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

				local Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2) :: number
				if Area <= MIN_TRIANGLE_AREA then
					continue
				end

				if MinX > MaxX or MinY > MaxY then
					continue
				end

				const CX0 = math.clamp(X0, MinX, MaxX) :: number
				const CX1 = math.clamp(X1, MinX, MaxX) :: number
				const CX2 = math.clamp(X2, MinX, MaxX) :: number
				const SpanY = MaxY - MinY + 1 :: number
				const ScannedPixels = ((CX0 + CX1 + CX2 - MinX * 3) * 0.5 + 1) * SpanY :: number
				const CoveredPixels = math.min(ScannedPixels, Area * 0.5) :: number
				local Result = ScannedPixels + CoveredPixels + SpanY * 4 + 32 :: number

				local SmallestValue = buffer.readf32(ScoreBuffer, 0) :: number
				local SVIndex = 1 :: number
				local SVOffset = 0 :: number

				-- Find the smallest value then increase it
				for WorkerIdx = 2, ACTOR_COUNT do
					const ScoreOffset = (WorkerIdx - 1) * 4 :: number
					const Score = buffer.readf32(ScoreBuffer, ScoreOffset) :: number

					if Score < SmallestValue then
						SmallestValue = Score
						SVIndex = WorkerIdx
						SVOffset = ScoreOffset
					end
				end

				const RBOffset = buffer.readu32(OffsetBuffer, SVOffset) :: number -- Render buffer memory offset
				if RBOffset + RENDER_BUFFER_LAYOUT_SIZE > WORKER_BUFFER_CAPACITY then
					continue
				end

				-- Apply changes and create a information buffer for workers
				buffer.writef32(ScoreBuffer, SVOffset, SmallestValue + Result)
				const RenderBuffer = BufferTable[SVIndex] :: buffer
				const InvArea = 1 / Area :: number

				local RenderResult = BufferHelper.CreateRenderBuffer(
					RenderBuffer,
					RBOffset,
					X0,
					Y0,
					InvZ0 * InvArea,
					X1,
					Y1,
					InvZ1 * InvArea,
					X2,
					Y2,
					InvZ2 * InvArea,
					PackedColor
				) :: number

				buffer.writeu32(OffsetBuffer, SVOffset, RenderResult)
			end
		end
	end

	-- 1.49 miliseconds part here:

	-- Sends the information to all workers workers
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const RenderBuffer = BufferTable[i] :: buffer
		const ByteCount = buffer.readu32(OffsetBuffer, (i - 1) * 4) :: number
		const PayloadBuffer = buffer.create(ByteCount) :: buffer
		if ByteCount > 0 then
			buffer.copy(PayloadBuffer, 0, RenderBuffer, 0, ByteCount)
		end

		TargetActor:SendMessage(
			"Execute Rendering",
			PayloadBuffer,
			ByteCount,
			CurrentFrame
		)
	end

	for i = 1, ACTOR_COUNT do
		buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
	end
end

Renderer.RenderFrame = Renderer.DrawFrame

return Renderer
