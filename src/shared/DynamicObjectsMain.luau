--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

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
	const FreeCount = #FreeIds :: number

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

function DynamicObjectsMain.GetObject(ObjectsTable: { [number]: any }, DynamicId: number): any
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return nil
	end

	return ObjectsTable[DynamicId]
end

function DynamicObjectsMain.GetObjectFromRegister(ObjectsTable: { [number]: any }, Register: number): any
	const DynamicId = ECSMain.GetEntityDynamicId(Register) :: number
	if DynamicId <= 0 then
		return nil
	end

	return ObjectsTable[DynamicId]
end

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

function DynamicObjectsMain.GetBoundEntityId(EntityIdByDynamicId: buffer, DynamicId: number): number
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return 0
	end

	return buffer.readu32(EntityIdByDynamicId, DynamicId * 4)
end

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
