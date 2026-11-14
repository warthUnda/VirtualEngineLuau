--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")
const UserInputService = game:GetService("UserInputService")

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
const PhysicsFolder = UtilitiesFolder:WaitForChild("Physics")

-- Modules --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const PhysicsMath = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMath"))
const PhysicsMathHelper = require(PhysicsFolder:WaitForChild("Core"):WaitForChild("PhysicsMathHelper"))

const CameraStore = if IS_CLIENT
	then require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Camera"):WaitForChild("CameraStore"))
	else nil

-- Configs --
const OBJECT_DEFAULT_DENSITY = SystemsConfigs.ObjectDefaultDensity :: number
const OBJECT_RESTITUTION = SystemsConfigs.ObjectRestitution :: number
const DEFAULT_LAUNCH_ANGLE = SystemsConfigs.ObjectDefaultLaunchAngle :: Vector3
const SLEEP_SPEED_THRESHOLD = SystemsConfigs.ObjectSleepSpeedThreshold :: number
const SLEEP_SPEED_SQ = SLEEP_SPEED_THRESHOLD * SLEEP_SPEED_THRESHOLD :: number
const PLAYER_MAX_WISH_SCALE = SystemsConfigs.PlayerMaxWishScale :: number
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_IS_VISIBLE = bit32.lshift(1, 2) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number

local PhysicsControllerHelper = {}

-- ============================================================================
-- 1. STORAGE RESOLUTION, INPUT SAMPLING & DYNAMIC OBJECT STEPPING HELPERS
-- ============================================================================

--[=[
	Resolves the active client or server ObjectStorage module reference.
	@return Instance? -- Resolved Storage module instance.
]=]
function PhysicsControllerHelper.ResolveObjectStorage(): Instance?
	if not IS_CLIENT then
		const ServerFolder = ServerScriptService:FindFirstChild("Server")
		const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
		const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
		return if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
	end

	const LocalPlayer = Players.LocalPlayer :: Player?
	if not LocalPlayer then
		return nil
	end

	const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
	const ControllerActor = PlayerScripts:FindFirstChild("Controller") :: Actor?
	if ControllerActor then
		const ActorStorage = ControllerActor:FindFirstChild("ObjectStorage")
		if ActorStorage then
			return ActorStorage
		end
	end

	return PlayerScripts:WaitForChild("Client"):WaitForChild("Objects"):WaitForChild("ObjectStorage")
end

--[=[
	Extracts an initial spawn position and optional root BasePart from a character model without requiring a Humanoid.
	@param Character Model -- Character model instance.
	@return (BasePart?, number, number, number) -- Optional RootPart, InitialX, InitialY, InitialZ.
]=]
function PhysicsControllerHelper.ConfigureCharacterInstance(
	Character: Model
): (BasePart?, number, number, number)
	const Humanoid = Character:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
	if Humanoid then
		Humanoid.PlatformStand = true
	end

	for _, Descendant: Instance in ipairs(Character:GetDescendants()) do
		if Descendant:IsA("BasePart") then
			Descendant.CanCollide = false
		end
	end

	const RootPartCandidate = Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")

	if RootPartCandidate and RootPartCandidate:IsA("BasePart") then
		const RootPart = RootPartCandidate :: BasePart
		RootPart.Anchored = true
		RootPart.CanCollide = false

		const StartPos = RootPart.Position :: Vector3
		return RootPart, StartPos.X, StartPos.Y + 0.5, StartPos.Z
	end

	const PivotPos = Character:GetPivot().Position :: Vector3
	return nil, PivotPos.X, PivotPos.Y + 0.5, PivotPos.Z
end

--[=[
	Waits briefly for a live Workspace character model's root BasePart to replicate before seeding spawn coordinates.
	@param Character Model -- Spawned character model.
]=]
function PhysicsControllerHelper.AwaitCharacterRoot(Character: Model)
	if not Character.Parent then
		return
	end

	const ExistingRoot = Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")
	if not ExistingRoot then
		Character:WaitForChild("HumanoidRootPart", 2)
	end
end

--[=[
	Samples WASD and Space keyboard inputs relative to camera orientation.
	@param PendingWishX number -- Accumulated wish direction X.
	@param PendingWishZ number -- Accumulated wish direction Z.
	@param PendingMaxScale number -- Accumulated wish scale.
	@param PendingJumpRequested boolean -- Accumulated jump flag.
	@return (number, number, number, boolean) -- WishX, WishZ, MaxScale, JumpRequested.
]=]
function PhysicsControllerHelper.SampleKeyboardInput(
	PendingWishX: number,
	PendingWishZ: number,
	PendingMaxScale: number,
	PendingJumpRequested: boolean
): (number, number, number, boolean)
	if not IS_CLIENT or not CameraStore then
		return PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested
	end

	if UserInputService:GetFocusedTextBox() ~= nil then
		return PendingWishX, PendingWishZ, PendingMaxScale, PendingJumpRequested
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

	local NextWishX = PendingWishX :: number
	local NextWishZ = PendingWishZ :: number
	local NextMaxScale = PendingMaxScale :: number
	local NextJumpRequested = PendingJumpRequested :: boolean

	const MoveLen = math.sqrt(MoveX * MoveX + MoveZ * MoveZ) :: number
	if MoveLen > 1e-5 then
		NextWishX += MoveX / MoveLen
		NextWishZ += MoveZ / MoveLen
		NextMaxScale = math.max(NextMaxScale, 1.0)
	end

	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		NextJumpRequested = true
	end

	return NextWishX, NextWishZ, NextMaxScale, NextJumpRequested
end

--[=[
	Normalizes and clamps accumulated player wish-direction intent.
	@param RawWishX number -- Raw accumulated wish direction X.
	@param RawWishZ number -- Raw accumulated wish direction Z.
	@param MaxScale number -- Accumulated wish scale.
	@param JumpRequested boolean -- Whether jump was requested.
	@return (number, number, number, boolean) -- UnitWishX, UnitWishZ, ClampedScale, JumpRequested.
]=]
function PhysicsControllerHelper.FlushPlayerIntent(
	RawWishX: number,
	RawWishZ: number,
	MaxScale: number,
	JumpRequested: boolean
): (number, number, number, boolean)
	const WishLen = math.sqrt(RawWishX * RawWishX + RawWishZ * RawWishZ) :: number
	if WishLen <= 1e-5 then
		return 0, 0, 0, JumpRequested
	end

	return RawWishX / WishLen, RawWishZ / WishLen, math.min(MaxScale, PLAYER_MAX_WISH_SCALE), JumpRequested
end

--[=[
	Calculates and writes dynamic entity mass and inverse mass into storage buffers.
	@param EntityId number -- Target ECS entity ID.
	@param ObjectInvMassBuffer buffer -- Dynamic inverse mass buffer.
	@param SizeBuffer buffer? -- ECS part sizes buffer.
	@param PropertiesBuffer buffer? -- ECS properties buffer.
	@param CustomMass number? -- Optional explicit mass override in kg.
	@return number -- Inverted mass (1 / mass).
]=]
function PhysicsControllerHelper.EnsureDynamicEntityMass(
	EntityId: number,
	ObjectInvMassBuffer: buffer,
	SizeBuffer: buffer?,
	PropertiesBuffer: buffer?,
	CustomMass: number?
): number
	const MassOffset = (EntityId - 1) * 4 :: number
	const ExistingInvMass = buffer.readf32(ObjectInvMassBuffer, MassOffset) :: number
	if ExistingInvMass > 0 and CustomMass == nil then
		return ExistingInvMass
	end

	local ResolvedMass = CustomMass :: number?
	if not ResolvedMass or ResolvedMass <= 0 then
		if SizeBuffer then
			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const SizeX = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset)) :: number
			const SizeY = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 4)) :: number
			const SizeZ = math.max(0.1, buffer.readf32(SizeBuffer, CompOffset + 8)) :: number
			ResolvedMass = SizeX * SizeY * SizeZ * OBJECT_DEFAULT_DENSITY
		else
			ResolvedMass = OBJECT_DEFAULT_DENSITY
		end
	end

	const InverseMass = 1 / (ResolvedMass :: number) :: number
	buffer.writef32(ObjectInvMassBuffer, MassOffset, InverseMass)

	if PropertiesBuffer then
		const PropReg = buffer.readu32(PropertiesBuffer, MassOffset) :: number
		const UpdatedReg =
			bit32.bor(bit32.band(PropReg, bit32.bnot(FLAG_ANCHORED)), FLAG_CAN_COLLIDE, FLAG_IS_VISIBLE) :: number
		buffer.writeu32(PropertiesBuffer, MassOffset, UpdatedReg)
	end

	return InverseMass
end

--[=[
	Resolves a unit launch direction vector from an optional Vector3 direction, yaw angle in degrees, or prepackaged config default.
	@param Angle (Vector3 | number)? -- Optional world direction vector or horizontal yaw angle in degrees.
	@return (number, number, number) -- Normalized (DirX, DirY, DirZ).
]=]
function PhysicsControllerHelper.ResolveLaunchDirection(Angle: (Vector3 | number)?): (number, number, number)
	if typeof(Angle) == "Vector3" then
		const Len = Angle.Magnitude :: number
		if Len <= 1e-6 then
			return 0, 0, 0
		end
		const InvLen = 1 / Len :: number
		return Angle.X * InvLen, Angle.Y * InvLen, Angle.Z * InvLen
	elseif type(Angle) == "number" then
		const Rad = math.rad(Angle) :: number
		const RawX = math.cos(Rad) :: number
		const RawY = DEFAULT_LAUNCH_ANGLE.Y :: number
		const RawZ = math.sin(Rad) :: number
		const InvLen = 1 / math.sqrt(RawX * RawX + RawY * RawY + RawZ * RawZ) :: number
		return RawX * InvLen, RawY * InvLen, RawZ * InvLen
	end

	return DEFAULT_LAUNCH_ANGLE.X, DEFAULT_LAUNCH_ANGLE.Y, DEFAULT_LAUNCH_ANGLE.Z
end

--[=[
	Simulates a single substepped physics frame for an active dynamic ECS object.
	@param EntityId number -- Target entity ID.
	@param EntityCount number -- Total active ECS entity count.
	@param StepDeltaTime number -- Substep delta time in seconds.
	@param PositionBuffer buffer -- ECS positions buffer.
	@param SizeBuffer buffer -- ECS sizes buffer.
	@param DirectionsBuffer buffer -- ECS directions buffer.
	@param OrientationBuffer buffer? -- Optional ECS orientation buffer.
	@param DynamicFlags buffer -- ECS dynamic state buffer.
	@param ObjectGroundedFlags buffer -- ECS grounded state buffer.
	@param ObjectVelocityBuffer buffer -- Dynamic objects velocity buffer.
	@param ObjectAngularVelocityBuffer buffer -- Dynamic objects angular velocity buffer.
	@param ObjectForceBuffer buffer -- Dynamic objects force buffer.
	@param ObjectInvMassBuffer buffer -- Dynamic objects inverse mass buffer.
]=]
function PhysicsControllerHelper.StepSingleDynamicObject(
	EntityId: number,
	EntityCount: number,
	StepDeltaTime: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	OrientationBuffer: buffer?,
	DynamicFlags: buffer,
	ObjectGroundedFlags: buffer,
	ObjectVelocityBuffer: buffer,
	ObjectAngularVelocityBuffer: buffer,
	ObjectForceBuffer: buffer,
	ObjectInvMassBuffer: buffer
)
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	const InverseMass = buffer.readf32(ObjectInvMassBuffer, FlagIndex * 4) :: number
	if InverseMass <= 0 then
		buffer.writeu8(DynamicFlags, FlagIndex, 0)
		return
	end

	const WasGrounded = (buffer.readu8(ObjectGroundedFlags, FlagIndex) == 1) :: boolean
	const ForceX = buffer.readf32(ObjectForceBuffer, CompOffset) :: number
	const ForceY = buffer.readf32(ObjectForceBuffer, CompOffset + 4) :: number
	const ForceZ = buffer.readf32(ObjectForceBuffer, CompOffset + 8) :: number

	local VelocityX: number, VelocityY: number, VelocityZ: number = PhysicsMath.StepObjectVelocity(
		buffer.readf32(ObjectVelocityBuffer, CompOffset),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 4),
		buffer.readf32(ObjectVelocityBuffer, CompOffset + 8),
		ForceX,
		ForceY,
		ForceZ,
		InverseMass,
		WasGrounded,
		StepDeltaTime
	)

	const PreCollisionVelX = VelocityX :: number
	const PreCollisionVelY = VelocityY :: number
	const PreCollisionVelZ = VelocityZ :: number

	local PosX = buffer.readf32(PositionBuffer, CompOffset) + VelocityX * StepDeltaTime :: number
	local PosY = buffer.readf32(PositionBuffer, CompOffset + 4) + VelocityY * StepDeltaTime :: number
	local PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) + VelocityZ * StepDeltaTime :: number

	const HalfSizeX = buffer.readf32(SizeBuffer, CompOffset) * 0.5 :: number
	const HalfSizeY = buffer.readf32(SizeBuffer, CompOffset + 4) * 0.5 :: number
	const HalfSizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) * 0.5 :: number

	local Grounded: boolean
	PosX, PosY, PosZ, VelocityX, VelocityY, VelocityZ, Grounded = PhysicsMath.ResolveBodyWorldCollisions(
		PosX,
		PosY,
		PosZ,
		HalfSizeX,
		HalfSizeY,
		HalfSizeZ,
		VelocityX,
		VelocityY,
		VelocityZ,
		InverseMass,
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

	const AngSpeedSquared = PhysicsMathHelper.StepObjectRotation(
		EntityId,
		HalfSizeX,
		HalfSizeY,
		HalfSizeZ,
		PreCollisionVelX,
		PreCollisionVelY,
		PreCollisionVelZ,
		VelocityX,
		VelocityY,
		VelocityZ,
		Grounded,
		StepDeltaTime,
		DirectionsBuffer,
		OrientationBuffer,
		ObjectAngularVelocityBuffer
	) :: number

	const SpeedSquared = VelocityX * VelocityX + VelocityY * VelocityY + VelocityZ * VelocityZ :: number
	const HasAppliedForce = (ForceX ~= 0 or ForceY ~= 0 or ForceZ ~= 0) :: boolean
	if Grounded and not HasAppliedForce and SpeedSquared < SLEEP_SPEED_SQ and AngSpeedSquared < SLEEP_SPEED_SQ then
		buffer.writef32(ObjectVelocityBuffer, CompOffset, 0)
		buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, 0)
		buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, 0)
		buffer.writef32(ObjectAngularVelocityBuffer, CompOffset, 0)
		buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 4, 0)
		buffer.writef32(ObjectAngularVelocityBuffer, CompOffset + 8, 0)
		buffer.writeu8(DynamicFlags, FlagIndex, 2)
		return
	end

	buffer.writef32(ObjectVelocityBuffer, CompOffset, VelocityX)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 4, VelocityY)
	buffer.writef32(ObjectVelocityBuffer, CompOffset + 8, VelocityZ)
end

--[=[
	Clears accumulated continuous force vectors for dynamic entities.
	@param ActiveForceCount number -- Number of entities with active forces.
	@param ActiveForceSlots buffer -- Buffer storing component byte offsets of entities with forces.
	@param ObjectForceBuffer buffer -- Force component buffer.
	@return number -- Reset active force count (0).
]=]
function PhysicsControllerHelper.ClearAccumulatedForces(
	ActiveForceCount: number,
	ActiveForceSlots: buffer,
	ObjectForceBuffer: buffer
): number
	for i = 0, ActiveForceCount - 1 do
		const CompOffset = buffer.readu32(ActiveForceSlots, i * 4) :: number
		buffer.writef32(ObjectForceBuffer, CompOffset, 0)
		buffer.writef32(ObjectForceBuffer, CompOffset + 4, 0)
		buffer.writef32(ObjectForceBuffer, CompOffset + 8, 0)
	end
	return 0
end

return PhysicsControllerHelper
