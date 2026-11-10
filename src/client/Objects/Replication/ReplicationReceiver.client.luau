--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
-- The render controller runs inside an Actor, and every Actor owns an isolated Luau VM with its
-- own copy of each required ModuleScript. The receiver therefore has to live in that same Actor,
-- otherwise it fills the PlayerScripts copy of the ECS that nothing ever reads and the controller
-- keeps seeing an entity count of 0. It is cloned into the controller Actor by RenderBootstrap.
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

const CoreEvents = ReplicatedStorage:WaitForChild("CoreEvents") :: Folder
const ReplicateEvent = CoreEvents:WaitForChild("ReplicateEvent") :: RemoteEvent
const ObjectStorage = SelfActor:WaitForChild("ObjectStorage") :: Folder

-- Modules --
const ECSData = require(ObjectStorage:WaitForChild("ECSData")) :: ModuleScript
const PositionData = require(ObjectStorage:WaitForChild("PositionData")) :: ModuleScript
const OrientationData = require(ObjectStorage:WaitForChild("OrientationData")) :: ModuleScript
const VisualData = require(ObjectStorage:WaitForChild("VisualData")) :: ModuleScript
const SizeData = require(ObjectStorage:WaitForChild("SizeData")) :: ModuleScript
const DirectionsData = require(ObjectStorage:WaitForChild("DirectionsData")) :: ModuleScript

-- Configs --
const COMPONENT_STRIDE = 12 :: number -- position, orientation, visual and size store 3 x f32 per entity
const DIRECTION_STRIDE = 36 :: number -- look + up + right, 3 x f32 each

-- Buffers
const LocalPositionBuffer = PositionData.GetData() :: buffer
const LocalOrientationBuffer = OrientationData.GetData() :: buffer
const LocalVisualBuffer = VisualData.GetData() :: buffer
const LocalSizeBuffer = SizeData.GetData() :: buffer
const LocalDirectionsBuffer = DirectionsData.GetData() :: buffer

-- The local ECS buffers have a fixed size, so a snapshot holding more entities than they can store
-- is clamped instead of erroring out on an out of bounds write and dropping every later packet.
const MAX_COMPONENT_ENTITIES = math.min(
	buffer.len(LocalPositionBuffer),
	buffer.len(LocalOrientationBuffer),
	buffer.len(LocalVisualBuffer),
	buffer.len(LocalSizeBuffer)
) // COMPONENT_STRIDE :: number

const MAX_DIRECTION_ENTITIES = buffer.len(LocalDirectionsBuffer) // DIRECTION_STRIDE :: number
const MAX_ENTITIES = math.min(MAX_COMPONENT_ENTITIES, MAX_DIRECTION_ENTITIES) :: number

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

-- ============================================================================
-- 1. LISTENER - WRITES THE REPLICATED SNAPSHOT INTO THE LOCAL ECS
-- ============================================================================

ReplicateEvent.OnClientEvent:Connect(
	function(
		PositionBuffer: buffer,
		OrientationBuffer: buffer,
		VisualBuffer: buffer,
		SizeBuffer: buffer,
		DirectionsBuffer: buffer,
		ECSDataTable: ECSTable
	)
		const EntityCount = math.min(ECSDataTable.EntityECSCount, MAX_ENTITIES) :: number

		-- The packet is a full snapshot of what this client can see, so the local ECS mirrors it.
		ECSData.SetEntityCount(EntityCount)

		if EntityCount > 0 then
			const ComponentByteCount = EntityCount * COMPONENT_STRIDE :: number
			const DirectionByteCount = EntityCount * DIRECTION_STRIDE :: number

			buffer.copy(LocalPositionBuffer, 0, PositionBuffer, 0, ComponentByteCount)
			buffer.copy(LocalOrientationBuffer, 0, OrientationBuffer, 0, ComponentByteCount)
			buffer.copy(LocalVisualBuffer, 0, VisualBuffer, 0, ComponentByteCount)
			buffer.copy(LocalSizeBuffer, 0, SizeBuffer, 0, ComponentByteCount)
			buffer.copy(LocalDirectionsBuffer, 0, DirectionsBuffer, 0, DirectionByteCount)
		end
	end
)
