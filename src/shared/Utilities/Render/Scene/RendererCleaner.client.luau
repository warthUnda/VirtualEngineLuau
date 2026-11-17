--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const SelfActor = script:GetActor() :: Actor?
const ObjectStorageModule = (SelfActor and SelfActor:WaitForChild("ObjectStorage"))
	or LocalPlayer:WaitForChild("PlayerScripts")
		:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const ObjectStorage = (require :: any)(ObjectStorageModule) :: ECSMain.ECSStorage
const ObjectECSData = ObjectStorage.ECSData
const ObjectPositionData = ObjectStorage.PositionData
const ObjectOrientationData = ObjectStorage.OrientationData
const ObjectVisualData = ObjectStorage.VisualData
const ObjectSizeData = ObjectStorage.SizeData
const ObjectDirectionsData = ObjectStorage.DirectionsData
const ObjectPropertiesData = ObjectStorage.PropertiesData

const RenderECSStorage = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("ECSStorage")
)
const RenderECSData = RenderECSStorage.ECSData
const RenderPositionData = RenderECSStorage.PositionData
const RenderOrientationData = RenderECSStorage.OrientationData
const RenderVisualData = RenderECSStorage.VisualData
const RenderSizeData = RenderECSStorage.SizeData
const RenderDirectionsData = RenderECSStorage.DirectionsData
const RenderPropertiesData = RenderECSStorage.PropertiesData

const ViewCulling = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Core")
		:WaitForChild("ViewCulling")
)

const CleanerHelper = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Scene")
		:WaitForChild("CleanerHelper")
)

const PhysicsController = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Physics")
		:WaitForChild("Controller")
		:WaitForChild("PhysicsController")
)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const CLEANER_TICK_INTERVAL = SystemsConfigs.CleanerTickInterval :: number

-- Buffers
const ObjectPositions = ObjectPositionData.GetData() :: buffer
const ObjectVisuals = ObjectVisualData.GetData() :: buffer
const ObjectSizes = ObjectSizeData.GetData() :: buffer
const ObjectDirections = ObjectDirectionsData.GetData() :: buffer
const ObjectProperties = ObjectPropertiesData.GetData() :: buffer
const ObjectDirtyFlags = ObjectECSData.GetDirtyFlags() :: buffer
const ObjectCounts = ObjectECSData.ECSDataTable

const RenderPositions = RenderPositionData.GetData() :: buffer
const RenderVisuals = RenderVisualData.GetData() :: buffer
const RenderSizes = RenderSizeData.GetData() :: buffer
const RenderDirections = RenderDirectionsData.GetData() :: buffer
const RenderProperties = RenderPropertiesData.GetData() :: buffer
const RenderCounts = RenderECSData.ECSDataTable

const MAX_ENTITIES = buffer.len(ObjectPositions) // COMPONENT_STRIDE :: number
const RenderSlotByObjectId = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
const ObjectIdByRenderSlot = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
local PreviousObjectCount = 0 :: number

-- ============================================================================
-- 1. CLEANER LOOP - POPULATES & CULLS RENDER ECS STORAGE FROM OBJECT STORAGE
-- ============================================================================

while true do
	const ObjectEntityCount = math.min(ObjectCounts.EntityECSCount, MAX_ENTITIES) :: number

	if ObjectEntityCount < PreviousObjectCount then
		for StaleId = ObjectEntityCount + 1, PreviousObjectCount do
			const StaleSlot = buffer.readu32(RenderSlotByObjectId, StaleId * 4) :: number
			if StaleSlot > 0 then
				CleanerHelper.RemoveRenderEntity(
					RenderECSData,
					RenderCounts,
					RenderSlotByObjectId,
					ObjectIdByRenderSlot,
					StaleId,
					StaleSlot
				)
			end
		end
	end
	PreviousObjectCount = ObjectEntityCount

	if ObjectEntityCount > 0 then
		ViewCulling.UpdateClientView(PhysicsController.GetPlayerPosition())
		ViewCulling.PrepassDominantOccluder(ObjectEntityCount, ObjectPositions, ObjectSizes, ObjectProperties)

		for i = 1, ObjectEntityCount do
			const ObjectSlotOffset = i * 4 :: number
			const SourcePropOffset = (i - 1) * PROPERTIES_STRIDE :: number
			local RenderSlot = buffer.readu32(RenderSlotByObjectId, ObjectSlotOffset) :: number
			const PropReg = buffer.readu32(ObjectProperties, SourcePropOffset) :: number

			if
				not ECSMain.IsEntityVisible(PropReg)
				or ViewCulling.IsEntityCulled(i, ObjectPositions, ObjectSizes)
			then
				if RenderSlot > 0 then
					CleanerHelper.RemoveRenderEntity(
						RenderECSData,
						RenderCounts,
						RenderSlotByObjectId,
						ObjectIdByRenderSlot,
						i,
						RenderSlot
					)
				end
				continue
			end

			const IsNewSlot = RenderSlot == 0 :: boolean
			if IsNewSlot then
				RenderSlot = RenderECSData.RegisterEntity()
				buffer.writeu32(RenderSlotByObjectId, ObjectSlotOffset, RenderSlot)
				buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, i)
			end

			if IsNewSlot or buffer.readu8(ObjectDirtyFlags, i - 1) ~= 0 then
				const SourceOffset = (i - 1) * COMPONENT_STRIDE :: number
				const SourceDirOffset = (i - 1) * DIRECTION_STRIDE :: number
				const SourceVisOffset = (i - 1) * VISUAL_STRIDE :: number
				const TargetOffset = (RenderSlot - 1) * COMPONENT_STRIDE :: number
				const TargetDirOffset = (RenderSlot - 1) * DIRECTION_STRIDE :: number
				const TargetVisOffset = (RenderSlot - 1) * VISUAL_STRIDE :: number
				const TargetPropOffset = (RenderSlot - 1) * PROPERTIES_STRIDE :: number

				buffer.copy(RenderPositions, TargetOffset, ObjectPositions, SourceOffset, COMPONENT_STRIDE)
				buffer.copy(RenderVisuals, TargetVisOffset, ObjectVisuals, SourceVisOffset, VISUAL_STRIDE)
				buffer.copy(RenderSizes, TargetOffset, ObjectSizes, SourceOffset, COMPONENT_STRIDE)
				buffer.copy(RenderDirections, TargetDirOffset, ObjectDirections, SourceDirOffset, DIRECTION_STRIDE)
				buffer.copy(RenderProperties, TargetPropOffset, ObjectProperties, SourcePropOffset, PROPERTIES_STRIDE)
				ObjectECSData.ClearDirty(i)
			end
		end
	end

	task.wait(CLEANER_TICK_INTERVAL)
end
