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

-- Modules --
const ObjectStorage = require(SelfActor:WaitForChild("ObjectStorage"))
const ECSData = ObjectStorage.ECSData
const PositionData = ObjectStorage.PositionData
const OrientationData = ObjectStorage.OrientationData
const VisualData = ObjectStorage.VisualData
const SizeData = ObjectStorage.SizeData
const DirectionsData = ObjectStorage.DirectionsData

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

const ClientSlotByServerId = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

-- ============================================================================
-- 1. LISTENER - MERGES REPLICATED DELTAS INTO THE LOCAL ECS
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
		const DeltaCount = math.min(ECSDataTable.EntityECSCount, MAX_ENTITIES) :: number
		if DeltaCount <= 0 then
			return
		end

		local LocalCount = math.min(ECSData.GetCounts().EntityECSCount, MAX_ENTITIES) :: number

		for i = 1, DeltaCount do
			const ReadOffset = (i - 1) * COMPONENT_STRIDE :: number
			const DirectionReadOffset = (i - 1) * DIRECTION_STRIDE :: number

			const ServerId = buffer.readu32(VisualBuffer, ReadOffset + 4) :: number
			local TargetSlot = if ServerId > 0 and ServerId <= MAX_ENTITIES
				then buffer.readu32(ClientSlotByServerId, ServerId * 4)
				else 0

			if TargetSlot == 0 then
				if LocalCount >= MAX_ENTITIES then
					continue
				end

				LocalCount = ECSData.RegisterEntity()
				TargetSlot = LocalCount

				if ServerId > 0 and ServerId <= MAX_ENTITIES then
					buffer.writeu32(ClientSlotByServerId, ServerId * 4, TargetSlot)
				end
			end

			const WriteOffset = (TargetSlot - 1) * COMPONENT_STRIDE :: number
			const DirectionWriteOffset = (TargetSlot - 1) * DIRECTION_STRIDE :: number

			buffer.copy(LocalPositionBuffer, WriteOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
			buffer.copy(LocalOrientationBuffer, WriteOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
			buffer.copy(LocalVisualBuffer, WriteOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
			buffer.copy(LocalSizeBuffer, WriteOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
			buffer.copy(LocalDirectionsBuffer, DirectionWriteOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)
		end
	end
)
