--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities") :: Folder
const PhysicsFolder = UtilitiesFolder:WaitForChild("Physics") :: Folder

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs")) :: ModuleScript
const PhysicsMovementQueue = require(PhysicsFolder:WaitForChild("PhysicsMovementQueue")) :: ModuleScript
const PhysicsLibrary = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsLIbrary")) :: ModuleScript

const CameraStore = if IS_CLIENT
	then require(
		UtilitiesFolder:WaitForChild("Render")
			:WaitForChild("Camera")
			:WaitForChild("CameraStore")
	) :: ModuleScript
	else nil

-- Configs --
const MAX_DELTA_TIME = SystemsConfigs.PhysicsMaxDeltaTime :: number
const SUBSTEPS = math.max(1, SystemsConfigs.PhysicsSubsteps) :: number

const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3
const VOID_RESET_Y = SystemsConfigs.PlayerVoidResetY :: number
const PLAYER_MASS = SystemsConfigs.PlayerMass :: number
const PLAYER_INV_MASS = 1 / PLAYER_MASS :: number

const PLAYER_HALF_EXTENTS = SystemsConfigs.PlayerHalfExtents :: Vector3
const PLAYER_HX = PLAYER_HALF_EXTENTS.X :: number
const PLAYER_HY = PLAYER_HALF_EXTENTS.Y :: number
const PLAYER_HZ = PLAYER_HALF_EXTENTS.Z :: number

const OBJECT_DEFAULT_DENSITY = SystemsConfigs.ObjectDefaultDensity :: number
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number
const SLEEP_SPEED_THRESHOLD = SystemsConfigs.ObjectSleepSpeedThreshold :: number
const SLEEP_SPEED_SQ = SLEEP_SPEED_THRESHOLD * SLEEP_SPEED_THRESHOLD :: number

const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const PLAYER_CMD_STRIDE = PhysicsMovementQueue.PlayerCommandStride :: number
const OBJECT_CMD_STRIDE = PhysicsMovementQueue.ObjectCommandStride :: number

-- Tables --
local Initialized = false :: boolean
local ActiveForceCount = 0 :: number

local SpawnPosX = DEFAULT_SPAWN.X :: number
local SpawnPosY = DEFAULT_SPAWN.Y :: number
local SpawnPosZ = DEFAULT_SPAWN.Z :: number

local PlayerPosX = DEFAULT_SPAWN.X :: number
local PlayerPosY = DEFAULT_SPAWN.Y :: number
local PlayerPosZ = DEFAULT_SPAWN.Z :: number

local PlayerVelX = 0 :: number
local PlayerVelY = 0 :: number
local PlayerVelZ = 0 :: number
local PlayerGrounded = false :: boolean

local HostRootPart: BasePart? = nil
local ECSDataModule: any = nil

-- Buffers
local ECSPositionBuffer: buffer? = nil
local ECSSizeBuffer: buffer? = nil
local ECSDirectionsBuffer: buffer? = nil

const DynamicFlags = buffer.create(MAX_ENTITIES) :: buffer -- 0 = static, 1 = awake dynamic, 2 = sleeping dynamic
const ObjectGroundedFlags = buffer.create(MAX_ENTITIES) :: buffer
const ObjectVelocityBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectForceBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectInvMassBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const ActiveForceSlots = buffer.create(MAX_ENTITIES * 4) :: buffer

local PhysicsController = {}

-- ============================================================================
-- 1. INTERNAL HELPERS - STORAGE BINDING, INPUT & QUEUE CONSUMPTION
-- ============================================================================

local function ResolveObjectStorage(): Folder?
	if not IS_CLIENT then
		return nil
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer then
		return nil
	end

	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
	const ControllerActor = PlayerScripts:FindFirstChild("Controller") :: Actor?
	if ControllerActor then
		const ActorStorage = ControllerActor:FindFirstChild("ObjectStorage") :: Folder?
		if ActorStorage then
			return ActorStorage
		end
	end

	return PlayerScripts:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage") :: Folder
end

local function ConfigureCharacterInstance(Character: Model)
	const Humanoid = Character:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
	if Humanoid then
		Humanoid.PlatformStand = true
	end

	for _, Descendant: Instance in ipairs(Character:GetDescendants()) do
		if Descendant:IsA("BasePart") then
			Descendant.CanCollide = false
		end
	end

	const RootPart = (Character:FindFirstChild("HumanoidRootPart") or Character:WaitForChild("HumanoidRootPart", 5)) :: BasePart?
	if not RootPart then
		return
	end

	RootPart.Anchored = true
	RootPart.CanCollide = false
	HostRootPart = RootPart

	const StartPos = RootPart.Position :: Vector3
	SpawnPosX, SpawnPosY, SpawnPosZ = StartPos.X, StartPos.Y + 0.5, StartPos.Z
	PlayerPosX, PlayerPosY, PlayerPosZ = SpawnPosX, SpawnPosY, SpawnPosZ
	PlayerVelX, PlayerVelY, PlayerVelZ = 0, 0, 0
end

local function SampleKeyboardInput()
	if not IS_CLIENT or not CameraStore then
		return
	end

	if UserInputService:GetFocusedTextBox() ~= nil then
		return
	end

	const CamLook = CameraStore.GetCameraLook() :: Vector3
	const CamRight = CameraStore.GetCameraRight() :: Vector3

	local ForwardX: number, ForwardZ: number = CamLook.X, CamLook.Z
	const ForwardLen = math.sqrt(ForwardX * ForwardX + ForwardZ * ForwardZ) :: number
	if ForwardLen > 1e-5 then
		ForwardX /= ForwardLen
		ForwardZ /= ForwardLen
	end

	local RightX: number, RightZ: number = CamRight.X, CamRight.Z
	const RightLen = math.sqrt(RightX * RightX + RightZ * RightZ) :: number
	if RightLen > 1e-5 then
		RightX /= RightLen
		RightZ /= RightLen
	end

	local MoveX = 0 :: number
	local MoveZ = 0 :: number

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		MoveX += ForwardX
		MoveZ += ForwardZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		MoveX -= ForwardX
		MoveZ -= ForwardZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		MoveX += RightX
		MoveZ += RightZ
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		MoveX -= RightX
		MoveZ -= RightZ
	end

	const MoveLen = math.sqrt(MoveX * MoveX + MoveZ * MoveZ) :: number
	if MoveLen > 1e-5 then
		MoveX /= MoveLen
		MoveZ /= MoveLen
	end

	const JumpPressed = UserInputService:IsKeyDown(Enum.KeyCode.Space) :: boolean
	if MoveLen > 1e-5 or JumpPressed then
		PhysicsMovementQueue.AddMovement(MoveX, 0, MoveZ, 1.0, JumpPressed, false)
	end
end

local function EnsureDynamicEntityMass(EntityId: number, SizeBuffer: buffer, CustomMass: number?): number
	const MassOffset = (EntityId - 1) * 4 :: number
	const ExistingInvMass = buffer.readf32(ObjectInvMassBuffer, MassOffset) :: number
	if ExistingInvMass > 0 and CustomMass == nil then
		return ExistingInvMass
	end

	local ResolvedMass = CustomMass :: number?
	if not ResolvedMass or ResolvedMass <= 0 then
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const Sx = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset)) :: number
		const Sy = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 4)) :: number
		const Sz = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 8)) :: number
		ResolvedMass = Sx * Sy * Sz * OBJECT_DEFAULT_DENSITY
	end

	const InvMass = 1 / (ResolvedMass :: number) :: number
	buffer.writef32(ObjectInvMassBuffer, MassOffset, InvMass)
	return InvMass
end

local function ConsumePlayerQueue(): (number, number, number, boolean)
	local WishX = 0 :: number
	local WishZ = 0 :: number
	local MaxScale = 0 :: number
	local JumpRequested = false :: boolean

	const PlayerBuffer = PhysicsMovementQueue.PlayerBuffer :: buffer
	const CmdCount = PhysicsMovementQueue.GetPlayerCommandCount() :: number

	for i = 1, CmdCount do
		const Offset = (i - 1) * PLAYER_CMD_STRIDE :: number
		const DirX = buffer.readf32(PlayerBuffer, Offset) :: number
		const DirY = buffer.readf32(PlayerBuffer, Offset + 4) :: number
		const DirZ = buffer.readf32(PlayerBuffer, Offset + 8) :: number
		const Scale = buffer.readf32(PlayerBuffer, Offset + 12) :: number
		const Flags = buffer.readu8(PlayerBuffer, Offset + 16) :: number

		if bit32.band(Flags, 1) ~= 0 then
			JumpRequested = true
		end

		if bit32.band(Flags, 2) ~= 0 then
			PlayerVelX += DirX * Scale * PLAYER_INV_MASS
			PlayerVelY += DirY * Scale * PLAYER_INV_MASS
			PlayerVelZ += DirZ * Scale * PLAYER_INV_MASS
			continue
		end

		WishX += DirX * Scale
		WishZ += DirZ * Scale
		MaxScale = math.max(MaxScale, math.abs(Scale))
	end

	for _, Entry in ipairs(PhysicsMovementQueue.PlayerQueue) do
		const Scale = Entry.Scale or 1.0 :: number
		if Entry.Jump then
			JumpRequested = true
		end

		if Entry.IsImpulse then
			PlayerVelX += Entry.DirX * Scale * PLAYER_INV_MASS
			PlayerVelY += Entry.DirY * Scale * PLAYER_INV_MASS
			PlayerVelZ += Entry.DirZ * Scale * PLAYER_INV_MASS
			continue
		end

		WishX += Entry.DirX * Scale
		WishZ += Entry.DirZ * Scale
		MaxScale = math.max(MaxScale, math.abs(Scale))
	end

	const WishLen = math.sqrt(WishX * WishX + WishZ * WishZ) :: number
	if WishLen <= 1e-5 then
		return 0, 0, 0, JumpRequested
	end

	return WishX / WishLen, WishZ / WishLen, math.min(MaxScale, 2.5), JumpRequested
end

local function ConsumeObjectQueue(EntityCount: number, SizeBuffer: buffer)
	const ObjectQueueBuffer = PhysicsMovementQueue.ObjectQueue :: buffer
	const CmdCount = PhysicsMovementQueue.GetObjectCommandCount() :: number

	for i = 1, CmdCount do
		const Offset = (i - 1) * OBJECT_CMD_STRIDE :: number
		const EntityId = buffer.readu32(ObjectQueueBuffer, Offset) :: number
		if EntityId < 1 or EntityId > EntityCount then
			continue
		end

		const DirX = buffer.readf32(ObjectQueueBuffer, Offset + 4) :: number
		const DirY = buffer.readf32(ObjectQueueBuffer, Offset + 8) :: number
		const DirZ = buffer.readf32(ObjectQueueBuffer, Offset + 12) :: number
		const Magnitude = buffer.readf32(ObjectQueueBuffer, Offset + 16) :: number
		const IsImpulse = (buffer.readu8(ObjectQueueBuffer, Offset + 20) == 1) :: boolean

		const InvMass = EnsureDynamicEntityMass(EntityId, SizeBuffer, nil) :: number
		const FlagIndex = EntityId - 1 :: number
		const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

		buffer.writeu8(DynamicFlags, FlagIndex, 1)

		if IsImpulse then
			const DeltaV = Magnitude * InvMass :: number
			buffer.writef32(ObjectVelocityBuffer, CompOffset, buffer.readf32(ObjectVelocityBuffer, CompOffset) + DirX * DeltaV)
			buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, buffer.readf32(ObjectVelocityBuffer, CompOffset + 4) + DirY * DeltaV)
			buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, buffer.readf32(ObjectVelocityBuffer, CompOffset + 8) + DirZ * DeltaV)
			continue
		end

		const PrevFx = buffer.readf32(ObjectForceBuffer, CompOffset) :: number
		const PrevFy = buffer.readf32(ObjectForceBuffer, CompOffset + 4) :: number
		const PrevFz = buffer.readf32(ObjectForceBuffer, CompOffset + 8) :: number

		if PrevFx == 0 and PrevFy == 0 and PrevFz == 0 and ActiveForceCount < MAX_ENTITIES then
			buffer.writeu32(ActiveForceSlots, ActiveForceCount * 4, CompOffset)
			ActiveForceCount += 1
		end

		buffer.writef32(ObjectForceBuffer, CompOffset, PrevFx + DirX * Magnitude)
		buffer.writef32(ObjectForceBuffer, CompOffset + 4, PrevFy + DirY * Magnitude)
		buffer.writef32(ObjectForceBuffer, CompOffset + 8, PrevFz + DirZ * Magnitude)
	end
end

local function StepSingleDynamicObject(
	EntityId: number,
	EntityCount: number,
	StepDt: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer
)
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	const InvMass = buffer.readf32(ObjectInvMassBuffer, FlagIndex * 4) :: number
	if InvMass <= 0 then
		buffer.writeu8(DynamicFlags, FlagIndex, 0)
		return
	end

	const WasGrounded = (buffer.readu8(ObjectGroundedFlags, FlagIndex) == 1) :: boolean
	const Fx = buffer.readf32(ObjectForceBuffer, CompOffset) :: number
	const Fy = buffer.readf32(ObjectForceBuffer, CompOffset + 4) :: number
	const Fz = buffer.readf32(ObjectForceBuffer, CompOffset + 8) :: number

	local Vx: number, Vy: number, Vz: number = PhysicsLibrary.StepObjectVelocity(
		buffer.readf32(ObjectVelocityBuffer, CompOffset),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 4),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 8),
		Fx,
		Fy,
		Fz,
		InvMass,
		WasGrounded,
		StepDt
	)

	local PosX = buffer.readf32(PositionBuffer, CompOffset) + Vx * StepDt :: number
	local PosY = buffer.readf32(PositionBuffer, CompOffset + 4) + Vy * StepDt :: number
	local PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) + Vz * StepDt :: number

	const Hx = buffer.readf32(SizeBuffer, CompOffset) * 0.5 :: number
	const Hy = buffer.readf32(SizeBuffer, CompOffset + 4) * 0.5 :: number
	const Hz = buffer.readf32(SizeBuffer, CompOffset + 8) * 0.5 :: number

	local Grounded: boolean
	PosX, PosY, PosZ, Vx, Vy, Vz, Grounded = PhysicsLibrary.ResolveBodyWorldCollisions(
		PosX,
		PosY,
		PosZ,
		Hx,
		Hy,
		Hz,
		Vx,
		Vy,
		Vz,
		InvMass,
		OBJECT_RESTITUTION,
		EntityId,
		EntityCount,
		PositionBuffer,
		SizeBuffer,
		DirectionsBuffer,
		DynamicFlags,
		ObjectVelocityBuffer,
		ObjectInvMassBuffer
	)

	buffer.writef32(PositionBuffer, CompOffset, PosX)
	buffer.writef32(PositionBuffer, CompOffset + 4, PosY)
	buffer.writef32(PositionBuffer, CompOffset + 8, PosZ)
	buffer.writeu8(ObjectGroundedFlags, FlagIndex, if Grounded then 1 else 0)

	const SpeedSq = Vx * Vx + Vy * Vy + Vz * Vz :: number
	const HasAppliedForce = (Fx ~= 0 or Fy ~= 0 or Fz ~= 0) :: boolean
	if Grounded and not HasAppliedForce and SpeedSq < SLEEP_SPEED_SQ then
		buffer.writef32(ObjectVelocityBuffer, CompOffset, 0)
		buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, 0)
		buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, 0)
		buffer.writeu8(DynamicFlags, FlagIndex, 2)
		return
	end

	buffer.writef32(ObjectVelocityBuffer, CompOffset, Vx)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, Vy)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, Vz)
end

local function ClearAccumulatedForces()
	for i = 0, ActiveForceCount - 1 do
		const CompOffset = buffer.readu32(ActiveForceSlots, i * 4) :: number
		buffer.writef32(ObjectForceBuffer, CompOffset, 0)
		buffer.writef32(ObjectForceBuffer, CompOffset + 4, 0)
		buffer.writef32(ObjectForceBuffer, CompOffset + 8, 0)
	end
	ActiveForceCount = 0
end

-- ============================================================================
-- 2. PUBLIC CONTROLLER API - INITIALIZATION & FRAME SIMULATION
-- ============================================================================

function PhysicsController.InitializePhysics()
	if Initialized then
		return
	end

	const ObjectStorage = ResolveObjectStorage()
	if ObjectStorage then
		const PositionData = require(ObjectStorage:WaitForChild("PositionData")) :: ModuleScript
		const SizeData = require(ObjectStorage:WaitForChild("SizeData")) :: ModuleScript
		const DirectionsData = require(ObjectStorage:WaitForChild("DirectionsData")) :: ModuleScript

		ECSDataModule = require(ObjectStorage:WaitForChild("ECSData"))
		ECSPositionBuffer = PositionData.GetData()
		ECSSizeBuffer = SizeData.GetData()
		ECSDirectionsBuffer = DirectionsData.GetData()
	end

	Initialized = true

	if not IS_CLIENT then
		return
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer then
		return
	end

	if LocalPlayer.Character then
		task.spawn(ConfigureCharacterInstance, LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(ConfigureCharacterInstance)
end

function PhysicsController.SimulatePhysicsFrame(DeltaTime: number?)
	if not Initialized then
		PhysicsController.InitializePhysics()
	end

	const PositionBuffer = ECSPositionBuffer
	const SizeBuffer = ECSSizeBuffer
	const DirectionsBuffer = ECSDirectionsBuffer
	if not PositionBuffer or not SizeBuffer or not DirectionsBuffer or not ECSDataModule then
		PhysicsMovementQueue.Clear()
		return
	end

	const EntityCount = math.min(ECSDataModule.GetCounts().EntityECSCount :: number, MAX_ENTITIES) :: number
	if EntityCount <= 0 then
		PhysicsMovementQueue.Clear()
		return
	end

	SampleKeyboardInput()
	const WishX: number, WishZ: number, WishScale: number, JumpRequested: boolean = ConsumePlayerQueue()
	ConsumeObjectQueue(EntityCount, SizeBuffer)

	const ClampedDt = math.clamp(DeltaTime or (1 / 60), 1e-4, MAX_DELTA_TIME) :: number
	const StepDt = ClampedDt / SUBSTEPS :: number
	local PendingJump = JumpRequested :: boolean

	for _ = 1, SUBSTEPS do
		const WasGrounded = PlayerGrounded :: boolean
		PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded = PhysicsLibrary.StepPlayerVelocity(
			PlayerVelX,
			PlayerVelY,
			PlayerVelZ,
			WishX,
			WishZ,
			WishScale,
			PendingJump,
			PlayerGrounded,
			StepDt
		)

		if WasGrounded and PendingJump then
			PendingJump = false
		end

		PlayerPosX += PlayerVelX * StepDt
		PlayerPosY += PlayerVelY * StepDt
		PlayerPosZ += PlayerVelZ * StepDt

		PlayerPosX, PlayerPosY, PlayerPosZ, PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded =
			PhysicsLibrary.ResolveBodyWorldCollisions(
				PlayerPosX,
				PlayerPosY,
				PlayerPosZ,
				PLAYER_HX,
				PLAYER_HY,
				PLAYER_HZ,
				PlayerVelX,
				PlayerVelY,
				PlayerVelZ,
				PLAYER_INV_MASS,
				0,
				0,
				EntityCount,
				PositionBuffer,
				SizeBuffer,
				DirectionsBuffer,
				DynamicFlags,
				ObjectVelocityBuffer,
				ObjectInvMassBuffer
			)

		for EntityId = 1, EntityCount do
			if buffer.readu8(DynamicFlags, EntityId - 1) == 1 then
				StepSingleDynamicObject(EntityId, EntityCount, StepDt, PositionBuffer, SizeBuffer, DirectionsBuffer)
			end
		end
	end

	ClearAccumulatedForces()

	if PlayerPosY < VOID_RESET_Y then
		PlayerPosX, PlayerPosY, PlayerPosZ = SpawnPosX, SpawnPosY, SpawnPosZ
		PlayerVelX, PlayerVelY, PlayerVelZ = 0, 0, 0
		PlayerGrounded = false
	end

	if HostRootPart and HostRootPart.Parent then
		HostRootPart.CFrame = HostRootPart.CFrame.Rotation + Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ)
	end

	PhysicsMovementQueue.Clear()
end

function PhysicsController.SetEntityDynamic(EntityId: number, IsDynamic: boolean, CustomMass: number?)
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end

	const FlagIndex = EntityId - 1 :: number
	if not IsDynamic then
		buffer.writeu8(DynamicFlags, FlagIndex, 0)
		buffer.writef32(ObjectInvMassBuffer, FlagIndex * 4, 0)
		return
	end

	if ECSSizeBuffer then
		EnsureDynamicEntityMass(EntityId, ECSSizeBuffer, CustomMass)
	end
	buffer.writeu8(DynamicFlags, FlagIndex, 1)
end

function PhysicsController.GetPlayerPosition(): Vector3
	return Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ)
end

function PhysicsController.SetPlayerPosition(NewPosition: Vector3)
	PlayerPosX, PlayerPosY, PlayerPosZ = NewPosition.X, NewPosition.Y, NewPosition.Z
	if HostRootPart and HostRootPart.Parent then
		HostRootPart.CFrame = HostRootPart.CFrame.Rotation + NewPosition
	end
end

function PhysicsController.GetPlayerVelocity(): Vector3
	return Vector3.new(PlayerVelX, PlayerVelY, PlayerVelZ)
end

function PhysicsController.SetPlayerVelocity(NewVelocity: Vector3)
	PlayerVelX, PlayerVelY, PlayerVelZ = NewVelocity.X, NewVelocity.Y, NewVelocity.Z
end

function PhysicsController.IsPlayerGrounded(): boolean
	return PlayerGrounded
end

return PhysicsController
