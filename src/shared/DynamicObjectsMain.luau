--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

-- Configs --
const MAX_DYNAMIC_OBJECTS = SystemsConfigs.DynamicObjectsMaxCount :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

export type DynamicListCounts = {
	ActiveCount: number,
	NextId: number,
}

local DynamicObjectsMain = {}

-- ============================================================================
-- 1. DYNAMIC OOP / OBJECTS LIST OPERATIONS
-- ============================================================================

--[=[
	Registers an OOP dynamic object instance and optionally binds it to an ECS entity ID.
	@param ObjectsTable { [number]: any } -- Hash map storing active dynamic objects by ID.
	@param FreeIds { number } -- Stack of recycled dynamic IDs.
	@param Counts DynamicListCounts -- State tracking active and high-water IDs.
	@param EntityIdByDynamicId buffer -- Mapping buffer from DynamicId to EntityId.
	@param ObjectInstance any -- OOP object reference or user data.
	@param EntityId number? -- Optional ECS entity ID to link.
	@param PropertiesBuffer buffer? -- Optional properties buffer to stamp with dynamic ID.
	@return number -- Allocated dynamic ID (or 0 if capacity exceeded).
]=]
function DynamicObjectsMain.AddObject(
	ObjectsTable: { [number]: any },
	FreeIds: { number },
	Counts: DynamicListCounts,
	EntityIdByDynamicId: buffer,
	ObjectInstance: any,
	EntityId: number?,
	PropertiesBuffer: buffer?
): number
	local DynamicId = 0 :: number
	const FreeCount = (#FreeIds) :: number

	if FreeCount > 0 then
		DynamicId = FreeIds[FreeCount]
		FreeIds[FreeCount] = nil
	else
		const CandidateId = Counts.NextId + 1 :: number
		if CandidateId > MAX_DYNAMIC_OBJECTS then
			return 0
		end
		Counts.NextId = CandidateId
		DynamicId = CandidateId
	end

	ObjectsTable[DynamicId] = ObjectInstance
	Counts.ActiveCount += 1

	if EntityId and EntityId > 0 then
		buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
		if PropertiesBuffer then
			ECSMain.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
		end
	end

	return DynamicId
end

--[=[
	Retrieves an OOP object instance by its allocated dynamic ID.
	@param ObjectsTable { [number]: any } -- Dynamic objects hash map.
	@param DynamicId number -- Target dynamic object ID.
	@return any -- Stored OOP object (or nil).
]=]
function DynamicObjectsMain.GetObject(ObjectsTable: { [number]: any }, DynamicId: number): any
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return nil
	end

	return ObjectsTable[DynamicId]
end

--[=[
	Retrieves an OOP object instance directly from an entity's 32-bit property register.
	@param ObjectsTable { [number]: any } -- Dynamic objects hash map.
	@param Register number -- 32-bit property register containing packed dynamic ID.
	@return any -- Stored OOP object (or nil).
]=]
function DynamicObjectsMain.GetObjectFromRegister(ObjectsTable: { [number]: any }, Register: number): any
	const DynamicId = ECSMain.GetEntityDynamicId(Register) :: number
	if DynamicId <= 0 then
		return nil
	end

	return ObjectsTable[DynamicId]
end

--[=[
	Retrieves an OOP object instance bound to an ECS entity ID.
	@param ObjectsTable { [number]: any } -- Dynamic objects hash map.
	@param PropertiesBuffer buffer -- Entity properties buffer.
	@param EntityId number -- Target ECS entity ID.
	@return any -- Stored OOP object (or nil).
]=]
function DynamicObjectsMain.GetObjectByEntityId(
	ObjectsTable: { [number]: any },
	PropertiesBuffer: buffer,
	EntityId: number
): any
	if EntityId < 1 then
		return nil
	end

	const Register = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
	const DynamicId = ECSMain.GetEntityDynamicId(Register) :: number
	if DynamicId <= 0 then
		return nil
	end

	return ObjectsTable[DynamicId]
end

--[=[
	Binds a dynamic OOP object to an ECS entity ID bi-directionally.
	@param EntityIdByDynamicId buffer -- Mapping buffer from DynamicId to EntityId.
	@param PropertiesBuffer buffer -- Properties buffer storing entity flags and dynamic ID.
	@param DynamicId number -- Target dynamic ID.
	@param EntityId number -- Target ECS entity ID.
]=]
function DynamicObjectsMain.BindEntity(
	EntityIdByDynamicId: buffer,
	PropertiesBuffer: buffer,
	DynamicId: number,
	EntityId: number
)
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS or EntityId < 1 then
		return
	end

	buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
	ECSMain.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
end

--[=[
	Returns the ECS entity ID bound to a dynamic OOP object.
	@param EntityIdByDynamicId buffer -- Mapping buffer from DynamicId to EntityId.
	@param DynamicId number -- Target dynamic ID.
	@return number -- Bound ECS entity ID (or 0 if unbound).
]=]
function DynamicObjectsMain.GetBoundEntityId(EntityIdByDynamicId: buffer, DynamicId: number): number
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return 0
	end

	return buffer.readu32(EntityIdByDynamicId, DynamicId * 4)
end

--[=[
	Unregisters an OOP dynamic object and unlinks its bound entity ID.
	@param ObjectsTable { [number]: any } -- Dynamic objects hash map.
	@param FreeIds { number } -- Recycled dynamic ID stack.
	@param Counts DynamicListCounts -- State tracking active count.
	@param EntityIdByDynamicId buffer -- Mapping buffer from DynamicId to EntityId.
	@param DynamicId number -- Dynamic ID to remove.
	@param PropertiesBuffer buffer? -- Optional properties buffer to clear dynamic ID from entity.
]=]
function DynamicObjectsMain.RemoveObject(
	ObjectsTable: { [number]: any },
	FreeIds: { number },
	Counts: DynamicListCounts,
	EntityIdByDynamicId: buffer,
	DynamicId: number,
	PropertiesBuffer: buffer?
)
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return
	end

	if ObjectsTable[DynamicId] == nil then
		return
	end

	const BoundEntityId = buffer.readu32(EntityIdByDynamicId, DynamicId * 4) :: number
	if BoundEntityId > 0 then
		buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, 0)
		if PropertiesBuffer then
			ECSMain.SetEntityDynamicId(PropertiesBuffer, BoundEntityId, 0)
		end
	end

	ObjectsTable[DynamicId] = nil
	Counts.ActiveCount = math.max(0, Counts.ActiveCount - 1)
	table.insert(FreeIds, DynamicId)
end

return DynamicObjectsMain
