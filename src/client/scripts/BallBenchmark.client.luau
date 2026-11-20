--!strict
--!native
--!optimize 2

--[=[
	@class BallBenchmark.client
	Creates a ScreenGui overlay above the software renderer with 4 benchmark presets
	(150, 300, 500, and 1000 balls), dispatching spawn requests to the temporary
	server RemoteEvent and measuring live ReplicateEvent network payload throughput.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const BenchmarkRemote = ReplicatedStorage:WaitForChild("BallBenchmarkEvent") :: RemoteEvent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const PAYLOAD_WINDOW_SECONDS = 0.5 :: number

type BenchmarkOption = {
	Count: number,
	Label: string,
	AccentColor: Color3,
}

const BENCHMARK_OPTIONS: { BenchmarkOption } = {
	{ Count = 150, Label = "150 Balls", AccentColor = Color3.fromRGB(62, 168, 110) },
	{ Count = 300, Label = "300 Balls", AccentColor = Color3.fromRGB(66, 138, 214) },
	{ Count = 500, Label = "500 Balls", AccentColor = Color3.fromRGB(224, 146, 54) },
	{ Count = 1000, Label = "1000 Balls", AccentColor = Color3.fromRGB(214, 72, 72) },
}

-- Variables --
local ActiveOptionCount = 0 :: number
local SpawnedBallCount = 0 :: number
local LastServerBuildMs = 0 :: number
local LastPacketBytes = 0 :: number
local LastPacketEntities = 0 :: number
local WindowBytes = 0 :: number
local WindowStartClock = os.clock() :: number
local MeasuredKbps = 0 :: number

-- Tables --
local OptionButtons = {} :: { [number]: TextButton }

-- Local Functions --

local function BuildBenchmarkGui(): TextLabel
	const ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "BallBenchmarkGui"
	ScreenGui.DisplayOrder = 100
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.ResetOnSpawn = false
	ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ScreenGui.Enabled = true
	ScreenGui.Parent = PlayerGui

	const Container = Instance.new("Frame")
	Container.Name = "Panel"
	Container.AnchorPoint = Vector2.new(1, 0)
	Container.Position = UDim2.new(1, -16, 0, 16)
	Container.Size = UDim2.fromOffset(250, 255)
	Container.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	Container.BackgroundTransparency = 0.08
	Container.BorderSizePixel = 0
	Container.Parent = ScreenGui

	const Corner = Instance.new("UICorner")
	Corner.CornerRadius = UDim.new(0, 10)
	Corner.Parent = Container

	const Stroke = Instance.new("UIStroke")
	Stroke.Color = Color3.fromRGB(85, 95, 120)
	Stroke.Thickness = 1.5
	Stroke.Parent = Container

	const Padding = Instance.new("UIPadding")
	Padding.PaddingTop = UDim.new(0, 10)
	Padding.PaddingBottom = UDim.new(0, 10)
	Padding.PaddingLeft = UDim.new(0, 10)
	Padding.PaddingRight = UDim.new(0, 10)
	Padding.Parent = Container

	const Layout = Instance.new("UIListLayout")
	Layout.FillDirection = Enum.FillDirection.Vertical
	Layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	Layout.SortOrder = Enum.SortOrder.LayoutOrder
	Layout.Padding = UDim.new(0, 6)
	Layout.Parent = Container

	const Title = Instance.new("TextLabel")
	Title.Name = "Title"
	Title.LayoutOrder = 1
	Title.Size = UDim2.new(1, 0, 0, 24)
	Title.BackgroundTransparency = 1
	Title.Font = Enum.Font.GothamBold
	Title.Text = "Ball Benchmark (50 Studs)"
	Title.TextColor3 = Color3.fromRGB(240, 244, 255)
	Title.TextSize = 15
	Title.Parent = Container

	for Index, Option: BenchmarkOption in ipairs(BENCHMARK_OPTIONS) do
		const Button = Instance.new("TextButton")
		Button.Name = "Spawn" .. tostring(Option.Count)
		Button.LayoutOrder = Index + 1
		Button.Size = UDim2.new(1, 0, 0, 34)
		Button.BackgroundColor3 = Option.AccentColor
		Button.AutoButtonColor = true
		Button.Font = Enum.Font.GothamSemibold
		Button.Text = Option.Label
		Button.TextColor3 = Color3.fromRGB(255, 255, 255)
		Button.TextSize = 15
		Button.Parent = Container

		const BtnCorner = Instance.new("UICorner")
		BtnCorner.CornerRadius = UDim.new(0, 6)
		BtnCorner.Parent = Button

		const BtnStroke = Instance.new("UIStroke")
		BtnStroke.Name = "SelectionStroke"
		BtnStroke.Color = Color3.fromRGB(255, 255, 255)
		BtnStroke.Thickness = 2
		BtnStroke.Enabled = false
		BtnStroke.Parent = Button

		OptionButtons[Option.Count] = Button
		Button.MouseButton1Click:Connect(function()
			ActiveOptionCount = Option.Count
			for CountKey: number, TargetBtn: TextButton in pairs(OptionButtons) do
				const Selection = TargetBtn:FindFirstChild("SelectionStroke")
				if Selection and Selection:IsA("UIStroke") then
					Selection.Enabled = (CountKey == ActiveOptionCount)
				end
			end
			BenchmarkRemote:FireServer(Option.Count)
		end)
	end

	const StatsLabel = Instance.new("TextLabel")
	StatsLabel.Name = "Stats"
	StatsLabel.LayoutOrder = 10
	StatsLabel.Size = UDim2.new(1, 0, 0, 34)
	StatsLabel.BackgroundTransparency = 1
	StatsLabel.Font = Enum.Font.Code
	StatsLabel.Text = "Balls: 0 | Net: 0.0 KB/s\nPkt: 0 B (0 ents)"
	StatsLabel.TextColor3 = Color3.fromRGB(165, 225, 255)
	StatsLabel.TextSize = 11
	StatsLabel.Parent = Container

	const HintLabel = Instance.new("TextLabel")
	HintLabel.Name = "Hint"
	HintLabel.LayoutOrder = 11
	HintLabel.Size = UDim2.new(1, 0, 0, 16)
	HintLabel.BackgroundTransparency = 1
	HintLabel.Font = Enum.Font.Gotham
	HintLabel.Text = "[LeftAlt] Unlock cursor to click"
	HintLabel.TextColor3 = Color3.fromRGB(160, 168, 188)
	HintLabel.TextSize = 11
	HintLabel.Parent = Container

	return StatsLabel
end

-- Functions --
-- ============================================================================
-- 1. BENCHMARK GUI & NETWORK PAYLOAD MONITOR
-- ============================================================================

const StatsLabel = BuildBenchmarkGui()

const RefreshStatsText = function()
	StatsLabel.Text = string.format(
		"Balls: %d (%.1f ms) | Net: %.1f KB/s\nPkt: %.2f KB (%d ents)",
		SpawnedBallCount,
		LastServerBuildMs,
		MeasuredKbps,
		LastPacketBytes / 1024,
		LastPacketEntities
	)
end

BenchmarkRemote.OnClientEvent:Connect(function(ServerBallCount: number, BuildMs: number)
	SpawnedBallCount = ServerBallCount
	LastServerBuildMs = BuildMs
	RefreshStatsText()
end)

task.spawn(function()
	const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
	const ReplicateEvent = CoreEvents:WaitForChild(REPLICATE_REMOTE_NAME) :: RemoteEvent
	ReplicateEvent.OnClientEvent:Connect(function(Payload: buffer)
		if typeof(Payload) ~= "buffer" or buffer.len(Payload) < 8 then
			return
		end

		const PacketBytes = buffer.len(Payload) :: number
		LastPacketBytes = PacketBytes
		LastPacketEntities = buffer.readu16(Payload, 0)
		WindowBytes += PacketBytes

		const Now = os.clock() :: number
		const Elapsed = Now - WindowStartClock :: number
		if Elapsed >= PAYLOAD_WINDOW_SECONDS then
			MeasuredKbps = (WindowBytes / 1024) / Elapsed
			WindowBytes = 0
			WindowStartClock = Now
		end

		RefreshStatsText()
	end)
end)
