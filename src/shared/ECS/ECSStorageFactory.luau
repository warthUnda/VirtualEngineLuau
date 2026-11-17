--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const DynamicObjectsMain = require(SharedFolder:WaitForChild("DynamicObjectsMain"))
const ECSTypes = require(script.Parent.ECSTypes)
const ECSBitfield = require(script.Parent.ECSBitfield)
const ECSComponents = require(script.Parent.ECSComponents)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number

-- Tables --
local ECSStorageFactory = {}

-- Functions --
-- ============================================================================
-- 1. UNIFIED FREE-LIST ECS STORAGE CONTAINER FACTORY
-- ============================================================================

--[=[
	Constructs a complete, unified ECS storage container with contiguous component streams and a flat free-list allocator.
	@param IncludeStaticBuffer boolean? -- Whether to allocate a static geometry marker buffer.
	@return ECSTypes.ECSStorage -- Fully initialized ECS storage structure.
]=]
function ECSStorageFactory.CreateStorage(IncludeStaticBuffer: boolean?): ECSTypes.ECSStorage
	const PositionData = ECSComponents.CreateVector3Component()
	const VisualData = ECSComponents.CreateVisualComponent()
	const SizeData = ECSComponents.CreateVector3Component()
	const DirectionsData = ECSComponents.CreateDirectionsComponent()
	const PropertiesData = ECSComponents.CreatePropertiesComponent() :: ECSTypes.PropertiesComponent

	const DirectionsBuffer = DirectionsData.GetData() :: buffer
	const PropertiesBuffer = PropertiesData.GetData() :: buffer
	const ActiveFlags = buffer.create(MAX_ENTITIES) :: buffer
	const FreeSlotsBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
	const StaticBuffer = if IncludeStaticBuffer then buffer.create(MAX_ENTITIES) else nil :: buffer?
	const DirtyFlags = buffer.create(MAX_ENTITIES) :: buffer
	const VersionBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
	local FreeSlotTop = 0 :: number

	const OrientationData: ECSTypes.Vector3Component = {
		CreateLayout = function(MemoryOffset: number, X: number, Y: number, Z: number): number
			const DirOffset = (MemoryOffset // COMPONENT_STRIDE) * DIRECTION_STRIDE :: number
			buffer.writef32(DirectionsBuffer, DirOffset, X)
			buffer.writef32(DirectionsBuffer, DirOffset + 4, Y)
			buffer.writef32(DirectionsBuffer, DirOffset + 8, Z)
			return MemoryOffset + COMPONENT_STRIDE
		end,
		GetData = function(): buffer
			return DirectionsBuffer
		end,
	}

	const ECSDataTable: ECSTypes.ECSTable = {
		OrientationECSCount = 0,
		PositionECSCount = 0,
		VisualECSCount = 0,
		SizeECSCount = 0,
		DirectionsECSCount = 0,
		PropertiesECSCount = 0,
		EntityECSCount = 0,
		ActiveEntityCount = 0,
	}

	const DynamicObjectsList = DynamicObjectsMain.CreateComponent(PropertiesBuffer)
	local ECSData = {}
	ECSData.ECSDataTable = ECSDataTable

	function ECSData.GetCounts(): ECSTypes.ECSTable
		return ECSDataTable
	end

	function ECSData.GetActiveFlags(): buffer
		return ActiveFlags
	end

	function ECSData.IsEntityActive(EntityId: number): boolean
		return EntityId >= 1
			and EntityId <= ECSDataTable.EntityECSCount
			and buffer.readu8(ActiveFlags, EntityId - 1) == 1
	end

	function ECSData.GetStaticData(): buffer
		return StaticBuffer :: buffer
	end

	function ECSData.GetDirtyFlags(): buffer
		return DirtyFlags
	end

	function ECSData.GetVersionBuffer(): buffer
		return VersionBuffer
	end

	function ECSData.MarkDirty(EntityId: number)
		if EntityId < 1 or EntityId > MAX_ENTITIES then
			return
		end
		if buffer.readu8(DirtyFlags, EntityId - 1) == 0 then
			buffer.writeu8(DirtyFlags, EntityId - 1, 1)
		end
		const VersionOffset = (EntityId - 1) * 4 :: number
		buffer.writeu32(VersionBuffer, VersionOffset, buffer.readu32(VersionBuffer, VersionOffset) + 1)
	end

	function ECSData.ClearDirty(EntityId: number)
		if EntityId < 1 or EntityId > MAX_ENTITIES then
			return
		end
		buffer.writeu8(DirtyFlags, EntityId - 1, 0)
	end

	function ECSData.RegisterEntity(IsStatic: boolean?): number
		local NewId: number
		NewId, FreeSlotTop = ECSComponents.RegisterEntity(
			ECSDataTable, ActiveFlags, FreeSlotsBuffer, FreeSlotTop, StaticBuffer, IsStatic
		)
		if NewId > 0 then
			buffer.writeu8(DirtyFlags, NewId - 1, 2)
			const VersionOffset = (NewId - 1) * 4 :: number
			buffer.writeu32(VersionBuffer, VersionOffset, buffer.readu32(VersionBuffer, VersionOffset) + 1)
		end
		return NewId
	end

	function ECSData.SetEntityCount(EntityCount: number)
		ECSComponents.SetEntityCount(ECSDataTable, EntityCount)
		ECSDataTable.ActiveEntityCount = EntityCount
		FreeSlotTop = 0
		buffer.fill(ActiveFlags, 0, 1, math.clamp(EntityCount, 0, MAX_ENTITIES))
		if EntityCount < MAX_ENTITIES then
			buffer.fill(ActiveFlags, math.max(0, EntityCount), 0, MAX_ENTITIES - math.max(0, EntityCount))
		end
	end

	function ECSData.DeleteEntity(EntityId: number)
		if EntityId < 1 or EntityId > ECSDataTable.EntityECSCount or buffer.readu8(ActiveFlags, EntityId - 1) == 0 then
			return
		end

		const DeletedProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		const DeletedDynId = ECSBitfield.GetEntityDynamicId(DeletedProp) :: number
		if DeletedDynId > 0 then
			DynamicObjectsList.RemoveObject(DeletedDynId)
		end

		buffer.writeu8(DirtyFlags, EntityId - 1, 0)
		const VersionOffset = (EntityId - 1) * 4 :: number
		buffer.writeu32(VersionBuffer, VersionOffset, buffer.readu32(VersionBuffer, VersionOffset) + 1)

		FreeSlotTop = ECSComponents.DeleteEntity(
			EntityId, ECSDataTable, ActiveFlags, FreeSlotsBuffer, FreeSlotTop, StaticBuffer, PropertiesBuffer
		)
	end

	return {
		PositionData = PositionData,
		OrientationData = OrientationData,
		VisualData = VisualData,
		SizeData = SizeData,
		DirectionsData = DirectionsData,
		PropertiesData = PropertiesData,
		ECSData = ECSData,
		DynamicObjectsList = DynamicObjectsList,
	}
end

return ECSStorageFactory
