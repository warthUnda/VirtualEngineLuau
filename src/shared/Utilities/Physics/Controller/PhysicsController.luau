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
const RequireAny = require :: any

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const BVH = require(UtilitiesFolder:WaitForChild("BVH"))
const PhysicsMath = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMath"))
const PlayerPhysics = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PlayerPhysics"))
const PhysicsControllerHelper = require(script.Parent.PhysicsControllerHelper)
const PhysicsAwakeState = require(script.Parent.PhysicsAwakeState)
const PhysicsInstanceManager = require(script.Parent.PhysicsInstanceManager)

-- Configs --
const MAX_DELTA_TIME = SystemsConfigs.PhysicsMaxDeltaTime :: number
const SUBSTEPS = math.max(1, SystemsConfigs.PhysicsSubsteps) :: number
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3
const VOID_RESET_Y = SystemsConfigs.PlayerVoidResetY :: number
const PLAYER_INV_MASS = 1 / (SystemsConfigs.PlayerMass :: number) :: number
const PLAYER_HALF_EXTENTS = SystemsConfigs.PlayerHalfExtents :: Vector3
const PLAYER_HX: number, PLAYER_HY: number, PLAYER_HZ: number = PLAYER_HALF_EXTENTS.X, PLAYER_HALF_EXTENTS.Y, PLAYER_HALF_EXTENTS.Z
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number

-- Variables --
local Initialized = false :: boolean
local SpawnPosX: number, SpawnPosY: number, SpawnPosZ: number = DEFAULT_SPAWN.X, DEFAULT_SPAWN.Y, DEFAULT_SPAWN.Z
local PlayerPosX: number, PlayerPosY: number, PlayerPosZ: number = DEFAULT_SPAWN.X, DEFAULT_SPAWN.Y, DEFAULT_SPAWN.Z
local PlayerVelX: number, PlayerVelY: number, PlayerVelZ: number = 0, 0, 0
local PlayerGrounded = false :: boolean
local PendingWishX: number, PendingWishZ: number, PendingMaxScale: number = 0, 0, 0
local PendingJumpRequested = false :: boolean
local HostRootPart: BasePart? = nil
local CharacterSeeded = false :: boolean
local CharacterAddedConnection: RBXScriptConnection? = nil
local ECSObjectStorage: any, ECSDataModule: any = nil, nil
local ECSPositionBuffer: buffer?, ECSSizeBuffer: buffer? = nil, nil
local ECSDirectionsBuffer: buffer?, ECSPropertiesBuffer: buffer? = nil, nil

-- Tables --
local PhysicsController = {}

-- Functions --
-- ============================================================================
-- 1. PUBLIC CONTROLLER FACADE - INITIALIZATION, DIRECT ACTIONS & SIMULATION
-- ============================================================================

function PhysicsController.BindCharacter(Character: Model)
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
	if Initialized then return end

	const ObjectStorageModule = PhysicsControllerHelper.ResolveObjectStorage()
	if ObjectStorageModule then
		const ObjectStorage = RequireAny(ObjectStorageModule)
		ECSObjectStorage = ObjectStorage
		ECSDataModule = ObjectStorage.ECSData
		ECSPositionBuffer = ObjectStorage.PositionData.GetData()
		ECSSizeBuffer = ObjectStorage.SizeData.GetData()
		ECSDirectionsBuffer = ObjectStorage.DirectionsData.GetData()
		ECSPropertiesBuffer = ObjectStorage.PropertiesData.GetData()
		if ECSDataModule and ECSDataModule.SetSwapPopCallback then
			ECSDataModule.SetSwapPopCallback(PhysicsAwakeState.OnEntitySwapPop)
		end
	end

	PhysicsMath.SetWakeEntityCallback(function(EntityId: number)
		PhysicsAwakeState.AddAwakeEntity(EntityId)
		if ECSDataModule then ECSDataModule.MarkDirty(EntityId) end
	end)

	Initialized = true
	if not IS_CLIENT then
		RunService.Heartbeat:Connect(PhysicsController.SimulatePhysicsFrame)
		return
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer or CharacterSeeded then return end
	if LocalPlayer.Character then
		task.spawn(function()
			const Character = LocalPlayer.Character
			if Character and not CharacterSeeded then
				PhysicsControllerHelper.AwaitCharacterRoot(Character)
				if not CharacterSeeded then PhysicsController.BindCharacter(Character) end
			end
		end)
	else
		CharacterAddedConnection = LocalPlayer.CharacterAdded:Once(function(Character: Model)
			PhysicsControllerHelper.AwaitCharacterRoot(Character)
			if not CharacterSeeded then PhysicsController.BindCharacter(Character) end
		end)
	end
end

function PhysicsController.AddPlayerMovement(DirX: number, DirY: number, DirZ: number, Scale: number?, Jump: boolean?, IsImpulse: boolean?)
	const ResolvedScale = if Scale ~= nil then Scale else 1.0 :: number
	if Jump then PendingJumpRequested = true end
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

function PhysicsController.AddObjectMovement(EntityId: number, DirX: number, DirY: number, DirZ: number, Magnitude: number, IsImpulse: boolean?)
	if not Initialized then PhysicsController.InitializePhysics() end
	PhysicsInstanceManager.ApplyObjectMovement(EntityId, DirX, DirY, DirZ, Magnitude, IsImpulse, ECSSizeBuffer, ECSPropertiesBuffer)
end

function PhysicsController.SimulatePhysicsFrame(DeltaTime: number?)
	if not Initialized then PhysicsController.InitializePhysics() end

	const PositionBuffer, SizeBuffer, DirectionsBuffer = ECSPositionBuffer, ECSSizeBuffer, ECSDirectionsBuffer
	const EntityCount = if ECSDataModule then math.min(ECSDataModule.GetCounts().EntityECSCount :: number, MAX_ENTITIES) else 0 :: number
	if not PositionBuffer or not SizeBuffer or not DirectionsBuffer or EntityCount <= 0 then
		PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested = 0, 0, 0, false
		PhysicsAwakeState.FlushForces()
		return
	end

	PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested =
		PhysicsControllerHelper.SampleKeyboardInput(PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested)
	const WishX: number, WishZ: number, WishScale: number, JumpRequested: boolean =
		PhysicsControllerHelper.FlushPlayerIntent(PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested)
	PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested = 0, 0, 0, false

	const StepDeltaTime = math.clamp(DeltaTime or (1 / 60), 1e-4, MAX_DELTA_TIME) / SUBSTEPS :: number
	local PendingJump = JumpRequested :: boolean
	const DynamicFlags = PhysicsAwakeState.DynamicFlags

	for _ = 1, SUBSTEPS do
		if IS_CLIENT or PhysicsAwakeState.GetAwakeCount() > 0 then
			BVH.EnsureFresh(ECSObjectStorage)
		end

		if IS_CLIENT then
			const WasGrounded = PlayerGrounded :: boolean
			PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded = PlayerPhysics.StepPlayerVelocity(
				PlayerVelX, PlayerVelY, PlayerVelZ, WishX, WishZ, WishScale, PendingJump, PlayerGrounded, StepDeltaTime
			)
			if WasGrounded and PendingJump then PendingJump = false end
			PlayerPosX += PlayerVelX * StepDeltaTime
			PlayerPosY += PlayerVelY * StepDeltaTime
			PlayerPosZ += PlayerVelZ * StepDeltaTime

			PlayerPosX, PlayerPosY, PlayerPosZ, PlayerVelX, PlayerVelY, PlayerVelZ, PlayerGrounded = PhysicsMath.ResolveBodyWorldCollisions(
				PlayerPosX, PlayerPosY, PlayerPosZ, PLAYER_HX, PLAYER_HY, PLAYER_HZ,
				PlayerVelX, PlayerVelY, PlayerVelZ, PLAYER_INV_MASS, 0, 0, EntityCount,
				PositionBuffer, SizeBuffer, DirectionsBuffer, DynamicFlags,
				PhysicsAwakeState.ObjectVelocityBuffer, PhysicsAwakeState.ObjectInvMassBuffer, true
			)
		end

		PhysicsInstanceManager.StepAwakeEntitiesSubstep(
			EntityCount, StepDeltaTime, PositionBuffer, SizeBuffer, DirectionsBuffer, ECSDataModule
		)
	end

	PhysicsAwakeState.FlushForces()
	if not IS_CLIENT then return end

	if PlayerPosY < VOID_RESET_Y then
		PlayerPosX, PlayerPosY, PlayerPosZ = SpawnPosX, SpawnPosY, SpawnPosZ
		PlayerVelX, PlayerVelY, PlayerVelZ = 0, 0, 0
		PlayerGrounded = false
	end
	if HostRootPart and HostRootPart.Parent then
		HostRootPart.CFrame = HostRootPart.CFrame.Rotation + Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ)
	elseif HostRootPart then
		HostRootPart = nil
	end
end

function PhysicsController.SimulateInstance(EntityId: number, Angle: (Vector3 | number)?, Impulse: number?, Speed: number?, CustomMass: number?): boolean
	if not Initialized then PhysicsController.InitializePhysics() end
	return PhysicsInstanceManager.StartSimulatingEntity(EntityId, Angle, Impulse, Speed, CustomMass, ECSSizeBuffer, ECSPropertiesBuffer)
end

function PhysicsController.StopSimulatingInstance(EntityId: number)
	if not Initialized then PhysicsController.InitializePhysics() end
	PhysicsInstanceManager.StopSimulatingEntity(EntityId)
end

function PhysicsController.SetEntityDynamic(EntityId: number, IsDynamic: boolean, CustomMass: number?)
	if not IsDynamic then
		PhysicsController.StopSimulatingInstance(EntityId)
		return
	end
	PhysicsController.SimulateInstance(EntityId, Vector3.zero, 0, 0, CustomMass)
end

function PhysicsController.GetPlayerPosition(): Vector3 return Vector3.new(PlayerPosX, PlayerPosY, PlayerPosZ) end
function PhysicsController.GetPlayerVelocity(): Vector3 return Vector3.new(PlayerVelX, PlayerVelY, PlayerVelZ) end
function PhysicsController.IsPlayerGrounded(): boolean return PlayerGrounded end
function PhysicsController.SetPlayerVelocity(NewVelocity: Vector3) PlayerVelX, PlayerVelY, PlayerVelZ = NewVelocity.X, NewVelocity.Y, NewVelocity.Z end

function PhysicsController.SetPlayerPosition(NewPosition: Vector3)
	PlayerPosX, PlayerPosY, PlayerPosZ = NewPosition.X, NewPosition.Y, NewPosition.Z
	if HostRootPart and HostRootPart.Parent then
		HostRootPart.CFrame = HostRootPart.CFrame.Rotation + NewPosition
	elseif HostRootPart then
		HostRootPart = nil
	end
end

return PhysicsController
