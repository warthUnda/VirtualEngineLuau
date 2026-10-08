--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const AssetService = game:GetService("AssetService") :: AssetService
const RunService = game:GetService("RunService") :: RunService

-- Caching --
const ClearTable = table.clear
const Floor = math.floor

const Max = math.max
const Min = math.min

-- Static References --
const Player = game:GetService("Players").LocalPlayer :: Player
const PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
const PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

const Camera = workspace.CurrentCamera :: Camera
const ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel

const SelfActor = script.Parent :: Actor

-- Modules --
const BufferHelper = require(ReplicatedStorage.Shared.Utilities.BufferHelper) :: ModuleScript
const MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.RenderMath) :: ModuleScript
const RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.RenderConfigs) :: ModuleScript
const PartStore = require(script.Parent.PartStores) :: ModuleScript

-- Configs --
const WIDTH: number, HEIGHT: number = RenderConfigs.ReturnDimensions2D()

const TOTAL_PIXELS = WIDTH * HEIGHT :: number

local Received = 0 :: number
local CurrentFrame = 0 :: number

-- Tables --
local BufferOffsetTable = {} :: { number }
local BufferTable = {} :: { buffer }
local BfrScoreTable = {} :: { number }

local PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: { { number } }
local WorldVertices = table.create(8) :: { Vector3 }

-- Buffers
const FinalPixel = buffer.create(TOTAL_PIXELS * 4) :: buffer
const FinalZ = buffer.create(TOTAL_PIXELS * 4) :: buffer

-- Connecting Editable image to ImageLabel --
const EditableImage = AssetService:CreateEditableImage({ Size = Vector2.new(WIDTH, HEIGHT) }) :: EditableImage
ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

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
	if Received == 6 then
		EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), FinalPixel)
		Received = 0
	end
end)

-- ============================================================================
-- 2. GATHER DATA - SEND DATA TO WORKERS
-- ============================================================================

RunService.RenderStepped:Connect(function()
	-- Tables
	const PartArray = PartStore.ReturnArray() :: { BasePart }
	const ScreenVertices = {} :: { Vector3 }

	-- Configs
	const CamCFrame = Camera.CFrame :: CFrame
	const CamFOV = Camera.FieldOfView :: number

	local SmallestValue = math.huge :: number
	local SVIndex = 0 :: number

	-- Pre loop Updates --
	BufferHelper.ClearBuffers(TOTAL_PIXELS, FinalPixel, FinalZ)

	CurrentFrame += 1
	Received = 0

	-- Create Information Data for workers
	for i = 1, 6 do
		BufferTable[i] = buffer.create(TOTAL_PIXELS * 8)
		BfrScoreTable[i] = 2
		BufferOffsetTable[i] = 0
	end

	-- Loop through all parts
	for i = 1, #PartArray do
		const TargetPart = PartArray[i] :: BasePart

		if not TargetPart then
			continue
		end

		-- Variables
		const PartColor = TargetPart.Color :: Color3
		const R = Floor(PartColor.R * 255) :: number
		const G = Floor(PartColor.G * 255) :: number
		const B = Floor(PartColor.B * 255) :: number

		-- Updates
		MathModule.GetPartWorldVertices(TargetPart, WorldVertices)

		-- Projects the vertices to screen
		for i, WorldPos: Vector3 in ipairs(WorldVertices) do
			ScreenVertices[i] =
				MathModule.ProjectWorldPointToScreen(WorldPos, CamCFrame, CamFOV, WIDTH, HEIGHT) :: Vector3
		end

		-- Loop through all triangles
		for TriangleIndex = 1, #PART_TRIANGLES do
			const Tri = PART_TRIANGLES[TriangleIndex] :: { number }
			const V0 = ScreenVertices[Tri[1]] :: Vector3
			const V1 = ScreenVertices[Tri[2]] :: Vector3
			const V2 = ScreenVertices[Tri[3]] :: Vector3

			if V0 and V1 and V2 then
				-- Variables
				const X0: number, Y0: number = V0.X, V0.Y
				const X1: number, Y1: number = V1.X, V1.Y
				const X2: number, Y2: number = V2.X, V2.Y

				const MinX = Max(0, Min(X0, X1, X2)) :: number
				const MaxX = Min(WIDTH - 1, Max(X0, X1, X2)) :: number
				const MinY = Max(0, Min(Y0, Y1, Y2)) :: number
				const MaxY = Min(HEIGHT - 1, Max(Y0, Y1, Y2)) :: number

				const YHeight = MaxY - MinY :: number
				const XWidth = MaxX - MinX :: number

				const Result = YHeight * XWidth :: number -- Calculate how many pixels the object covers
				math.abs(Result)

				SmallestValue = math.huge :: number
				SVIndex = 0 :: number

				-- Find the smallest value then increase it
				for i = 1, 6 do
					const Score = BfrScoreTable[i] :: number

					if Score <= SmallestValue then
						SmallestValue = Score
						SVIndex = i
					end
				end

				-- Apply changes and create a information buffer for workers
				BfrScoreTable[SVIndex] += Result
				const RBOffset = BufferOffsetTable[SVIndex] :: number -- Render buffer memory offset
				const RenderBuffer = BufferTable[SVIndex] :: buffer

				BufferOffsetTable[SVIndex] =
					BufferHelper.CreateRenderBuffer(RenderBuffer, RBOffset, V0, V1, V2, R, G, B)
			end
		end

		ClearTable(ScreenVertices)
	end

	-- Sends the information to all workers workers
	for i, TargetActor: Actor in ipairs(PlayerScripts:WaitForChild("WorkerFolder"):GetChildren()) do
		const RenderBuffer = BufferTable[i] :: buffer
		TargetActor:SendMessage("Execute Rendering", RenderBuffer, BufferOffsetTable[i], CurrentFrame)
	end

	BufferOffsetTable = {}
end)
