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

const Camera = workspace.CurrentCamera :: Camera

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const RenderControllerHelper = require(script.Parent.RenderControllerHelper)

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
const IMAGE_SIZE = Vector2.new(WIDTH, HEIGHT) :: Vector2
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const SUN_DIRECTION = SystemsConfigs.SunDirection :: Vector3
const SUN_VEC = vector.create(SUN_DIRECTION.X, SUN_DIRECTION.Y, SUN_DIRECTION.Z)
const AMBIENT_LIGHT = SystemsConfigs.AmbientLight :: number
const DIFFUSE_LIGHT = 1 - AMBIENT_LIGHT :: number
const ACTOR_COUNT = SystemsConfigs.ActorCount :: number
const WORKER_BUFFER_MULTIPLIER = SystemsConfigs.WorkerBufferMultiplier :: number
const WORKER_BUFFER_CAPACITY = TOTAL_PIXELS * WORKER_BUFFER_MULTIPLIER :: number
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
	WorkerActors = (PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: any) :: { Actor }

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
					const IncomingInverseZ = buffer.readf32(ZBuffer, i) :: number
					if IncomingInverseZ > buffer.readf32(FinalZ, i) then
						buffer.writef32(FinalZ, i, IncomingInverseZ)
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
			const LookSunDot = vector.dot(
				RenderControllerHelper.ReadDirectionVec(ECSDirectionsBuffer, DirectionOffset),
				SUN_VEC
			) :: number
			if bit32.btest(FaceMask, 1) then
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, LookSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					0,
					36,
					24,
					12,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			else
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -LookSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					48,
					60,
					72,
					84,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			end
		end

		-- Bottom (-Up, bit 2) or Top (+Up, bit 3)
		if bit32.btest(FaceMask, 12) then
			const UpSunDot = vector.dot(
				RenderControllerHelper.ReadDirectionVec(ECSDirectionsBuffer, DirectionOffset + 12),
				SUN_VEC
			) :: number
			if bit32.btest(FaceMask, 4) then
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -UpSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					0,
					12,
					60,
					48,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			else
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, UpSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					24,
					36,
					84,
					72,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			end
		end

		-- Left (-Right, bit 4) or Right (+Right, bit 5)
		if bit32.btest(FaceMask, 48) then
			const RightSunDot = vector.dot(
				RenderControllerHelper.ReadDirectionVec(ECSDirectionsBuffer, DirectionOffset + 24),
				SUN_VEC
			) :: number
			if bit32.btest(FaceMask, 16) then
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, -RightSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					0,
					48,
					84,
					36,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			else
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, RightSunDot)
				)
				RenderControllerHelper.SubmitFaceQuad(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					12,
					24,
					72,
					60,
					Color,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
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
