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

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const CLEANER_TICK_INTERVAL = SystemsConfigs.CleanerTickInterval :: number

-- Buffers
const ObjectPositions = ObjectPositionData.GetData() :: buffer
const ObjectOrientations = ObjectOrientationData.GetData() :: buffer
const ObjectVisuals = ObjectVisualData.GetData() :: buffer
const ObjectSizes = ObjectSizeData.GetData() :: buffer
const ObjectDirections = ObjectDirectionsData.GetData() :: buffer
const ObjectCounts = ObjectECSData.ECSDataTable

const RenderPositions = RenderPositionData.GetData() :: buffer
const RenderOrientations = RenderOrientationData.GetData() :: buffer
const RenderVisuals = RenderVisualData.GetData() :: buffer
const RenderSizes = RenderSizeData.GetData() :: buffer
const RenderDirections = RenderDirectionsData.GetData() :: buffer
const RenderCounts = RenderECSData.ECSDataTable

const MAX_ENTITIES = buffer.len(ObjectPositions) // COMPONENT_STRIDE :: number
const RenderSlotByObjectId = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
const ObjectIdByRenderSlot = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer

-- ============================================================================
-- 1. CLEANER LOOP - POPULATES & CULLS RENDER ECS STORAGE FROM OBJECT STORAGE
-- ============================================================================

while true do
	const Head = ViewCulling.GetObserverHead(LocalPlayer) :: BasePart?
	const ObjectEntityCount = math.min(ObjectCounts.EntityECSCount, MAX_ENTITIES) :: number

	if Head and ObjectEntityCount > 0 then
		ViewCulling.UpdateDynamicView(Head)

		for i = 1, ObjectEntityCount do
			const ObjectSlotOffset = i * 4 :: number
			local RenderSlot = buffer.readu32(RenderSlotByObjectId, ObjectSlotOffset) :: number

			if ViewCulling.IsEntityCulled(i, ObjectPositions, ObjectSizes) then
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

			if RenderSlot == 0 then
				RenderSlot = RenderECSData.RegisterEntity()
				buffer.writeu32(RenderSlotByObjectId, ObjectSlotOffset, RenderSlot)
				buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, i)
			end

			const SourceOffset = (i - 1) * COMPONENT_STRIDE :: number
			const SourceDirOffset = (i - 1) * DIRECTION_STRIDE :: number
			const TargetOffset = (RenderSlot - 1) * COMPONENT_STRIDE :: number
			const TargetDirOffset = (RenderSlot - 1) * DIRECTION_STRIDE :: number

			buffer.copy(RenderPositions, TargetOffset, ObjectPositions, SourceOffset, COMPONENT_STRIDE)
			buffer.copy(RenderOrientations, TargetOffset, ObjectOrientations, SourceOffset, COMPONENT_STRIDE)
			buffer.copy(RenderVisuals, TargetOffset, ObjectVisuals, SourceOffset, COMPONENT_STRIDE)
			buffer.copy(RenderSizes, TargetOffset, ObjectSizes, SourceOffset, COMPONENT_STRIDE)
			buffer.copy(RenderDirections, TargetDirOffset, ObjectDirections, SourceDirOffset, DIRECTION_STRIDE)
		end
	end

	task.wait(CLEANER_TICK_INTERVAL)
end
