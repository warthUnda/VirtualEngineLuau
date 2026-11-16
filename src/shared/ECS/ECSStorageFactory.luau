--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

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
-- 1. UNIFIED ECS STORAGE CONTAINER FACTORY
-- ============================================================================

--[=[
	Constructs a complete, unified ECS storage container with all component buffers and swap-pop hooks.
	@param IncludeStaticBuffer boolean? -- Whether to allocate a static geometry marker buffer.
	@return ECSTypes.ECSStorage -- Fully initialized ECS storage structure.
]=]
function ECSStorageFactory.CreateStorage(IncludeStaticBuffer: boolean?): ECSTypes.ECSStorage
	const PositionData = ECSComponents.CreateVector3Component()
	const VisualData = ECSComponents.CreateVisualComponent()
	const SizeData = ECSComponents.CreateVector3Component()
	const DirectionsData = ECSComponents.CreateDirectionsComponent()
	const PropertiesData = ECSComponents.CreatePropertiesComponent() :: ECSTypes.PropertiesComponent

	const PositionBuffer = PositionData.GetData() :: buffer
	const VisualBuffer = VisualData.GetData() :: buffer
	const SizeBuffer = SizeData.GetData() :: buffer
	const DirectionsBuffer = DirectionsData.GetData() :: buffer
	const PropertiesBuffer = PropertiesData.GetData() :: buffer
	const StaticBuffer = if IncludeStaticBuffer then buffer.create(MAX_ENTITIES) else nil :: buffer?
	const DirtyFlags = buffer.create(MAX_ENTITIES) :: buffer
	const VersionBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
	const SwapPopCallbacks = {} :: { (DeletedEntityId: number, MovedFromEntityId: number) -> () }

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
	}

	const DynamicObjectsList = DynamicObjectsMain.CreateComponent(PropertiesBuffer)
	local ECSData = {}
	ECSData.ECSDataTable = ECSDataTable

	function ECSData.GetCounts(): ECSTypes.ECSTable
		return ECSDataTable
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
		buffer.writeu8(DirtyFlags, EntityId - 1, 1)
		const VersionOffset = (EntityId - 1) * 4 :: number
		buffer.writeu32(VersionBuffer, VersionOffset, buffer.readu32(VersionBuffer, VersionOffset) + 1)
	end

	function ECSData.ClearDirty(EntityId: number)
		if EntityId < 1 or EntityId > MAX_ENTITIES then
			return
		end
		buffer.writeu8(DirtyFlags, EntityId - 1, 0)
	end

	function ECSData.SetSwapPopCallback(Callback: ((DeletedEntityId: number, MovedFromEntityId: number) -> ())?)
		if not Callback then
			table.clear(SwapPopCallbacks)
			return
		end
		if not table.find(SwapPopCallbacks, Callback) then
			table.insert(SwapPopCallbacks, Callback)
		end
	end

	function ECSData.RegisterEntity(IsStatic: boolean?): number
		const NewId = ECSComponents.RegisterEntity(ECSDataTable, StaticBuffer, IsStatic) :: number
		if NewId > 0 then
			ECSData.MarkDirty(NewId)
		end
		return NewId
	end

	function ECSData.SetEntityCount(EntityCount: number)
		ECSComponents.SetEntityCount(ECSDataTable, EntityCount)
	end

	function ECSData.DeleteEntity(EntityId: number)
		const LastEntityId = ECSDataTable.EntityECSCount :: number
		if EntityId < 1 or EntityId > LastEntityId then
			return
		end

		const DeletedProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		const DeletedDynId = ECSBitfield.GetEntityDynamicId(DeletedProp) :: number
		if DeletedDynId > 0 then
			DynamicObjectsList.RemoveObject(DeletedDynId)
		end

		ECSComponents.DeleteEntity(
			EntityId, ECSDataTable, PositionBuffer, nil, VisualBuffer, SizeBuffer, DirectionsBuffer, StaticBuffer, PropertiesBuffer
		)

		if EntityId ~= LastEntityId then
			const MovedProp = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
			const MovedDynId = ECSBitfield.GetEntityDynamicId(MovedProp) :: number
			if MovedDynId > 0 then
				DynamicObjectsList.BindEntity(MovedDynId, EntityId)
			end
			ECSData.MarkDirty(EntityId)
		end

		buffer.writeu8(DirtyFlags, LastEntityId - 1, 0)
		buffer.writeu32(VersionBuffer, (LastEntityId - 1) * 4, 0)

		for _, Callback in SwapPopCallbacks do
			Callback(EntityId, LastEntityId)
		end
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
