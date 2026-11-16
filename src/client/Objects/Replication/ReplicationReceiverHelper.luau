--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const HEADER_BYTES = 8 :: number
const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const NOT_CAN_COLLIDE = bit32.bnot(FLAG_CAN_COLLIDE) :: number

export type ReceiverState = {
	Storage: ECSMain.ECSStorage,
	LocalUserId: number,
	MaxEntities: number,
	ClientSlotByServerId: buffer,
	ServerIdByClientSlot: buffer,
	LastWorldEntityCount: number,
}

-- Tables --
local ReplicationReceiverHelper = {}

-- ============================================================================
-- 1. STATE INITIALIZATION & BINARY DELTA PAYLOAD INGESTION
-- ============================================================================

--[=[
	Creates bidirectional server<->client entity slot maps and registers the O(1) swap-and-pop hook on Storage.
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

	const MaxComponentEntities = math.min(
		buffer.len(LocalPositionBuffer),
		buffer.len(LocalSizeBuffer)
	) // COMPONENT_STRIDE :: number
	const MaxDirectionEntities = buffer.len(LocalDirectionsBuffer) // DIRECTION_STRIDE :: number
	const MaxVisualEntities = buffer.len(LocalVisualBuffer) // VISUAL_STRIDE :: number
	const MaxEntities = math.min(MaxComponentEntities, MaxDirectionEntities, MaxVisualEntities) :: number

	const ClientSlotByServerId = buffer.create((MaxEntities + 1) * 4) :: buffer
	const ServerIdByClientSlot = buffer.create((MaxEntities + 1) * 4) :: buffer
	const ECSData = Storage.ECSData
	const DynamicObjectsList = Storage.DynamicObjectsList

	ECSData.SetSwapPopCallback(function(DeletedSlot: number, LastSlot: number)
		if DeletedSlot ~= LastSlot then
			const MovedServerId = buffer.readu32(ServerIdByClientSlot, LastSlot * 4) :: number
			buffer.writeu32(ServerIdByClientSlot, DeletedSlot * 4, MovedServerId)
			if MovedServerId > 0 and MovedServerId <= MaxEntities then
				buffer.writeu32(ClientSlotByServerId, MovedServerId * 4, DeletedSlot)
			end
			const MovedObj = DynamicObjectsList.GetObjectByEntityId(DeletedSlot)
			if type(MovedObj) == "table" then
				const MovedRecord = MovedObj :: { [string]: any }
				MovedRecord.EntityId = DeletedSlot
			end
			ECSData.MarkDirty(DeletedSlot)
		end
		buffer.writeu32(ServerIdByClientSlot, LastSlot * 4, 0)
	end)

	return {
		Storage = Storage,
		LocalUserId = LocalUserId,
		MaxEntities = MaxEntities,
		ClientSlotByServerId = ClientSlotByServerId,
		ServerIdByClientSlot = ServerIdByClientSlot,
		LastWorldEntityCount = 0,
	}
end

--[=[
	Unpacks a binary replication delta payload into Storage, reconstructing orthonormal basis vectors,
	compacting despawned tail server IDs, and binding replicated DynamicIds into DynamicObjectsList.
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
	const WorldEntityCount = buffer.readu16(Payload, 2) :: number
	const PreviousWorldCount = State.LastWorldEntityCount :: number

	if WorldEntityCount < PreviousWorldCount then
		for ServerId = WorldEntityCount + 1, math.min(PreviousWorldCount, MaxEntities) do
			const StaleSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4) :: number
			if StaleSlot > 0 then
				buffer.writeu32(ClientSlotByServerId, ServerId * 4, 0)
				ECSMain.SetEntityDynamicId(LocalPropertiesBuffer, StaleSlot, 0)
				ECSData.DeleteEntity(StaleSlot)
			end
		end
	end
	State.LastWorldEntityCount = WorldEntityCount

	local ReadOffset = HEADER_BYTES :: number
	const PayloadLen = buffer.len(Payload) :: number

	for _ = 1, UpdatedCount do
		if ReadOffset + 3 > PayloadLen then
			break
		end

		const ServerId = buffer.readu16(Payload, ReadOffset) :: number
		const Mask = buffer.readu8(Payload, ReadOffset + 2) :: number
		ReadOffset += 3

		local TargetSlot = if ServerId > 0 and ServerId <= MaxEntities
			then buffer.readu32(ClientSlotByServerId, ServerId * 4)
			else 0

		if TargetSlot == 0 then
			if ECSData.GetCounts().EntityECSCount >= MaxEntities then
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

			const ReplicatedReg = buffer.readu32(LocalPropertiesBuffer, PropertiesWriteOffset) :: number
			const ReplicatedDynId = ECSMain.GetEntityDynamicId(ReplicatedReg) :: number
			if ReplicatedDynId > 0 then
				const LinkedObj = DynamicObjectsList.GetObject(ReplicatedDynId)
				if type(LinkedObj) == "table" then
					const LinkedRecord = LinkedObj :: { [string]: any }
					DynamicObjectsList.BindEntity(ReplicatedDynId, TargetSlot)
					LinkedRecord.EntityId = TargetSlot
					if LocalUserId ~= 0 and LinkedRecord.UserId == LocalUserId then
						buffer.writeu32(
							LocalPropertiesBuffer,
							PropertiesWriteOffset,
							bit32.band(ReplicatedReg, NOT_CAN_COLLIDE)
						)
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
