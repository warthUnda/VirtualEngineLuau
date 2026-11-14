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
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const VerticeFile = require(ReplicatedStorage.Shared.Utilities.Render.Core.VerticeFile)
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath)
const TextureTable = require(ReplicatedStorage.Shared.Utilities.Render.Texture.TextureTable)
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
const PropertiesData = ECSStorage.PropertiesData

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
const ECS_PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const TEXTURE_SIZE = SystemsConfigs.TextureSize :: number
const TEXTURE_STUDS_PER_TILE = SystemsConfigs.TextureStudsPerTile :: number
const INV_TEXTURE_STUDS_PER_TILE = if TEXTURE_STUDS_PER_TILE > 0 then 1 / TEXTURE_STUDS_PER_TILE else 0 :: number
const TEXTURE_REGISTRY_FOLDER_NAME = SystemsConfigs.TextureRegistryFolderName :: string

local Initialized = false :: boolean
local Received = 0 :: number
local CurrentFrame = 0 :: number
local PendingTextureSyncFrames = 0 :: number
local LoadedTextureBuffers: { [number]: buffer }? = nil

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
const ECSPropertiesBuffer = PropertiesData.GetData() :: buffer
local ScreenVertices = buffer.create(VerticeFile.MaxShapeVertices * 12) :: buffer
local ProjectedVertices = buffer.create(12 * 20) :: buffer
local ClipBufferA = buffer.create(12 * 20) :: buffer
local ClipBufferB = buffer.create(12 * 20) :: buffer

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
		function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number, DirtyMinY: number, DirtyMaxY: number)
			if FrameId ~= CurrentFrame then -- ignore stale frames
				return
			end

			if Received == 0 then
				buffer.copy(FinalPixel, 0, PixelBuffer, 0, TOTAL_PIXELS * 4)
				buffer.copy(FinalZ, 0, ZBuffer, 0, TOTAL_PIXELS * 4)
			elseif DirtyMinY <= DirtyMaxY then
				const StartOffset = DirtyMinY * WIDTH * 4 :: number
				const EndOffset = ((DirtyMaxY + 1) * WIDTH - 1) * 4 :: number
				for i = StartOffset, EndOffset, 4 do -- Overwrites only the worker's dirty scanline rows
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

	-- Decode replicated Decal URLs from TextureRegistry into 64x64 buffers inside TextureTable and push them to workers
	local function DecodeRegistryEntry(Entry: Instance)
		if not Entry:IsA("StringValue") then
			return
		end

		const TextureId = tonumber(Entry.Name) :: number?
		if not TextureId then
			return
		end

		const RawUrl = Entry.Value :: string
		const TextureNameAttr = Entry:GetAttribute("TextureName")
		const TextureName = if typeof(TextureNameAttr) == "string" then TextureNameAttr else nil

		task.spawn(function()
			const _Buf: buffer, Updated: boolean = TextureTable.RegisterEntryWithId(TextureId, RawUrl, TextureName)
			if Updated or not LoadedTextureBuffers then
				LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
				PendingTextureSyncFrames = 3
			end
		end)
	end

	local function HookTextureRegistry(RegistryFolder: Instance)
		for _, Entry: Instance in ipairs(RegistryFolder:GetChildren()) do
			DecodeRegistryEntry(Entry)
		end

		RegistryFolder.ChildAdded:Connect(DecodeRegistryEntry)
	end

	const ExistingRegistry = ReplicatedStorage:FindFirstChild(TEXTURE_REGISTRY_FOLDER_NAME)
	if ExistingRegistry then
		HookTextureRegistry(ExistingRegistry)
	else
		ReplicatedStorage.ChildAdded:Connect(function(Child: Instance)
			if Child.Name == TEXTURE_REGISTRY_FOLDER_NAME then
				HookTextureRegistry(Child)
			end
		end)
	end

	LoadedTextureBuffers = TextureTable.GetAllCachedBuffers()
	PendingTextureSyncFrames = 3

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

	if PendingTextureSyncFrames > 0 and LoadedTextureBuffers then
		PendingTextureSyncFrames -= 1
		for _, TargetActor: Actor in ipairs(WorkerActors) do
			TargetActor:SendMessage("Set Texture Table", LoadedTextureBuffers :: { [number]: buffer }, TEXTURE_SIZE, TEXTURE_SIZE)
		end
	end

	for i = 1, ACTOR_COUNT do
		WorkerScores[i] = 0
		WorkerOffsets[i] = 0
	end

	-- Loop through all parts
	for i = 1, EntityCount do
		const ComponentOffset = (i - 1) * ECS_COMPONENT_STRIDE :: number
		const DirectionOffset = (i - 1) * ECS_DIRECTION_STRIDE :: number
		const PropertiesOffset = (i - 1) * ECS_PROPERTIES_STRIDE :: number

		const PropertiesRegister = buffer.readu32(ECSPropertiesBuffer, PropertiesOffset) :: number
		const EntityShapeId = ECSMain.GetEntityShapeId(PropertiesRegister) :: number
		const EntityTextureId = ECSMain.GetEntityTextureId(PropertiesRegister) :: number
		const ShapeMesh = VerticeFile.ShapeData[EntityShapeId] or VerticeFile.ShapeData[0]

		-- If untextured (EntityTextureId == 0), shade with the part's color; if textured, use white base so the decal's colors are preserved
		local PartColorR = 255 :: number
		local PartColorG = 255 :: number
		local PartColorB = 255 :: number
		if EntityTextureId == 0 then
			PartColorR = buffer.readu8(ECSVisualBuffer, ComponentOffset) :: number
			PartColorG = buffer.readu8(ECSVisualBuffer, ComponentOffset + 1) :: number
			PartColorB = buffer.readu8(ECSVisualBuffer, ComponentOffset + 2) :: number
		end

		local TileScaleX = 1 :: number
		local TileScaleY = 1 :: number
		local TileScaleZ = 1 :: number
		if INV_TEXTURE_STUDS_PER_TILE > 0 then
			TileScaleX = math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8)
			TileScaleY = math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 4) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8)
			TileScaleZ = math.clamp(math.floor(buffer.readf32(ECSSizeBuffer, ComponentOffset + 8) * INV_TEXTURE_STUDS_PER_TILE + 0.5), 1, 8)
		end

		const IsVisible: boolean, LocalCameraPos: vector, HalfSize: vector, LocalSun: vector =
			RenderMath.TransformShapeCameraVertices(
				ECSPositionBuffer,
				ECSDirectionsBuffer,
				ECSSizeBuffer,
				ComponentOffset,
				DirectionOffset,
				ShapeMesh.LocalVertices,
				ShapeMesh.VertexCount,
				ScreenVertices,
				CamPosVec,
				CamRightVec,
				CamUpVec,
				CamLookVec,
				SUN_VEC
			)

		if not IsVisible then
			continue
		end

		if ShapeMesh.IsAxisAligned then
			for _, Face in ipairs(ShapeMesh.Faces) do
				const ScaledPoint = Face.PointOnFace * HalfSize
				if vector.dot(LocalCameraPos - ScaledPoint, Face.Normal) <= -1e-3 then
					continue
				end

				const FaceSunDot = vector.dot(Face.Normal, LocalSun) :: number
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, FaceSunDot)
				)

				RenderControllerHelper.SubmitFace(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					Face.V0ByteOffset,
					Face.V1ByteOffset,
					Face.V2ByteOffset,
					Face.V3ByteOffset,
					TileScaleX,
					TileScaleY,
					Color,
					EntityTextureId,
					FocalLength,
					GuardBandX,
					GuardBandY
				)
			end
		else
			const InvHalfSize = vector.create(
				if HalfSize.x > 1e-4 then 1 / HalfSize.x else 1,
				if HalfSize.y > 1e-4 then 1 / HalfSize.y else 1,
				if HalfSize.z > 1e-4 then 1 / HalfSize.z else 1
			)

			for _, Face in ipairs(ShapeMesh.Faces) do
				const ScaledPoint = Face.PointOnFace * HalfSize
				const ScaledLocalNormal = Face.Normal * InvHalfSize
				if vector.dot(LocalCameraPos - ScaledPoint, ScaledLocalNormal) <= -1e-3 then
					continue
				end

				const WorldSpaceLocalNormal = vector.normalize(ScaledLocalNormal)
				const FaceSunDot = vector.dot(WorldSpaceLocalNormal, LocalSun) :: number
				const Color = RenderControllerHelper.PackShadedColor(
					PartColorR,
					PartColorG,
					PartColorB,
					AMBIENT_LIGHT + DIFFUSE_LIGHT * math.max(0, FaceSunDot)
				)

				RenderControllerHelper.SubmitFace(
					ScreenVertices,
					ProjectedVertices,
					ClipBufferA,
					ClipBufferB,
					WorkerScores,
					WorkerOffsets,
					BufferTable,
					Face.V0ByteOffset,
					Face.V1ByteOffset,
					Face.V2ByteOffset,
					Face.V3ByteOffset,
					TileScaleX,
					TileScaleY,
					Color,
					EntityTextureId,
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
		const PayloadBuffer = if ByteCount > 0 then BufferTable[i] else EmptyPayload

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
