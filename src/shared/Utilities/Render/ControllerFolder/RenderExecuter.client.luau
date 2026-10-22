--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const AssetService = game:GetService("AssetService") :: AssetService
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const Player = game:GetService("Players").LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

const ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel

const Camera = workspace.CurrentCamera :: Camera

const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript

const RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.RenderConfigs) :: ModuleScript
const RenderMath = require(game.ReplicatedStorage.Shared.Utilities.Render.RenderMath) :: ModuleScript
const MathModule = require(game.ReplicatedStorage.Shared.Utilities.Functions.MathModule)

const CameraStore = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("ControllerFolder")
		:WaitForChild("CameraStore")
) :: ModuleScript

local CameraService = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("ControllerFolder")
		:WaitForChild("CameraService")
)

const PartStore = require(script.Parent.PartStores) :: ModuleScript

-- Configs --
const WIDTH: number, HEIGHT: number = RenderConfigs.ReturnDimensions2D()
const TOTAL_PIXELS = WIDTH * HEIGHT :: number

const ActorCount = RenderConfigs.GetActorCount() :: number

local Received = 0 :: number
local CurrentFrame = 0 :: number

-- Tables --
local OffsetBuffer = buffer.create(ActorCount * 4) :: buffer
local BufferTable = {} :: { buffer }
local ScoreBuffer = buffer.create(ActorCount * 4) :: buffer

local PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: buffer
local SphereVertices = RenderConfigs.GetSphereVertices() :: { Vector3 }

-- Buffers
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const FinalZ = buffer.create(TOTAL_PIXELS * 4) :: buffer

-- Create Information Data for workers
for i = 1, ActorCount do
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
	local targetPosition = Vector3.new(0, -50000, 0)
	Camera.CFrame = CFrame.new(targetPosition)
end)

-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA
-- ============================================================================

SelfActor:BindToMessage("Return Render Calculations", function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number)
	if FrameId ~= CurrentFrame then -- ignore stale frames
		return
	end

	for i = 1, TOTAL_PIXELS do -- Overwrites the FinalZ and FinalPixel buffers
		const Offset = (i - 1) * 4 :: number
		if buffer.readf32(ZBuffer, Offset) < buffer.readf32(FinalZ, Offset) then
			buffer.writef32(FinalZ, Offset, buffer.readf32(ZBuffer, Offset))
			buffer.writeu32(FinalPixel, Offset, buffer.readu32(PixelBuffer, Offset))
		end
	end

	Received += 1

	-- If all workers have returned their data, write it to the image
	if Received == ActorCount then
		EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), FinalPixel)
		Received = 0
	end
end)

-- ============================================================================
-- 2. GATHER DATA - SEND DATA TO WORKERS
-- ============================================================================

RunService.RenderStepped:Connect(function()
	-- Tables
	const PartSizeArray = PartStore.ReturnSizeArray() :: { CFrame }
	const PartPositionArray = PartStore.ReturnPositionArray() :: { Vector3 }

	local PartLookVectorArray = PartStore.ReturnLookVectorArray() :: { Vector3 }
	local PartUpVectorArray = PartStore.ReturnUpVectorArray() :: { Vector3 }
	local PartRightVectorArray = PartStore.ReturnRightVectorArray() :: { Vector3 }

	local ColorArrayR = PartStore.ReturnColorArrayR() :: {}
	local ColorArrayG = PartStore.ReturnColorArrayG() :: {}
	local ColorArrayB = PartStore.ReturnColorArrayB() :: {}

	const CamTable = CameraStore.ReturnCameraTable()
	const ScreenVertices = {} :: { Vector3 }
	const ProjectedVertices = {} :: { Vector3 }
	const ClipBufferA = {} :: { Vector3 }
	const ClipBufferB = {} :: { Vector3 }

	local CamPosition = CameraStore.ReturnCameraPosition()
	local CamRight = CameraStore.ReturnCameraRight()
	local CamUp = CameraStore.ReturnCameraUp()
	local CamLook = CameraStore.ReturnCameraLook()

	-- Configs
	const CamCFrame = CamTable.CameraCFrame :: CFrame
	const CamFOV = CamTable.CameraFOV :: number

	-- Pre loop Updates --
	BufferHelper.ClearBuffers(TOTAL_PIXELS, FinalPixel, FinalZ)

	CurrentFrame += 1
	Received = 0

	for i = 1, ActorCount do
		buffer.writef32(ScoreBuffer, (i - 1) * 4, 0)
	end

	-- Loop through all parts
	for i = 1, #PartPositionArray do
		const TargetPosition = PartPositionArray[i] :: Vector3
		local LookVector = PartLookVectorArray[i] :: Vector3
		local UpVector = PartUpVectorArray[i] :: Vector3
		local RightVector = PartRightVectorArray[i] :: Vector3
		const TargetSize = PartSizeArray[i] :: Vector3

		const PartColorR = ColorArrayR[i] :: number
		const PartColorG = ColorArrayG[i] :: number
		const PartColorB = ColorArrayB[i] :: number

		if not TargetPosition and TargetSize or PartColorR == nil or PartColorG == nil or PartColorB == nil then
			continue
		end

		-- Variables
		const R = math.floor(PartColorR * 255) :: number
		const G = math.floor(PartColorG * 255) :: number
		const B = math.floor(PartColorB * 255) :: number

		-- Updates
		RenderMath.GetPartCameraVertices(
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

		-- Loop through all triangles

		local MemoryOffset = 0
		for TriangleIndex = 1, 12 do
			local V0TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1
			local V1TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1
			local V2TRI = buffer.readu8(PART_TRIANGLES, MemoryOffset)
			MemoryOffset += 1

			local ClippedVertexCount = RenderMath.ClipAndProjectTriangle(
				ScreenVertices[V0TRI],
				ScreenVertices[V1TRI],
				ScreenVertices[V2TRI],
				ProjectedVertices,
				ClipBufferA,
				ClipBufferB,
				CamFOV,
				WIDTH,
				HEIGHT
			)

			for ClippedTriangleIndex = 2, ClippedVertexCount - 1 do
				const V0 = ProjectedVertices[1] :: Vector3
				const V1 = ProjectedVertices[ClippedTriangleIndex] :: Vector3
				const V2 = ProjectedVertices[ClippedTriangleIndex + 1] :: Vector3

				-- Variables
				const X0: number, Y0: number = V0.X, V0.Y
				const X1: number, Y1: number = V1.X, V1.Y
				const X2: number, Y2: number = V2.X, V2.Y

				const MinX = math.max(0, math.min(X0, X1, X2)) :: number
				const MaxX = math.min(WIDTH - 1, math.max(X0, X1, X2)) :: number
				const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
				const MaxY = math.min(HEIGHT - 1, math.max(Y0, Y1, Y2)) :: number

				local Area = MathModule.EdgeFunction(X0, Y0, X1, Y1, X2, Y2)
				if Area <= 0.1 then
					continue
				end

				if MinX > MaxX or MinY > MaxY then
					continue
				end

				local Result = (MaxX - MinX + 1) * (MaxY - MinY + 1) :: number

				local SmallestValue = math.huge :: number
				local SVIndex = 0 :: number

				-- Find the smallest value then increase it
				for i = 1, ActorCount do
					const Score = buffer.readf32(ScoreBuffer, (i - 1) * 4) :: number

					if Score <= SmallestValue then
						SmallestValue = Score
						SVIndex = i
					end
				end

				-- Apply changes and create a information buffer for workers
				buffer.writef32(ScoreBuffer, (SVIndex - 1) * 4, SmallestValue + Result)
				const RBOffset = buffer.readu32(OffsetBuffer, (SVIndex - 1) * 4) :: number -- Render buffer memory offset
				const RenderBuffer = BufferTable[SVIndex] :: buffer

				local RenderResult =
					BufferHelper.CreateRenderBuffer(RenderBuffer, RBOffset, V0, V1, V2, R, G, B) :: number

				buffer.writeu32(OffsetBuffer, (SVIndex - 1) * 4, RenderResult)
			end
		end

		table.clear(ScreenVertices)
	end

	-- Sends the information to all workers workers
	for i, TargetActor: Actor in ipairs(PlayerScripts:WaitForChild("WorkerFolder"):GetChildren()) do
		const RenderBuffer = BufferTable[i] :: buffer

		TargetActor:SendMessage(
			"Execute Rendering",
			RenderBuffer,
			buffer.readu32(OffsetBuffer, (i - 1) * 4),
			CurrentFrame
		)
	end

	for i = 1, ActorCount do
		buffer.writeu32(OffsetBuffer, (i - 1) * 4, 0)
	end
end)
