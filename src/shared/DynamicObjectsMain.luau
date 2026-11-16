--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ECSFolder = SharedFolder:WaitForChild("ECS")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSTypes = require(ECSFolder:WaitForChild("ECSTypes"))
const ECSBitfield = require(ECSFolder:WaitForChild("ECSBitfield"))

-- Configs --
const MAX_DYNAMIC_OBJECTS = SystemsConfigs.DynamicObjectsMaxCount :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

export type DynamicListCounts = ECSTypes.DynamicListCounts
export type DynamicObjectsComponent = ECSTypes.DynamicObjectsComponent

-- Tables --
local DynamicObjectsMain = {}

-- ============================================================================
-- 1. UNIFIED DYNAMIC OOP / OBJECTS REGISTRY & COMPONENT FACTORY
-- ============================================================================

--[=[
	Registers an OOP dynamic object instance and optionally binds it to an ECS entity ID.
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
			ECSBitfield.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
		end
	end
	return DynamicId
end

--[=[
	Stores an OOP object instance at an explicit replicated DynamicId and optionally links an ECS entity ID.
]=]
function DynamicObjectsMain.SetObjectAtId(
	ObjectsTable: { [number]: any },
	FreeIds: { number },
	Counts: DynamicListCounts,
	EntityIdByDynamicId: buffer,
	DynamicId: number,
	ObjectInstance: any,
	EntityId: number?,
	PropertiesBuffer: buffer?
): boolean
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS or ObjectInstance == nil then
		return false
	end

	const FreeIndex = table.find(FreeIds, DynamicId)
	if FreeIndex then
		table.remove(FreeIds, FreeIndex)
	end
	if ObjectsTable[DynamicId] == nil then
		Counts.ActiveCount += 1
	end
	if DynamicId > Counts.NextId then
		Counts.NextId = DynamicId
	end
	ObjectsTable[DynamicId] = ObjectInstance

	if EntityId and EntityId > 0 then
		buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
		if PropertiesBuffer then
			ECSBitfield.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
		end
	end
	return true
end

function DynamicObjectsMain.GetObject(ObjectsTable: { [number]: any }, DynamicId: number): any
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return nil
	end
	return ObjectsTable[DynamicId]
end

function DynamicObjectsMain.GetObjectFromRegister(ObjectsTable: { [number]: any }, Register: number): any
	const DynamicId = ECSBitfield.GetEntityDynamicId(Register) :: number
	return if DynamicId > 0 then ObjectsTable[DynamicId] else nil
end

function DynamicObjectsMain.GetObjectByEntityId(ObjectsTable: { [number]: any }, PropertiesBuffer: buffer, EntityId: number): any
	if EntityId < 1 then
		return nil
	end
	const Register = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
	const DynamicId = ECSBitfield.GetEntityDynamicId(Register) :: number
	return if DynamicId > 0 then ObjectsTable[DynamicId] else nil
end

function DynamicObjectsMain.BindEntity(EntityIdByDynamicId: buffer, PropertiesBuffer: buffer, DynamicId: number, EntityId: number)
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS or EntityId < 1 then
		return
	end
	buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, EntityId)
	ECSBitfield.SetEntityDynamicId(PropertiesBuffer, EntityId, DynamicId)
end

function DynamicObjectsMain.GetBoundEntityId(EntityIdByDynamicId: buffer, DynamicId: number): number
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS then
		return 0
	end
	return buffer.readu32(EntityIdByDynamicId, DynamicId * 4)
end

--[=[
	Unregisters an OOP dynamic object and clears its bound entity DynamicId if still owned by DynamicId.
]=]
function DynamicObjectsMain.RemoveObject(
	ObjectsTable: { [number]: any },
	FreeIds: { number },
	Counts: DynamicListCounts,
	EntityIdByDynamicId: buffer,
	DynamicId: number,
	PropertiesBuffer: buffer?
)
	if DynamicId <= 0 or DynamicId > MAX_DYNAMIC_OBJECTS or ObjectsTable[DynamicId] == nil then
		return
	end

	const BoundEntityId = buffer.readu32(EntityIdByDynamicId, DynamicId * 4) :: number
	if BoundEntityId > 0 then
		buffer.writeu32(EntityIdByDynamicId, DynamicId * 4, 0)
		if PropertiesBuffer then
			const BoundOffset = (BoundEntityId - 1) * PROPERTIES_STRIDE :: number
			if BoundOffset + PROPERTIES_STRIDE <= buffer.len(PropertiesBuffer) then
				const BoundRegister = buffer.readu32(PropertiesBuffer, BoundOffset) :: number
				if ECSBitfield.GetEntityDynamicId(BoundRegister) == DynamicId then
					ECSBitfield.SetEntityDynamicId(PropertiesBuffer, BoundEntityId, 0)
				end
			end
		end
	end

	ObjectsTable[DynamicId] = nil
	Counts.ActiveCount = math.max(0, Counts.ActiveCount - 1)
	table.insert(FreeIds, DynamicId)
end

--[=[
	Creates an isolated DynamicObjectsComponent bound to PropertiesBuffer using DynamicObjectsMain operations.
	@param PropertiesBuffer buffer -- Entity properties buffer to link IDs into.
	@return DynamicObjectsComponent -- Initialized dynamic objects registry.
]=]
function DynamicObjectsMain.CreateComponent(PropertiesBuffer: buffer): DynamicObjectsComponent
	local ObjectsTable = {} :: { [number]: any }
	local FreeIds = {} :: { number }
	const EntityIdByDynamicId = buffer.create((MAX_DYNAMIC_OBJECTS + 1) * 4) :: buffer
	local Counts: DynamicListCounts = { ActiveCount = 0, NextId = 0 }

	return {
		ObjectsTable = ObjectsTable,
		Counts = Counts,
		AddObject = function(ObjectInstance: any, EntityId: number?): number
			return DynamicObjectsMain.AddObject(ObjectsTable, FreeIds, Counts, EntityIdByDynamicId, ObjectInstance, EntityId, PropertiesBuffer)
		end,
		SetObjectAtId = function(DynamicId: number, ObjectInstance: any, EntityId: number?): boolean
			return DynamicObjectsMain.SetObjectAtId(ObjectsTable, FreeIds, Counts, EntityIdByDynamicId, DynamicId, ObjectInstance, EntityId, PropertiesBuffer)
		end,
		GetObject = function(DynamicId: number): any
			return DynamicObjectsMain.GetObject(ObjectsTable, DynamicId)
		end,
		GetObjectFromRegister = function(Register: number): any
			return DynamicObjectsMain.GetObjectFromRegister(ObjectsTable, Register)
		end,
		GetObjectByEntityId = function(EntityId: number): any
			return DynamicObjectsMain.GetObjectByEntityId(ObjectsTable, PropertiesBuffer, EntityId)
		end,
		BindEntity = function(DynamicId: number, EntityId: number)
			DynamicObjectsMain.BindEntity(EntityIdByDynamicId, PropertiesBuffer, DynamicId, EntityId)
		end,
		GetBoundEntityId = function(DynamicId: number): number
			return DynamicObjectsMain.GetBoundEntityId(EntityIdByDynamicId, DynamicId)
		end,
		RemoveObject = function(DynamicId: number)
			DynamicObjectsMain.RemoveObject(ObjectsTable, FreeIds, Counts, EntityIdByDynamicId, DynamicId, PropertiesBuffer)
		end,
		GetData = function(): { [number]: any }
			return ObjectsTable
		end,
	}
end

return DynamicObjectsMain
