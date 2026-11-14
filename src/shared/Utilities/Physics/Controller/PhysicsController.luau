--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
const PhysicsFolder = UtilitiesFolder:WaitForChild("Physics")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const PhysicsMath = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMath"))
const PhysicsControllerHelper = require(script.Parent.PhysicsControllerHelper)

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

const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const DEFAULT_OBJECT_IMPULSE = SystemsConfigs.ObjectDefaultImpulse :: number
const DEFAULT_OBJECT_SPEED = SystemsConfigs.ObjectDefaultSpeed :: number

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number

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

local PendingWishX = 0 :: number
local PendingWishZ = 0 :: number
local PendingMaxScale = 0 :: number
local PendingJumpRequested = false :: boolean

local HostRootPart: BasePart? = nil
local CharacterSeeded = false :: boolean
local CharacterAddedConnection: RBXScriptConnection? = nil
local ECSDataModule: any = nil

-- Buffers
local ECSPositionBuffer: buffer? = nil
local ECSSizeBuffer: buffer? = nil
local ECSDirectionsBuffer: buffer? = nil
local ECSOrientationBuffer: buffer? = nil
local ECSPropertiesBuffer: buffer? = nil

const DynamicFlags = buffer.create(MAX_ENTITIES) :: buffer -- 0 = static, 1 = awake dynamic, 2 = sleeping dynamic
const ObjectGroundedFlags = buffer.create(MAX_ENTITIES) :: buffer
const ObjectVelocityBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectAngularVelocityBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectForceBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectInvMassBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const ActiveForceSlots = buffer.create(MAX_ENTITIES * 4) :: buffer

local PhysicsController = {}

-- ============================================================================
-- 1. PUBLIC CONTROLLER API - INITIALIZATION, DIRECT ACTIONS & SIMULATION
-- ============================================================================

function PhysicsController.BindPlrCharacter(Character: Model)
	const RootPart, StartX, StartY, StartZ = PhysicsControllerHelper.ConfigureCharacterInstance(Character)
	HostRootPart = RootPart
	CharacterSeeded = true

	if CharacterAddedConnection then
		CharacterAddedConnection:Disconnect()
		CharacterAddedConnection = nil
	end

	SpawnPosX, SpawnPosY, SpawnPosZ = StartX, StartY, StartZ
	PlayerPosX, PlayerPosY, PlayerPosZ = StartX, StartY, StartZ
	PlayerVelX, PlayerVelY, PlayerVelZ = 0, 0, 0
end

function PhysicsController.InitializePhysics()
	if Initialized then
		return
	end

	const ObjectStorageModule = PhysicsControllerHelper.ResolveObjectStorage()
	if ObjectStorageModule then
		const ObjectStorage = (require :: any)(ObjectStorageModule)
		ECSDataModule = ObjectStorage.ECSData
		ECSPositionBuffer = ObjectStorage.PositionData.GetData()
		ECSSizeBuffer = ObjectStorage.SizeData.GetData()
		ECSDirectionsBuffer = ObjectStorage.DirectionsData.GetData()
		ECSOrientationBuffer = if ObjectStorage.OrientationData then ObjectStorage.OrientationData.GetData() else nil
		ECSPropertiesBuffer = ObjectStorage.PropertiesData.GetData()
	end

	Initialized = true

	if not IS_CLIENT then
		RunService.Heartbeat:Connect(PhysicsController.SimulatePhysicsFrame)
		return
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer or CharacterSeeded then
		return
	end

	if LocalPlayer.Character then
		PhysicsController.BindCharacter(LocalPlayer.Character)
	else
		CharacterAddedConnection = LocalPlayer.CharacterAdded:Once(function(Character: Model)
			if not CharacterSeeded then
				PhysicsController.BindCharacter(Character)
			end
		end)
	end
end

function PhysicsController.AddPlayerMovement(
	DirX: number,
	DirY: number,
	DirZ: number,
	Scale: number?,
	Jump: boolean?,
	IsImpulse: boolean?
)
	const ResolvedScale = if Scale ~= nil then Scale else 1.0 :: number

	if Jump then
		PendingJumpRequested = true
	end

	if IsImpulse then
		PlayerVelX += DirX * ResolvedScale * PLAYER_INV_MASS
		PlayerVelY += DirY * ResolvedScale * PLAYER_INV_MASS
		PlayerVelZ += DirZ * ResolvedScale * PLAYER_INV_MASS
		return
	end

	PendingWishX += DirX * ResolvedScale
	PendingWishZ += DirZ * ResolvedScale
	PendingMaxScale = math.max(PendingMaxScale, math.abs(ResolvedScale))
end

function PhysicsController.AddObjectMovement(
	EntityId: number,
	DirX: number,
	DirY: number,
	DirZ: number,
	Magnitude: number,
	IsImpulse: boolean?
)
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end

	const InverseMass = PhysicsControllerHelper.EnsureDynamicEntityMass(
		EntityId,
		ObjectInvMassBuffer,
		ECSSizeBuffer,
		ECSPropertiesBuffer,
		nil
	) :: number
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	buffer.writeu8(DynamicFlags, FlagIndex, 1)

	if IsImpulse then
		const DeltaVelocity = Magnitude * InverseMass :: number
		buffer.writef32(
			ObjectVelocityBuffer,
			CompOffset,
			buffer.readf32(ObjectVelocityBuffer, CompOffset) + DirX * DeltaVelocity
		)
		buffer.writef32(
			ObjectVelocityBuffer,
			CompOffset + 4,
			buffer.readf32(ObjectVelocityBuffer, CompOffset + 4) + DirY * DeltaVelocity
		)
		buffer.writef32(
			ObjectVelocityBuffer,
			CompOffset + 8,
			buffer.readf32(ObjectVelocityBuffer, CompOffset + 8) + DirZ * DeltaVelocity
		)
		return
	end

	const PrevForceX = buffer.readf32(ObjectForceBuffer, CompOffset) :: number
	const PrevForceY = buffer.readf32(ObjectForceBuffer, CompOffset + 4) :: number
	const PrevForceZ = buffer.readf32(ObjectForceBuffer, CompOffset + 8) :: number

	if PrevForceX == 0 and PrevForceY == 0 and PrevForceZ == 0 and ActiveForceCount < MAX_ENTITIES then
		buffer.writeu32(ActiveForceSlots, ActiveForceCount * 4, CompOffset)
		ActiveForceCount += 1
	end

	buffer.writef32(ObjectForceBuffer, CompOffset, PrevForceX + DirX * Magnitude)
	buffer.writef32(ObjectForceBuffer, CompOffset + 4, PrevForceY + DirY * Magnitude)
	buffer.writef32(ObjectForceBuffer, CompOffset + 8, PrevForceZ + DirZ * Magnitude)
end

function PhysicsController.SimulatePhysicsFrame(DeltaTime: number?)
	if not Initialized then
		PhysicsController.InitializePhysics()
	end

	const PositionBuffer = ECSPositionBuffer
	const SizeBuffer = ECSSizeBuffer
	const DirectionsBuffer = ECSDirectionsBuffer
	if not PositionBuffer or not SizeBuffer or not DirectionsBuffer or not ECSDataModule then
		PendingWishX = 0
		PendingWishZ = 0
		PendingMaxScale = 0
		PendingJumpRequested = false
		ActiveForceCount =
			PhysicsControllerHelper.ClearAccumulatedForces(ActiveForceCount, ActiveForceSlots, ObjectForceBuffer)
		return
	end

	const EntityCount = math.min(ECSDataModule.GetCounts().EntityECSCount :: number, MAX_ENTITIES) :: number
	if EntityCount <= 0 then
		PendingWishX = 0
		PendingWishZ = 0
		PendingMaxScale = 0
		PendingJumpRequested = false
		ActiveForceCount =
			PhysicsControllerHelper.ClearAccumulatedForces(ActiveForceCount, ActiveForceSlots, ObjectForceBuffer)
		return
	end

	PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested =
		PhysicsControllerHelper.SampleKeyboardInput(PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested)

	const WishX: number, WishZ: number, WishScale: number, JumpRequested: boolean =
		PhysicsControllerHelper.FlushPlayerIntent(PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested)
	PendingWishX = 0
	PendingWishZ = 0
	PendingMaxScale = 0
	PendingJumpRequested = false

	const ClampedDeltaTime = math.clamp(DeltaTime or (1 / 60), 1e-4, MAX_DELTA_TIME) :: number
	const StepDeltaTime = ClampedDeltaTime / SUBSTEPS :: number
	local PendingJump = JumpRequested :: boolean

	for _ = 1, SUBSTEPS do
		if IS_CLIENT then
			const WasGrounded = PlayerGrounded :: boolean
			PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded = PhysicsMath.StepPlayerVelocity(
				PlayerVelX,
				PlayerVelY,
				PlayerVelZ,
				WishX,
				WishZ,
				WishScale,
				PendingJump,
				PlayerGrounded,
				StepDeltaTime
			)

			if WasGrounded and PendingJump then
				PendingJump = false
			end

			PlayerPosX += PlayerVelX * StepDeltaTime
			PlayerPosY += PlayerVelY * StepDeltaTime
			PlayerPosZ += PlayerVelZ * StepDeltaTime

			PlayerPosX, PlayerPosY, PlayerPosZ, PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded =
				PhysicsMath.ResolveBodyWorldCollisions(
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
		end

		for EntityId = 1, EntityCount do
			if buffer.readu8(DynamicFlags, EntityId - 1) == 1 then
				PhysicsControllerHelper.StepSingleDynamicObject(
					EntityId,
					EntityCount,
					StepDeltaTime,
					PositionBuffer,
					SizeBuffer,
					DirectionsBuffer,
					ECSOrientationBuffer,
					DynamicFlags,
					ObjectGroundedFlags,
					ObjectVelocityBuffer,
					ObjectAngularVelocityBuffer,
					ObjectForceBuffer,
					ObjectInvMassBuffer
				)
			end
		end
	end

	ActiveForceCount =
		PhysicsControllerHelper.ClearAccumulatedForces(ActiveForceCount, ActiveForceSlots, ObjectForceBuffer)

	if IS_CLIENT then
		if PlayerPosY < VOID_RESET_Y then
			PlayerPosX, PlayerPosY, PlayerPosZ = SpawnPosX, SpawnPosY, SpawnPosZ
			PlayerVelX, PlayerVelY, PlayerVelZ = 0, 0, 0
			PlayerGrounded = false
		end

		if HostRootPart then
			if HostRootPart.Parent then
				HostRootPart.CFrame = HostRootPart.CFrame.Rotation + Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ)
			else
				HostRootPart = nil
			end
		end
	end
end

function PhysicsController.SimulateInstance(
	EntityId: number,
	Angle: (Vector3 | number)?,
	Impulse: number?,
	Speed: number?,
	CustomMass: number?
): boolean
	if not Initialized then
		PhysicsController.InitializePhysics()
	end

	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return false
	end

	const FlagIndex = EntityId - 1 :: number
	if ECSPropertiesBuffer then
		const PropReg = buffer.readu32(ECSPropertiesBuffer, FlagIndex * 4) :: number
		if bit32.btest(PropReg, FLAG_ANCHORED) then
			return false
		end
	end

	const InverseMass = PhysicsControllerHelper.EnsureDynamicEntityMass(
		EntityId,
		ObjectInvMassBuffer,
		ECSSizeBuffer,
		ECSPropertiesBuffer,
		CustomMass
	) :: number

	const DirX: number, DirY: number, DirZ: number = PhysicsControllerHelper.ResolveLaunchDirection(Angle)
	const ResolvedImpulse = if Impulse ~= nil then Impulse else DEFAULT_OBJECT_IMPULSE :: number
	const ResolvedSpeed = if Speed ~= nil then Speed else DEFAULT_OBJECT_SPEED :: number
	const TotalLaunchSpeed = ResolvedSpeed + ResolvedImpulse * InverseMass :: number

	const VelX = DirX * TotalLaunchSpeed :: number
	const VelY = DirY * TotalLaunchSpeed :: number
	const VelZ = DirZ * TotalLaunchSpeed :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	buffer.writeu8(DynamicFlags, FlagIndex, 1)
	buffer.writef32(ObjectVelocityBuffer, CompOffset, VelX)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, VelY)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, VelZ)

	local Radius = 1.0 :: number
	if ECSSizeBuffer then
		const SizeX = buffer.readf32(ECSSizeBuffer, CompOffset) :: number
		const SizeY = buffer.readf32(ECSSizeBuffer, CompOffset + 4) :: number
		const SizeZ = buffer.readf32(ECSSizeBuffer, CompOffset + 8) :: number
		Radius = math.max(0.25, (SizeX + SizeY + SizeZ) / 6)
	end

	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset, VelZ / Radius)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 4, 0)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 8, -VelX / Radius)

	return true
end

function PhysicsController.StopSimulatingInstance(EntityId: number)
	if not Initialized then
		PhysicsController.InitializePhysics()
	end

	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end

	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	buffer.writeu8(DynamicFlags, FlagIndex, 0)
	buffer.writeu8(ObjectGroundedFlags, FlagIndex, 0)
	buffer.writef32(ObjectInvMassBuffer, FlagIndex * 4, 0)
	buffer.writef32(ObjectVelocityBuffer, CompOffset, 0)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, 0)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, 0)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset, 0)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 4, 0)
	buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 8, 0)
	buffer.writef32(ObjectForceBuffer, CompOffset, 0)
	buffer.writef32(ObjectForceBuffer, CompOffset + 4, 0)
	buffer.writef32(ObjectForceBuffer, CompOffset + 8, 0)
end

function PhysicsController.SetEntityDynamic(EntityId: number, IsDynamic: boolean, CustomMass: number?)
	if not IsDynamic then
		PhysicsController.StopSimulatingInstance(EntityId)
		return
	end

	PhysicsController.SimulateInstance(EntityId, Vector3.zero, 0, 0, CustomMass)
end

function PhysicsController.GetPlayerPosition(): Vector3
	return Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ)
end

function PhysicsController.SetPlayerPosition(NewPosition: Vector3)
	PlayerPosX, PlayerPosY, PlayerPosZ = NewPosition.X, NewPosition.Y, NewPosition.Z
	if HostRootPart then
		if HostRootPart.Parent then
			HostRootPart.CFrame = HostRootPart.CFrame.Rotation + NewPosition
		else
			HostRootPart = nil
		end
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
