--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number

-- Variables --
local AwakeEntityCount = 0 :: number
local ActiveForceCount = 0 :: number

-- Buffers
const DynamicFlags = buffer.create(MAX_ENTITIES) :: buffer
const ObjectGroundedFlags = buffer.create(MAX_ENTITIES) :: buffer
const ObjectVelocityBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectAngularVelocityBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectForceBuffer = buffer.create(MAX_ENTITIES * COMPONENT_STRIDE) :: buffer
const ObjectInvMassBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const ActiveForceSlots = buffer.create(MAX_ENTITIES * 4) :: buffer
const AwakeEntitiesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const AwakeEntitySlotBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer

-- Tables --
local PhysicsAwakeState = {
	DynamicFlags = DynamicFlags,
	ObjectGroundedFlags = ObjectGroundedFlags,
	ObjectVelocityBuffer = ObjectVelocityBuffer,
	ObjectAngularVelocityBuffer = ObjectAngularVelocityBuffer,
	ObjectForceBuffer = ObjectForceBuffer,
	ObjectInvMassBuffer = ObjectInvMassBuffer,
	ActiveForceSlots = ActiveForceSlots,
	AwakeEntitiesBuffer = AwakeEntitiesBuffer,
}

-- Functions --
-- ============================================================================
-- 1. DYNAMIC PHYSICS BUFFERS, AWAKE SET & O(1) SWAP-POP COMPACTION
-- ============================================================================

--[=[
	Returns the count of currently awake dynamic entities.
	@return number -- Active awake entity count.
]=]
function PhysicsAwakeState.GetAwakeCount(): number
	return AwakeEntityCount
end

--[=[
	Adds an entity to the active awake set if not already present.
	@param EntityId number -- 1-based entity ID.
]=]
function PhysicsAwakeState.AddAwakeEntity(EntityId: number)
	if EntityId < 1 or EntityId > MAX_ENTITIES or AwakeEntityCount >= MAX_ENTITIES then
		return
	end
	const SlotOffset = (EntityId - 1) * 4 :: number
	if buffer.readu32(AwakeEntitySlotBuffer, SlotOffset) ~= 0 then
		return
	end

	const SlotIndex = AwakeEntityCount :: number
	buffer.writeu32(AwakeEntitiesBuffer, SlotIndex * 4, EntityId)
	AwakeEntityCount = SlotIndex + 1
	buffer.writeu32(AwakeEntitySlotBuffer, SlotOffset, AwakeEntityCount)
end

--[=[
	Removes an entity from the awake set via O(1) swap-and-pop compaction.
	@param EntityId number -- 1-based entity ID.
]=]
function PhysicsAwakeState.RemoveAwakeEntity(EntityId: number)
	if EntityId < 1 or EntityId > MAX_ENTITIES then
		return
	end
	const SlotOffset = (EntityId - 1) * 4 :: number
	const SlotOneBased = buffer.readu32(AwakeEntitySlotBuffer, SlotOffset) :: number
	if SlotOneBased == 0 then
		return
	end

	const SlotIndex = SlotOneBased - 1 :: number
	const LastSlotIndex = AwakeEntityCount - 1 :: number
	if SlotIndex ~= LastSlotIndex then
		const TailEntityId = buffer.readu32(AwakeEntitiesBuffer, LastSlotIndex * 4) :: number
		buffer.writeu32(AwakeEntitiesBuffer, SlotIndex * 4, TailEntityId)
		buffer.writeu32(AwakeEntitySlotBuffer, (TailEntityId - 1) * 4, SlotOneBased)
	end

	buffer.writeu32(AwakeEntitiesBuffer, LastSlotIndex * 4, 0)
	buffer.writeu32(AwakeEntitySlotBuffer, SlotOffset, 0)
	AwakeEntityCount = LastSlotIndex
end

--[=[
	Zeroes all dynamic physics state buffers and registers for a specific entity slot.
	@param EntityId number -- 1-based entity ID.
]=]
function PhysicsAwakeState.ClearEntityPhysicsSlots(EntityId: number)
	const FlagIndex = EntityId - 1 :: number
	const CompOffset = FlagIndex * COMPONENT_STRIDE :: number
	buffer.writeu8(DynamicFlags, FlagIndex, 0)
	buffer.writeu8(ObjectGroundedFlags, FlagIndex, 0)
	buffer.writef32(ObjectInvMassBuffer, FlagIndex * 4, 0)
	buffer.fill(ObjectVelocityBuffer, CompOffset, 0, COMPONENT_STRIDE)
	buffer.fill(ObjectAngularVelocityBuffer, CompOffset, 0, COMPONENT_STRIDE)
	buffer.fill(ObjectForceBuffer, CompOffset, 0, COMPONENT_STRIDE)
end

--[=[
	Accumulates continuous external force on an entity slot and stages it for batch flushing.
	@param CompOffset number -- Byte offset in component buffers ((EntityId - 1) * COMPONENT_STRIDE).
	@param DirX number -- Unit direction X component.
	@param DirY number -- Unit direction Y component.
	@param DirZ number -- Unit direction Z component.
	@param Magnitude number -- Force magnitude.
]=]
function PhysicsAwakeState.AccumulateContinuousForce(CompOffset: number, DirX: number, DirY: number, DirZ: number, Magnitude: number)
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

--[=[
	Zeroes out all staged external force slots accumulated during the frame.
]=]
function PhysicsAwakeState.FlushForces()
	for i = 0, ActiveForceCount - 1 do
		const CompOffset = buffer.readu32(ActiveForceSlots, i * 4) :: number
		buffer.fill(ObjectForceBuffer, CompOffset, 0, COMPONENT_STRIDE)
	end
	ActiveForceCount = 0
end

return PhysicsAwakeState
