--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const AssetService = game:GetService("AssetService") :: AssetService
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const Player = Players.LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

const ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel

const Camera = workspace.CurrentCamera :: Camera

const SelfActor = script.Parent :: Actor
const WorkerActors = PlayerScripts:WaitForChild("WorkerFolder"):GetChildren() :: { Actor }

-- Modules --
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.Render.Core.BufferHelper) :: ModuleScript
const RenderConfigs = require(ReplicatedStorage.Shared.Utilities.Render.RenderConfigs) :: ModuleScript
const RenderMath = require(ReplicatedStorage.Shared.Utilities.Render.Core.RenderMath) :: ModuleScript
const MathModule = require(ReplicatedStorage.Shared.Utilities.Render.Core.MathModule) :: ModuleScript

const CameraStore = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraStore")
) :: ModuleScript

const CameraService = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraService")
) :: ModuleScript

-- The controller renders from the ECS cloned into its own Actor. Each Actor runs in a separate
-- Luau VM, so reaching into PlayerScripts here would resolve to a different copy of these modules
-- that nothing ever writes to (which reads back as an entity count of 0).
const ObjectStorage = SelfActor:WaitForChild("ObjectStorage") :: Folder

const ECSData = require(ObjectStorage:WaitForChild("ECSData")) :: ModuleScript
const PositionData = require(ObjectStorage:WaitForChild("PositionData")) :: ModuleScript
const SizeData = require(ObjectStorage:WaitForChild("SizeData")) :: ModuleScript
const DirectionsData = require(ObjectStorage:WaitForChild("DirectionsData")) :: ModuleScript
const VisualData = require(ObjectStorage:WaitForChild("VisualData")) :: ModuleScript

-- Configs --
const WIDTH: number, HEIGHT: number = RenderConfigs.GetDimensions2D()
const TOTAL_PIXELS = WIDTH * HEIGHT :: number
const SUN_DIRECTION = Vector3.new(-0.4, 0.85, -0.35).Unit :: Vector3
const AMBIENT_LIGHT = 0.3 :: number
const ACTOR_COUNT = RenderConfigs.GetActorCount() :: number

const ECS_COMPONENT_STRIDE = 12 :: number
const ECS_DIRECTION_STRIDE = 36 :: number

local Received = 0 :: number
local CurrentFrame = 0 :: number

-- Tables --
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

local function ReadProjectedVertex(VertexIndex: number): Vector3
	local Offset = (VertexIndex - 1) * 12 :: number
	return Vector3.new(
		buffer.readf32(ProjectedVertices, Offset),
		buffer.readf32(ProjectedVertices, Offset + 4),
		buffer.readf32(ProjectedVertices, Offset + 8)
	)
end

-- Create Information Data for workers
for i = 1, ACTOR_COUNT do
	BufferTable[i] = buffer.create(TOTAL_PIXELS * 32)
	buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
	buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
end

-- Connecting Editable image to ImageLabel --
const EditableImage = AssetService:CreateEditableImage({ Size = Vector2.new(WIDTH, HEIGHT) }) :: EditableImage
ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

CameraService:SetCameraHost()
CameraService:SetCameraView("FirstPerson")

-- Wait for the camera to initialize
task.spawn(function()
	-- Switch camera to scriptable so default controls don't override it
	Camera.CameraType = Enum.CameraType.Scriptable

	-- Set position: Y = -50000 (underground) or 50000 (sky)
	-- Looking straight ahead or down
	const TargetPosition = Vector3.new(0, -50000, 0) :: Vector3
	Camera.CFrame = CFrame.new(TargetPosition)
end)

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA
-- ============================================================================

SelfActor:BindToMessage("Return Render Calculations", function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number)
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
end)

-- ============================================================================
-- 2. GATHER DATA - SEND DATA TO WORKERS
-- ============================================================================

RunService.RenderStepped:Connect(function()
	-- Tables
	local EntityCount = ECSData.GetCounts().EntityECSCount :: number

	const CamTable = CameraStore.GetCameraTable()

	const CamPosition = CameraStore.GetCameraPosition() :: Vector3
	const CamRight = CameraStore.GetCameraRight() :: Vector3
	const CamUp = CameraStore.GetCameraUp() :: Vector3
	const CamLook = CameraStore.GetCameraLook() :: Vector3

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

		const TargetPosition = Vector3.new(
			buffer.readf32(ECSPositionBuffer, ComponentOffset),
			buffer.readf32(ECSPositionBuffer, ComponentOffset + 4),
			buffer.readf32(ECSPositionBuffer, ComponentOffset + 8)
		) :: Vector3

		const LookVector = Vector3.new(
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 4),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 8)
		) :: Vector3
		const UpVector = Vector3.new(
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 12),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 16),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 20)
		) :: Vector3
		const RightVector = Vector3.new(
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 24),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 28),
			buffer.readf32(ECSDirectionsBuffer, DirectionOffset + 32)
		) :: Vector3

		const TargetSize = Vector3.new(
			buffer.readf32(ECSSizeBuffer, ComponentOffset),
			buffer.readf32(ECSSizeBuffer, ComponentOffset + 4),
			buffer.readf32(ECSSizeBuffer, ComponentOffset + 8)
		) :: Vector3

		const PartColorR = buffer.readu8(ECSVisualBuffer, ComponentOffset) :: number
		const PartColorG = buffer.readu8(ECSVisualBuffer, ComponentOffset + 1) :: number
		const PartColorB = buffer.readu8(ECSVisualBuffer, ComponentOffset + 2) :: number

		-- 2.5 miliseconds part here:

		-- Updates
		if
			not RenderMath.GetPartCameraVertices(
				TargetPosition,
				LookVector,
				UpVector,
				RightVector,
				TargetSize,
				ScreenVertices,
				CamPosition,
				CamRight,
				CamUp,
				CamLook
			)
		then
			continue
		end

		const DotL = LookVector:Dot(SUN_DIRECTION) :: number
		const DotU = UpVector:Dot(SUN_DIRECTION) :: number
		const DotR = RightVector:Dot(SUN_DIRECTION) :: number

		const IllumBack = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, DotL) :: number
		const IllumFront = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, -DotL) :: number
		const IllumBottom = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, -DotU) :: number
		const IllumTop = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, DotU) :: number
		const IllumLeft = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, -DotR) :: number
		const IllumRight = AMBIENT_LIGHT + (1 - AMBIENT_LIGHT) * math.max(0, DotR) :: number

		buffer.writef32(FaceIllumination, 0, IllumBack)
		buffer.writef32(FaceIllumination, 4, IllumBack)
		buffer.writef32(FaceIllumination, 8, IllumFront)
		buffer.writef32(FaceIllumination, 12, IllumFront)
		buffer.writef32(FaceIllumination, 16, IllumBottom)
		buffer.writef32(FaceIllumination, 20, IllumBottom)
		buffer.writef32(FaceIllumination, 24, IllumTop)
		buffer.writef32(FaceIllumination, 28, IllumTop)
		buffer.writef32(FaceIllumination, 32, IllumLeft)
		buffer.writef32(FaceIllumination, 36, IllumLeft)
		buffer.writef32(FaceIllumination, 40, IllumRight)
		buffer.writef32(FaceIllumination, 44, IllumRight)

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

			local Illumination = buffer.readf32(FaceIllumination, (TriangleIndex - 1) * 4) :: number
			local ShadedR = math.floor(PartColorR * Illumination) :: number
			local ShadedG = math.floor(PartColorG * Illumination) :: number
			local ShadedB = math.floor(PartColorB * Illumination) :: number

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

			const V0 = ReadProjectedVertex(1)
			const X0: number, Y0: number = V0.X, V0.Y

			for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
				const V1 = ReadProjectedVertex(ClippedTriangleIndex)
				const V2 = ReadProjectedVertex(ClippedTriangleIndex + 1)

				-- Variables
				const X1: number, Y1: number = V1.X, V1.Y
				const X2: number, Y2: number = V2.X, V2.Y

				const MinX = math.max(0, math.min(X0, X1, X2)) :: number
				const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
				const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
				const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

				local Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2) :: number
				if Area <= 0.1 then
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
				for i = 2, ACTOR_COUNT do
					const ScoreOffset = (i - 1) * 4 :: number
					const Score = buffer.readf32(ScoreBuffer, ScoreOffset) :: number

					if Score < SmallestValue then
						SmallestValue = Score
						SVIndex = i
						SVOffset = ScoreOffset
					end
				end

				-- Apply changes and create a information buffer for workers
				buffer.writef32(ScoreBuffer, SVOffset, SmallestValue + Result)
				const RBOffset = buffer.readu32(OffsetBuffer, SVOffset) :: number -- Render buffer memory offset
				const RenderBuffer = BufferTable[SVIndex] :: buffer

				local RenderResult = BufferHelper.CreateRenderBuffer(
					RenderBuffer,
					RBOffset,
					V0,
					V1,
					V2,
					ShadedR,
					ShadedG,
					ShadedB
				) :: number

				buffer.writeu32(OffsetBuffer, SVOffset, RenderResult)
			end
		end
	end

	-- 1.49 miliseconds part here:

	-- Sends the information to all workers workers
	for i, TargetActor: Actor in ipairs(WorkerActors) do
		const RenderBuffer = BufferTable[i] :: buffer

		TargetActor:SendMessage(
			"Execute Rendering",
			RenderBuffer,
			buffer.readu32(OffsetBuffer, (i - 1) * 4),
			CurrentFrame
		)
	end

	for i = 1, ACTOR_COUNT do
		buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
	end
end)
