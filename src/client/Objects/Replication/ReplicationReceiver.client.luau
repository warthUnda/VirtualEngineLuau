--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
-- The render controller runs inside an Actor, and every Actor owns an isolated Luau VM with its
-- own copy of each required ModuleScript. The receiver therefore has to live in that same Actor,
-- otherwise it fills the PlayerScripts copy of the ECS that nothing ever reads and the controller
-- keeps seeing an entity count of 0. It is cloned into the controller Actor by RenderBootstrap.
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const ObjectStorage = (require :: any)(SelfActor:WaitForChild("ObjectStorage")) :: ECSMain.ECSStorage

-- table data
const ECSData = ObjectStorage.ECSData
const PositionData = ObjectStorage.PositionData
const VisualData = ObjectStorage.VisualData
const SizeData = ObjectStorage.SizeData
const DirectionsData = ObjectStorage.DirectionsData
const PropertiesData = ObjectStorage.PropertiesData

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const HEADER_BYTES = 8 :: number

-- Remote events
const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
const ReplicateEvent = CoreEvents:WaitForChild(REPLICATE_REMOTE_EVENT_NAME) :: RemoteEvent

-- Buffers
const LocalPositionBuffer = PositionData.GetData() :: buffer
const LocalVisualBuffer = VisualData.GetData() :: buffer
const LocalSizeBuffer = SizeData.GetData() :: buffer
const LocalDirectionsBuffer = DirectionsData.GetData() :: buffer
const LocalPropertiesBuffer = PropertiesData.GetData() :: buffer

-- The local ECS buffers have a fixed size, so a snapshot holding more entities than they can store
-- is clamped instead of erroring out on an out of bounds write and dropping every later packet.
const MAX_COMPONENT_ENTITIES = math.min(
	buffer.len(LocalPositionBuffer),
	buffer.len(LocalSizeBuffer)
) // COMPONENT_STRIDE :: number

const MAX_DIRECTION_ENTITIES = buffer.len(LocalDirectionsBuffer) // DIRECTION_STRIDE :: number
const MAX_VISUAL_ENTITIES = buffer.len(LocalVisualBuffer) // VISUAL_STRIDE :: number
const MAX_ENTITIES = math.min(MAX_COMPONENT_ENTITIES, MAX_DIRECTION_ENTITIES, MAX_VISUAL_ENTITIES) :: number

const ClientSlotByServerId = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
const ServerIdByClientSlot = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
local LastWorldEntityCount = 0 :: number

ECSData.SetSwapPopCallback(function(DeletedSlot: number, LastSlot: number)
	if DeletedSlot ~= LastSlot then
		const MovedServerId = buffer.readu32(ServerIdByClientSlot, LastSlot * 4) :: number
		buffer.writeu32(ServerIdByClientSlot, DeletedSlot * 4, MovedServerId)
		if MovedServerId > 0 and MovedServerId <= MAX_ENTITIES then
			buffer.writeu32(ClientSlotByServerId, MovedServerId * 4, DeletedSlot)
		end
		ECSData.MarkDirty(DeletedSlot)
	end
	buffer.writeu32(ServerIdByClientSlot, LastSlot * 4, 0)
end)

-- ============================================================================
-- 1. LISTENER - MERGES REPLICATED DELTAS INTO THE LOCAL ECS
-- ============================================================================

ReplicateEvent.OnClientEvent:Connect(function(Payload: buffer)
	if typeof(Payload) ~= "buffer" or buffer.len(Payload) < HEADER_BYTES then
		return
	end

	const UpdatedCount = buffer.readu16(Payload, 0) :: number
	const WorldEntityCount = buffer.readu16(Payload, 2) :: number

	if WorldEntityCount < LastWorldEntityCount then
		for ServerId = WorldEntityCount + 1, math.min(LastWorldEntityCount, MAX_ENTITIES) do
			const StaleSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4) :: number
			if StaleSlot > 0 then
				buffer.writeu32(ClientSlotByServerId, ServerId * 4, 0)
				ECSData.DeleteEntity(StaleSlot)
			end
		end
	end
	LastWorldEntityCount = WorldEntityCount

	local ReadOffset = HEADER_BYTES :: number
	const PayloadLen = buffer.len(Payload) :: number

	for _ = 1, UpdatedCount do
		if ReadOffset + 3 > PayloadLen then
			break
		end

		const ServerId = buffer.readu16(Payload, ReadOffset) :: number
		const Mask = buffer.readu8(Payload, ReadOffset + 2) :: number
		ReadOffset += 3

		local TargetSlot = if ServerId > 0 and ServerId <= MAX_ENTITIES
			then buffer.readu32(ClientSlotByServerId, ServerId * 4)
			else 0

		if TargetSlot == 0 then
			if ECSData.GetCounts().EntityECSCount >= MAX_ENTITIES then
				break
			end

			TargetSlot = ECSData.RegisterEntity()
			if TargetSlot <= 0 then
				break
			end

			if ServerId > 0 and ServerId <= MAX_ENTITIES then
				buffer.writeu32(ClientSlotByServerId, ServerId * 4, TargetSlot)
				buffer.writeu32(ServerIdByClientSlot, TargetSlot * 4, ServerId)
			end
		end

		const WriteOffset = (TargetSlot - 1) * COMPONENT_STRIDE :: number
		const DirectionWriteOffset = (TargetSlot - 1) * DIRECTION_STRIDE :: number
		const VisualWriteOffset = (TargetSlot - 1) * VISUAL_STRIDE :: number
		const PropertiesWriteOffset = (TargetSlot - 1) * PROPERTIES_STRIDE :: number

		if bit32.band(Mask, 1) ~= 0 then
			buffer.copy(LocalPositionBuffer, WriteOffset, Payload, ReadOffset, COMPONENT_STRIDE)
			ReadOffset += COMPONENT_STRIDE
		end

		if bit32.band(Mask, 2) ~= 0 then
			buffer.copy(LocalSizeBuffer, WriteOffset, Payload, ReadOffset, COMPONENT_STRIDE)
			ReadOffset += COMPONENT_STRIDE
		end

		if bit32.band(Mask, 4) ~= 0 then
			const LookX = buffer.readf32(Payload, ReadOffset) :: number
			const LookY = buffer.readf32(Payload, ReadOffset + 4) :: number
			const LookZ = buffer.readf32(Payload, ReadOffset + 8) :: number
			const UpX = buffer.readf32(Payload, ReadOffset + 12) :: number
			const UpY = buffer.readf32(Payload, ReadOffset + 16) :: number
			const UpZ = buffer.readf32(Payload, ReadOffset + 20) :: number
			ReadOffset += 24

			const RightX = LookY * UpZ - LookZ * UpY :: number
			const RightY = LookZ * UpX - LookX * UpZ :: number
			const RightZ = LookX * UpY - LookY * UpX :: number

			-- Directions layout: Look (0..11), Up (12..23), Right (24..35)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset, LookX)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 4, LookY)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 8, LookZ)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 12, UpX)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 16, UpY)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 20, UpZ)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 24, RightX)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 28, RightY)
			buffer.writef32(LocalDirectionsBuffer, DirectionWriteOffset + 32, RightZ)
		end

		if bit32.band(Mask, 8) ~= 0 then
			buffer.copy(LocalVisualBuffer, VisualWriteOffset, Payload, ReadOffset, VISUAL_STRIDE)
			ReadOffset += VISUAL_STRIDE
		end

		if bit32.band(Mask, 16) ~= 0 then
			buffer.copy(LocalPropertiesBuffer, PropertiesWriteOffset, Payload, ReadOffset, PROPERTIES_STRIDE)
			ReadOffset += PROPERTIES_STRIDE
		end

		ECSData.MarkDirty(TargetSlot)
	end
end)

-- Notify server that the Controller Actor's ReplicationReceiver listener is connected and ready for initial snapshot
ReplicateEvent:FireServer()
