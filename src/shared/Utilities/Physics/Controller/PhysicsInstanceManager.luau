--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const PhysicsControllerHelper = require(script.Parent.PhysicsControllerHelper)
const PhysicsAwakeState = require(script.Parent.PhysicsAwakeState)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const DEFAULT_OBJECT_IMPULSE = SystemsConfigs.ObjectDefaultImpulse :: number
const DEFAULT_OBJECT_SPEED = SystemsConfigs.ObjectDefaultSpeed :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number

-- Tables --
local PhysicsInstanceManager = {}

-- Functions --
-- ============================================================================
-- 1. DYNAMIC ENTITY INSTANCE LAUNCH, FORCE ACCUMULATION & STOP
-- ============================================================================

--[=[
	Applies a continuous force or instantaneous impulse to a dynamic ECS entity.
	@param EntityId number -- 1-based ECS entity identifier.
	@param DirX number -- Direction X component.
	@param DirY number -- Direction Y component.
	@param DirZ number -- Direction Z component.
	@param Magnitude number -- Force or impulse magnitude.
	@param IsImpulse boolean? -- True for instantaneous impulse, false/nil for continuous force.
	@param ECSSizeBuffer buffer? -- Active ECS Size buffer.
	@param ECSPropertiesBuffer buffer? -- Active ECS Properties buffer.
]=]
function PhysicsInstanceManager.ApplyObjectMovement(
	EntityId: number,
	DirX: number,
	DirY: number,
	DirZ: number,
	Magnitude: number,
	IsImpulse: boolean?,
	ECSSizeBuffer: buffer?,
	ECSPropertiesBuffer: buffer?
)
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end

	const InverseMass = PhysicsControllerHelper.EnsureDynamicEntityMass(
		EntityId, PhysicsAwakeState.ObjectInvMassBuffer, ECSSizeBuffer, ECSPropertiesBuffer, nil
	) :: number
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number
	const VelBuf = PhysicsAwakeState.ObjectVelocityBuffer

	buffer.writeu8(PhysicsAwakeState.DynamicFlags, FlagIndex, 1)
	PhysicsAwakeState.AddAwakeEntity(EntityId)

	if IsImpulse then
		const DeltaVelocity = Magnitude * InverseMass :: number
		buffer.writef32(VelBuf, CompOffset, buffer.readf32(VelBuf, CompOffset) + DirX * DeltaVelocity)
		buffer.writef32(VelBuf, CompOffset + 4, buffer.readf32(VelBuf, CompOffset + 4) + DirY * DeltaVelocity)
		buffer.writef32(VelBuf, CompOffset + 8, buffer.readf32(VelBuf, CompOffset + 8) + DirZ * DeltaVelocity)
		return
	end

	PhysicsAwakeState.AccumulateContinuousForce(CompOffset, DirX, DirY, DirZ, Magnitude)
end

--[=[
	Activates rigid-body simulation on an unanchored ECS entity with launch velocity and angular spin.
	@param EntityId number -- 1-based ECS entity identifier.
	@param Angle (Vector3 | number)? -- Launch direction vector or horizontal yaw angle in degrees.
	@param Impulse number? -- Launch impulse scalar.
	@param Speed number? -- Direct launch speed scalar.
	@param CustomMass number? -- Optional explicit mass override.
	@param ECSSizeBuffer buffer? -- Active ECS Size buffer.
	@param ECSPropertiesBuffer buffer? -- Active ECS Properties buffer.
	@return boolean -- True when simulation started, false if out-of-range or anchored.
]=]
function PhysicsInstanceManager.StartSimulatingEntity(
	EntityId: number,
	Angle: (Vector3 | number)?,
	Impulse: number?,
	Speed: number?,
	CustomMass: number?,
	ECSSizeBuffer: buffer?,
	ECSPropertiesBuffer: buffer?
): boolean
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return false
	end

	const FlagIndex = EntityId - 1 :: number
	if ECSPropertiesBuffer and bit32.btest(buffer.readu32(ECSPropertiesBuffer, FlagIndex * 4), FLAG_ANCHORED) then
		return false
	end

	const InverseMass = PhysicsControllerHelper.EnsureDynamicEntityMass(
		EntityId, PhysicsAwakeState.ObjectInvMassBuffer, ECSSizeBuffer, ECSPropertiesBuffer, CustomMass
	) :: number
	const DirX: number, DirY: number, DirZ: number = PhysicsControllerHelper.ResolveLaunchDirection(Angle)
	const TotalLaunchSpeed = (if Speed ~= nil then Speed else DEFAULT_OBJECT_SPEED)
		+ (if Impulse ~= nil then Impulse else DEFAULT_OBJECT_IMPULSE) * InverseMass :: number
	const VelX: number, VelY: number, VelZ: number = DirX * TotalLaunchSpeed, DirY * TotalLaunchSpeed, DirZ * TotalLaunchSpeed
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number

	buffer.writeu8(PhysicsAwakeState.DynamicFlags, FlagIndex, 1)
	PhysicsAwakeState.AddAwakeEntity(EntityId)
	buffer.writef32(PhysicsAwakeState.ObjectVelocityBuffer, CompOffset, VelX)
	buffer.writef32(PhysicsAwakeState.ObjectVelocityBuffer, CompOffset + 4, VelY)
	buffer.writef32(PhysicsAwakeState.ObjectVelocityBuffer, CompOffset + 8, VelZ)

	local Radius = 1.0 :: number
	if ECSSizeBuffer then
		const SizeSum = buffer.readf32(ECSSizeBuffer, CompOffset)
			+ buffer.readf32(ECSSizeBuffer, CompOffset + 4)
			+ buffer.readf32(ECSSizeBuffer, CompOffset + 8) :: number
		Radius = math.max(0.25, SizeSum / 6)
	end
	buffer.writef32(PhysicsAwakeState.ObjectAngularVelocityBuffer, CompOffset, VelZ / Radius)
	buffer.writef32(PhysicsAwakeState.ObjectAngularVelocityBuffer, CompOffset + 4, 0)
	buffer.writef32(PhysicsAwakeState.ObjectAngularVelocityBuffer, CompOffset + 8, -VelX / Radius)
	return true
end

--[=[
	Halts simulation for an ECS entity and zeroes its dynamic physics slots.
	@param EntityId number -- 1-based ECS entity identifier.
]=]
function PhysicsInstanceManager.StopSimulatingEntity(EntityId: number)
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end
	PhysicsAwakeState.RemoveAwakeEntity(EntityId)
	PhysicsAwakeState.ClearEntityPhysicsSlots(EntityId)
end

--[=[
	Steps all currently awake dynamic ECS entities by one physics substep and compacts newly sleeping slots.
	@param EntityCount number -- Current ECS entity count bound.
	@param StepDeltaTime number -- Delta time for single physics substep.
	@param PositionBuffer buffer -- ECS Position buffer.
	@param SizeBuffer buffer -- ECS Size buffer.
	@param DirectionsBuffer buffer -- ECS Directions buffer.
	@param ActiveFlags buffer? -- Optional ECS active flags buffer.
	@param ECSDataModule any -- ECS data component interface.
]=]
function PhysicsInstanceManager.StepAwakeEntitiesSubstep(
	EntityCount: number,
	StepDeltaTime: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	ActiveFlags: buffer?,
	ECSDataModule: any
)
	const DynamicFlags = PhysicsAwakeState.DynamicFlags
	const AwakeBuf = PhysicsAwakeState.AwakeEntitiesBuffer
	local AwakeIndex = 0 :: number
	while AwakeIndex < PhysicsAwakeState.GetAwakeCount() do
		const EntityId = buffer.readu32(AwakeBuf, AwakeIndex * 4) :: number
		if
			EntityId < 1
			or EntityId > EntityCount
			or (ActiveFlags ~= nil and buffer.readu8(ActiveFlags, EntityId - 1) == 0)
			or buffer.readu8(DynamicFlags, EntityId - 1) ~= 1
		then
			PhysicsAwakeState.RemoveAwakeEntity(EntityId)
			if EntityId >= 1 and EntityId <= MAX_ENTITIES and ActiveFlags ~= nil and buffer.readu8(ActiveFlags, EntityId - 1) == 0 then
				PhysicsAwakeState.ClearEntityPhysicsSlots(EntityId)
			end
			continue
		end

		PhysicsControllerHelper.StepSingleDynamicObject(
			EntityId, EntityCount, StepDeltaTime, PositionBuffer, SizeBuffer, DirectionsBuffer, nil,
			DynamicFlags, PhysicsAwakeState.ObjectGroundedFlags, PhysicsAwakeState.ObjectVelocityBuffer,
			PhysicsAwakeState.ObjectAngularVelocityBuffer, PhysicsAwakeState.ObjectForceBuffer, PhysicsAwakeState.ObjectInvMassBuffer
		)
		ECSDataModule.MarkDirty(EntityId)

		if buffer.readu8(DynamicFlags, EntityId - 1) ~= 1 then
			PhysicsAwakeState.RemoveAwakeEntity(EntityId)
		else
			AwakeIndex += 1
		end
	end
end

return PhysicsInstanceManager
