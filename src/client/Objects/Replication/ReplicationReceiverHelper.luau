--!strict
--!native
--!optimize 2

--[=[
	@class ReplicationReceiverHelper
	Helper module for client replication ingestion, texture synchronization,
	player registry forwarding, and delta packet decoding with free-list slot management.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const EventBus = require(UtilitiesFolder:WaitForChild("EventBus"))
const TextureTable = require(UtilitiesFolder:WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const HEADER_BYTES = 8 :: number
const MASK_DESPAWN = 0x80 :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const NOT_CAN_COLLIDE = bit32.bnot(FLAG_CAN_COLLIDE) :: number
const Events = EventBus.Events

export type ReceiverState = {
	Storage: ECSMain.ECSStorage,
	LocalUserId: number,
	MaxEntities: number,
	ClientSlotByServerId: buffer,
	ServerIdByClientSlot: buffer,
}

-- Tables --
local ReplicationReceiverHelper = {}

-- Functions --
-- ============================================================================
-- 1. STATE INITIALIZATION, INBOUND EVENT DISPATCH & DELTA PAYLOAD INGESTION
-- ============================================================================

--[=[
	Creates bidirectional server<->client entity slot maps over the target client ECSStorage.
	@param Storage ECSMain.ECSStorage -- Target client ECSStorage instance.
	@param LocalUserId number -- Local player's UserId (or 0 if unavailable).
	@return ReceiverState -- Initialized replication receiver state.
]=]
function ReplicationReceiverHelper.CreateReceiverState(
	Storage: ECSMain.ECSStorage,
	LocalUserId: number
): ReceiverState
	const LocalPositionBuffer = Storage.PositionData.GetData() :: buffer
	const LocalSizeBuffer = Storage.SizeData.GetData() :: buffer
	const LocalDirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const LocalVisualBuffer = Storage.VisualData.GetData() :: buffer

	const MaxComponentEntities = math.min(buffer.len(LocalPositionBuffer), buffer.len(LocalSizeBuffer)) // COMPONENT_STRIDE :: number
	const MaxDirectionEntities = buffer.len(LocalDirectionsBuffer) // DIRECTION_STRIDE :: number
	const MaxVisualEntities = buffer.len(LocalVisualBuffer) // VISUAL_STRIDE :: number
	const MaxEntities = math.min(MaxComponentEntities, MaxDirectionEntities, MaxVisualEntities) :: number

	return {
		Storage = Storage,
		LocalUserId = LocalUserId,
		MaxEntities = MaxEntities,
		ClientSlotByServerId = buffer.create((MaxEntities + 1) * 4),
		ServerIdByClientSlot = buffer.create((MaxEntities + 1) * 4),
	}
end

--[=[
	Asynchronously decodes replicated server texture entries into TextureTable without stalling the frame loop.
	@param Entries any -- Replicated TextureEntry array from TextureSyncEvent.
]=]
function ReplicationReceiverHelper.ApplySyncedTextures(Entries: any)
	if type(Entries) ~= "table" then
		return
	end
	task.spawn(function()
		for _, Entry: any in ipairs(Entries :: { any }) do
			if type(Entry) == "table" and type(Entry.Id) == "number" and type(Entry.Url) == "string" then
				TextureTable.RegisterEntryWithId(Entry.Id, Entry.Url, Entry.Name)
			end
		end
	end)
end

--[=[
	Publishes inbound player registry snapshots onto the client EventBus so PlayerController never touches RemoteEvents.
	@param Bus EventBus.BusInstance -- Target EventBus instance.
	@param Entries any -- Replicated player registry entries array.
]=]
function ReplicationReceiverHelper.ForwardPlayerRegistry(Bus: EventBus.BusInstance, Entries: any)
	if type(Entries) ~= "table" then
		return
	end
	Bus.Emit(Events.PlayerRegistryReceived, Entries)
end

--[=[
	Unpacks a binary replication delta payload into Storage, releasing MASK_DESPAWN slots in place into the free-list
	and reconstructing orthonormal basis vectors and DynamicId bindings for active records.
	@param State ReceiverState -- Active replication receiver state.
	@param Payload buffer -- Binary replication delta packet from ReplicateEvent.
]=]
function ReplicationReceiverHelper.IngestPayload(State: ReceiverState, Payload: buffer)
	if typeof(Payload) ~= "buffer" or buffer.len(Payload) < HEADER_BYTES then
		return
	end

	const Storage = State.Storage
	const ECSData = Storage.ECSData
	const DynamicObjectsList = Storage.DynamicObjectsList
	const LocalPositionBuffer = Storage.PositionData.GetData() :: buffer
	const LocalSizeBuffer = Storage.SizeData.GetData() :: buffer
	const LocalDirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const LocalVisualBuffer = Storage.VisualData.GetData() :: buffer
	const LocalPropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	const MaxEntities = State.MaxEntities :: number
	const LocalUserId = State.LocalUserId :: number
	const ClientSlotByServerId = State.ClientSlotByServerId :: buffer
	const ServerIdByClientSlot = State.ServerIdByClientSlot :: buffer

	const UpdatedCount = buffer.readu16(Payload, 0) :: number
	local ReadOffset = HEADER_BYTES :: number
	const PayloadLen = buffer.len(Payload) :: number

	for _ = 1, UpdatedCount do
		if ReadOffset + 3 > PayloadLen then
			break
		end

		const ServerId = buffer.readu16(Payload, ReadOffset) :: number
		const Mask = buffer.readu8(Payload, ReadOffset + 2) :: number
		ReadOffset += 3

		if Mask == MASK_DESPAWN then
			if ServerId <= 0 or ServerId > MaxEntities then
				continue
			end
			const FreedSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4) :: number
			if FreedSlot > 0 then
				buffer.writeu32(ClientSlotByServerId, ServerId * 4, 0)
				buffer.writeu32(ServerIdByClientSlot, FreedSlot * 4, 0)
				ECSMain.SetEntityDynamicId(LocalPropertiesBuffer, FreedSlot, 0)
				ECSData.DeleteEntity(FreedSlot)
			end
			continue
		end

		local TargetSlot = if ServerId > 0 and ServerId <= MaxEntities
			then buffer.readu32(ClientSlotByServerId, ServerId * 4)
			else 0

		if TargetSlot == 0 then
			if ECSData.GetCounts().ActiveEntityCount >= MaxEntities then
				break
			end
			TargetSlot = ECSData.RegisterEntity()
			if TargetSlot <= 0 then
				break
			end
			if ServerId > 0 and ServerId <= MaxEntities then
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

			const ReplicatedReg = buffer.readu32(LocalPropertiesBuffer, PropertiesWriteOffset) :: number
			const ReplicatedDynId = ECSMain.GetEntityDynamicId(ReplicatedReg) :: number
			if ReplicatedDynId > 0 then
				const LinkedObj = DynamicObjectsList.GetObject(ReplicatedDynId)
				if type(LinkedObj) == "table" then
					const LinkedRecord = LinkedObj :: { [string]: any }
					DynamicObjectsList.BindEntity(ReplicatedDynId, TargetSlot)
					LinkedRecord.EntityId = TargetSlot
					if LocalUserId ~= 0 and LinkedRecord.UserId == LocalUserId then
						buffer.writeu32(LocalPropertiesBuffer, PropertiesWriteOffset, bit32.band(ReplicatedReg, NOT_CAN_COLLIDE))
					end
				elseif LinkedObj ~= nil then
					DynamicObjectsList.BindEntity(ReplicatedDynId, TargetSlot)
				end
			end
		end

		ECSData.MarkDirty(TargetSlot)
	end
end

return ReplicationReceiverHelper
