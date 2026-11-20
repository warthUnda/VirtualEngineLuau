--!strict
--!native
--!optimize 2

--[=[
	@class BallBenchmark.server
	Creates a temporary RemoteEvent in ReplicatedStorage and spawns 150, 300, 500, or 1000
	non-colliding Sphere ECS entities across a 50-stud radius around SpawnLocation, driving
	fast, violent kinematic up-and-down bouncing with zero physics simulation or collisions.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
const SpawnInstance = workspace:FindFirstChild("SpawnLocation", true)

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const VerticeFile = require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Core"):WaitForChild("VerticeFile"))

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData
const PositionData = Storage.PositionData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const VisualData = Storage.VisualData
const PropertiesData = Storage.PropertiesData

-- Configs --
const REMOTE_NAME = "BallBenchmarkEvent" :: string
const MAX_BENCHMARK_BALLS = 1000 :: number
const BENCHMARK_RADIUS = 50 :: number
const BENCHMARK_RADIUS_SQ = BENCHMARK_RADIUS * BENCHMARK_RADIUS :: number
const BALL_DIAMETER = 2.2 :: number
const MIN_SPAWN_HEIGHT = 4.0 :: number
const MAX_SPAWN_HEIGHT = 42.0 :: number
const FLOOR_Y_OFFSET = 2.0 :: number
const CEILING_Y_OFFSET = 46.0 :: number
const KINEMATIC_GRAVITY = 240.0 :: number
const MIN_UP_SPEED = 110.0 :: number
const MAX_UP_SPEED = 185.0 :: number
const MIN_RADIAL_SPEED = 35.0 :: number
const MAX_RADIAL_SPEED = 85.0 :: number
const MAX_STEP_DT = 0.05 :: number
const REQUEST_COOLDOWN = 0.25 :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const SPHERE_SHAPE_ID = VerticeFile.ShapeToId.Sphere :: number
const SPAWN_POSITION = (
	if SpawnInstance and SpawnInstance:IsA("BasePart")
		then SpawnInstance.Position
		else Vector3.new(0, 4.1, 0)
) :: Vector3

const ALLOWED_COUNTS = {
	[150] = true,
	[300] = true,
	[500] = true,
	[1000] = true,
} :: { [number]: boolean }

-- Remote Events --
const ExistingRemote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
const BenchmarkRemote = (
	if ExistingRemote and ExistingRemote:IsA("RemoteEvent")
		then ExistingRemote
		else Instance.new("RemoteEvent")
) :: RemoteEvent
BenchmarkRemote.Name = REMOTE_NAME
BenchmarkRemote:SetAttribute("SpawnPosition", SPAWN_POSITION)
BenchmarkRemote.Parent = ReplicatedStorage

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const BallVelocityBuffer = buffer.create(MAX_BENCHMARK_BALLS * COMPONENT_STRIDE) :: buffer

-- Variables --
const BenchmarkRng = Random.new()

-- Tables --
local BenchmarkBallIds = {} :: { number }
local LastRequestTimeByPlayer = {} :: { [Player]: number }

-- Local Functions --

local function ClearBenchmarkBalls()
	for _, EntityId: number in ipairs(BenchmarkBallIds) do
		ECSData.DeleteEntity(EntityId)
	end
	table.clear(BenchmarkBallIds)
	buffer.fill(BallVelocityBuffer, 0, 0, MAX_BENCHMARK_BALLS * COMPONENT_STRIDE)
end

local function SpawnBallGroup(RequestedCount: number)
	const BuildStart = os.clock() :: number
	ClearBenchmarkBalls()

	const SpawnCap = math.min(RequestedCount, MAX_BENCHMARK_BALLS) :: number
	for Index = 1, SpawnCap do
		const EntityId = ECSData.RegisterEntity(false) :: number
		if EntityId <= 0 then
			break
		end

		const Theta = BenchmarkRng:NextNumber(0, math.pi * 2) :: number
		const RadialDist = BENCHMARK_RADIUS * math.sqrt(BenchmarkRng:NextNumber(0.03, 1.0)) :: number
		const DirX = math.cos(Theta) :: number
		const DirZ = math.sin(Theta) :: number
		const PosX = SPAWN_POSITION.X + DirX * RadialDist :: number
		const PosY = SPAWN_POSITION.Y + BenchmarkRng:NextNumber(MIN_SPAWN_HEIGHT, MAX_SPAWN_HEIGHT) :: number
		const PosZ = SPAWN_POSITION.Z + DirZ * RadialDist :: number

		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const VisOffset = (EntityId - 1) * VISUAL_STRIDE :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number

		PositionData.CreateLayout(CompOffset, PosX, PosY, PosZ)
		SizeData.CreateLayout(CompOffset, BALL_DIAMETER, BALL_DIAMETER, BALL_DIAMETER)
		DirectionsData.CreateLayout(DirOffset, 0, 0, -1, 0, 1, 0, 1, 0, 0)

		const Tint = Color3.fromHSV(((Index - 1) % 24) / 24, 0.9, 1)
		VisualData.CreateLayout(
			VisOffset,
			math.floor(Tint.R * 255),
			math.floor(Tint.G * 255),
			math.floor(Tint.B * 255),
			255
		)
		-- CanCollide=false, IsVisible=true, Anchored=true to bypass physics collisions and simulation
		PropertiesData.CreateLayout(PropOffset, false, true, true, 0, 0, SPHERE_SHAPE_ID)
		ECSData.MarkDirty(EntityId)

		const BallSlot = #BenchmarkBallIds :: number
		const VelOffset = BallSlot * COMPONENT_STRIDE :: number
		const HorizSpeed = BenchmarkRng:NextNumber(MIN_RADIAL_SPEED, MAX_RADIAL_SPEED) :: number
		const VerticalSign = if BenchmarkRng:NextNumber() < 0.5 then -1 else 1 :: number
		buffer.writef32(BallVelocityBuffer, VelOffset, DirX * HorizSpeed)
		buffer.writef32(
			BallVelocityBuffer,
			VelOffset + 4,
			VerticalSign * BenchmarkRng:NextNumber(MIN_UP_SPEED * 0.6, MAX_UP_SPEED)
		)
		buffer.writef32(BallVelocityBuffer, VelOffset + 8, DirZ * HorizSpeed)

		table.insert(BenchmarkBallIds, EntityId)
	end

	const ElapsedMs = (os.clock() - BuildStart) * 1000 :: number
	BenchmarkRemote:FireAllClients(#BenchmarkBallIds, ElapsedMs)
end

local function StepBenchmarkBouncing(DeltaTime: number)
	const BallCount = #BenchmarkBallIds :: number
	if BallCount == 0 then
		return
	end

	const Dt = math.min(DeltaTime, MAX_STEP_DT) :: number
	const FloorY = SPAWN_POSITION.Y + FLOOR_Y_OFFSET :: number
	const CeilingY = SPAWN_POSITION.Y + CEILING_Y_OFFSET :: number

	for Index = 1, BallCount do
		const EntityId = BenchmarkBallIds[Index] :: number
		if not ECSData.IsEntityActive(EntityId) then
			continue
		end

		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const VelOffset = (Index - 1) * COMPONENT_STRIDE :: number

		local PosX = buffer.readf32(PositionBuffer, CompOffset) :: number
		local PosY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		local PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

		local VelX = buffer.readf32(BallVelocityBuffer, VelOffset) :: number
		local VelY = buffer.readf32(BallVelocityBuffer, VelOffset + 4) - KINEMATIC_GRAVITY * Dt :: number
		local VelZ = buffer.readf32(BallVelocityBuffer, VelOffset + 8) :: number

		PosX += VelX * Dt
		PosY += VelY * Dt
		PosZ += VelZ * Dt

		if PosY <= FloorY then
			PosY = FloorY
			const ScatterAngle = BenchmarkRng:NextNumber(0, math.pi * 2) :: number
			const HorizSpeed = BenchmarkRng:NextNumber(MIN_RADIAL_SPEED, MAX_RADIAL_SPEED) :: number
			VelX = math.cos(ScatterAngle) * HorizSpeed
			VelZ = math.sin(ScatterAngle) * HorizSpeed
			VelY = BenchmarkRng:NextNumber(MIN_UP_SPEED, MAX_UP_SPEED)
		elseif PosY >= CeilingY then
			PosY = CeilingY
			VelY = -math.max(95, math.abs(VelY) * 1.05)
		end

		const Dx = PosX - SPAWN_POSITION.X :: number
		const Dz = PosZ - SPAWN_POSITION.Z :: number
		const DistSq = Dx * Dx + Dz * Dz :: number
		if DistSq > BENCHMARK_RADIUS_SQ then
			const InvDist = 1 / math.sqrt(DistSq) :: number
			const NormX = Dx * InvDist :: number
			const NormZ = Dz * InvDist :: number
			PosX = SPAWN_POSITION.X + NormX * BENCHMARK_RADIUS
			PosZ = SPAWN_POSITION.Z + NormZ * BENCHMARK_RADIUS

			const RadialDot = VelX * NormX + VelZ * NormZ :: number
			if RadialDot > 0 then
				VelX -= 2 * RadialDot * NormX
				VelZ -= 2 * RadialDot * NormZ
			end
		end

		buffer.writef32(PositionBuffer, CompOffset, PosX)
		buffer.writef32(PositionBuffer, CompOffset + 4, PosY)
		buffer.writef32(PositionBuffer, CompOffset + 8, PosZ)

		buffer.writef32(BallVelocityBuffer, VelOffset, VelX)
		buffer.writef32(BallVelocityBuffer, VelOffset + 4, VelY)
		buffer.writef32(BallVelocityBuffer, VelOffset + 8, VelZ)

		ECSData.MarkDirty(EntityId)
	end
end

-- Functions --
-- ============================================================================
-- 1. TEMPORARY REMOTE EVENT HANDLER & VIOLENT KINEMATIC BOUNCE LOOP
-- ============================================================================

BenchmarkRemote.OnServerEvent:Connect(function(PlayerObject: Player, RequestedCount: any)
	if type(RequestedCount) ~= "number" or not ALLOWED_COUNTS[RequestedCount] then
		return
	end

	const Now = os.clock() :: number
	const LastRequest = LastRequestTimeByPlayer[PlayerObject] or 0 :: number
	if Now - LastRequest < REQUEST_COOLDOWN then
		return
	end
	LastRequestTimeByPlayer[PlayerObject] = Now

	SpawnBallGroup(RequestedCount)
end)

Players.PlayerRemoving:Connect(function(LeavingPlayer: Player)
	LastRequestTimeByPlayer[LeavingPlayer] = nil
end)

RunService.Heartbeat:Connect(StepBenchmarkBouncing)
