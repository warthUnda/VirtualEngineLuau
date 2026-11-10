--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const SelfActor = script:GetActor() :: Actor?
const ObjectStorage = (SelfActor and SelfActor:WaitForChild("ObjectStorage"))
	or LocalPlayer:WaitForChild("PlayerScripts")
		:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage") :: Folder

const RenderECSStorage = ReplicatedStorage:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Render")
	:WaitForChild("ECSStorage") :: Folder

-- Modules --
const ObjectECSData = require(ObjectStorage:WaitForChild("ECSData")) :: ModuleScript
const ObjectPositionData = require(ObjectStorage:WaitForChild("PositionData")) :: ModuleScript
const ObjectOrientationData = require(ObjectStorage:WaitForChild("OrientationData")) :: ModuleScript
const ObjectVisualData = require(ObjectStorage:WaitForChild("VisualData")) :: ModuleScript
const ObjectSizeData = require(ObjectStorage:WaitForChild("SizeData")) :: ModuleScript
const ObjectDirectionsData = require(ObjectStorage:WaitForChild("DirectionsData")) :: ModuleScript

const RenderECSData = require(RenderECSStorage:WaitForChild("ECSData")) :: ModuleScript
const RenderPositionData = require(RenderECSStorage:WaitForChild("PositionData")) :: ModuleScript
const RenderOrientationData = require(RenderECSStorage:WaitForChild("OrientationData")) :: ModuleScript
const RenderVisualData = require(RenderECSStorage:WaitForChild("VisualData")) :: ModuleScript
const RenderSizeData = require(RenderECSStorage:WaitForChild("SizeData")) :: ModuleScript
const RenderDirectionsData = require(RenderECSStorage:WaitForChild("DirectionsData")) :: ModuleScript

const ViewCulling = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Core")
		:WaitForChild("ViewCulling")
) :: ModuleScript

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
