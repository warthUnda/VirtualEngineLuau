--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const SelfActor = script:GetActor() :: Actor?
const ObjectStorageModule = (SelfActor and SelfActor:WaitForChild("ObjectStorage"))
	or LocalPlayer:WaitForChild("PlayerScripts")
		:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage")

-- Modules --
const ObjectStorage = require(ObjectStorageModule)
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

-- Configs --
const COMPONENT_STRIDE = 12 :: number
const DIRECTION_STRIDE = 36 :: number

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

local function RemoveRenderEntity(ObjectId: number, RenderSlot: number)
	const LastRenderSlot = RenderCounts.EntityECSCount :: number
	const LastObjectId = buffer.readu32(ObjectIdByRenderSlot, LastRenderSlot * 4) :: number

	RenderECSData.DeleteEntity(RenderSlot)

	if RenderSlot ~= LastRenderSlot and LastObjectId > 0 then
		buffer.writeu32(RenderSlotByObjectId, LastObjectId * 4, RenderSlot)
		buffer.writeu32(ObjectIdByRenderSlot, RenderSlot * 4, LastObjectId)
	end

	buffer.writeu32(RenderSlotByObjectId, ObjectId * 4, 0)
	buffer.writeu32(ObjectIdByRenderSlot, LastRenderSlot * 4, 0)
end

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
					RemoveRenderEntity(i, RenderSlot)
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

	task.wait()
end
