--!native
--!optimize 2

local SelfActor = script.Parent :: Actor

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

-- Caching --
local ClearTable = table.clear
local Floor = math.floor

local Max = math.max
local Min = math.min

-- Static References --
local Player = game:GetService("Players").LocalPlayer :: Player
local PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui
local StarterPlayerScripts = game.StarterPlayer:WaitForChild("StarterPlayerScripts") :: StarterPlayerScripts

local Camera = workspace.CurrentCamera :: Camera

local ImageLabel = PlayerGui:WaitForChild("ScreenGui"):WaitForChild("ImageLabel") :: ImageLabel

-- Services --
local AssetService = game:GetService("AssetService") :: AssetService
local RunService = game:GetService("RunService") :: RunService

local BufferHelper = require(ReplicatedStorage.Shared.Utilities.BufferHelper)
local MathModule = require(game.ReplicatedStorage.Shared.Utilities.Render.MathModule) :: ModuleScript
local RenderConfigs = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.RenderConfigs) :: ModuleScript
local PartStore = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.Stores.PartStores) :: ModuleScript

-- Configs
local WIDTH = 240 :: number
local HEIGHT = 120 :: number
local TOTAL_PIXELS = WIDTH * HEIGHT :: number
local BUFFER_SIZE = TOTAL_PIXELS * 4 :: number

local BufferOffsetTable = {} :: { number }
local BufferTable = {} :: { buffer }
local BfrScoreTable = {} :: { number }

local PART_TRIANGLES = RenderConfigs.GetPartTriangles() :: { { number } }

local WorldVertices = table.create(8)

-- CONNECTING IMAGE + EDITABLE IMAGE
local EditableImage = AssetService:CreateEditableImage({
	Size = Vector2.new(WIDTH, HEIGHT),
}) :: EditableImage
ImageLabel.ImageContent = Content.fromObject(EditableImage) :: Content

SelfActor:BindToMessage("Return Render Calculations", function(ReturnedBuffer: buffer)
	EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), ReturnedBuffer)
end)

-- ============================================================================
-- 1. RENDER LOOP
-- ============================================================================

RunService.RenderStepped:Connect(function()
	const Clock = os.clock() :: number

	local PartArray = PartStore.ReturnArray() :: { BasePart }

	const CamCFrame = Camera.CFrame :: CFrame
	const CamFOV = Camera.FieldOfView :: number

	local ScreenVertices = {} :: { Vector3 }

	for i = 1, 6 do
		BufferTable[i] = buffer.create(BUFFER_SIZE * 4) :: buffer
		BfrScoreTable[i] = 2
		BufferOffsetTable[i] = 0
	end

	for i = 1, #PartArray do
		const TargetPart = PartArray[i] :: BasePart

		if not TargetPart then
			continue
		end

		const PartColor = TargetPart.Color :: Color3
		const R = Floor(PartColor.R * 255) :: number
		const G = Floor(PartColor.G * 255) :: number
		const B = Floor(PartColor.B * 255) :: number

		MathModule.GetPartWorldVertices(TargetPart, WorldVertices)

		for i, WorldPos in ipairs(WorldVertices) do
			ScreenVertices[i] =
				MathModule.ProjectWorldPointToScreen(WorldPos, CamCFrame, CamFOV, WIDTH, HEIGHT) :: Vector3
		end

		for TriangleIndex = 1, #PART_TRIANGLES do
			const tri = PART_TRIANGLES[TriangleIndex] :: { number }
			const v0 = ScreenVertices[tri[1]] :: Vector3
			const v1 = ScreenVertices[tri[2]] :: Vector3
			const v2 = ScreenVertices[tri[3]] :: Vector3
			if v0 and v1 and v2 then
				const x0: number, y0: number = v0.X, v0.Y
				const x1: number, y1: number = v1.X, v1.Y
				const x2: number, y2: number = v2.X, v2.Y

				const minX = Max(0, Min(x0, x1, x2)) :: number
				const maxX = Min(WIDTH - 1, Max(x0, x1, x2)) :: number
				const minY = Max(0, Min(y0, y1, y2)) :: number
				const maxY = Min(HEIGHT - 1, Max(y0, y1, y2)) :: number

				local YResult = minY - maxY
				local XResult = minX - maxX

				local Result = YResult * XResult

				local SmallestValue = math.huge
				local SVIndex = 0

				for i = 1, 6 do
					local Score = BfrScoreTable[i] :: number

					if Score < SmallestValue then
						SmallestValue = Score
						SVIndex = i
					end
				end

				BfrScoreTable[SVIndex] = Result
				local RBOffset = BufferOffsetTable[SVIndex] :: number -- Render buffer memory offset
				local RenderBuffer = BufferTable[SVIndex] :: buffer

				BufferOffsetTable[SVIndex] =
					BufferHelper.CreateRenderBuffer(RenderBuffer, RBOffset, v0, v1, v2, R, G, B, WIDTH, HEIGHT)
			end
		end

		ClearTable(ScreenVertices)
	end

	for i, TargetActor: Actor in ipairs(StarterPlayerScripts:WaitForChild("RenderParralel")) do
		local RenderBuffer = BufferTable[i] :: buffer
		TargetActor:SendMessage("Execute Rendering", RenderBuffer)
	end

	BufferOffsetTable = {}

	print("Rendering took " .. (os.clock() - Clock) .. " seconds")
end)
