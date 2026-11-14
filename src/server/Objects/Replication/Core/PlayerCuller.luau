--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const PlayerFunctions = require(script.Parent.PlayerFunctions)
const ViewCulling = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Core")
		:WaitForChild("ViewCulling")
)

-- Storage tables (ECS)
const PositionData = Storage.PositionData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const PropertiesData = Storage.PropertiesData
const ECSData = Storage.ECSData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES_PER_PACKET = math.max(1, SystemsConfigs.MaxEntitiesPerReplicationPacket or 256) :: number
const STATIC_STREAM_RADIUS = (SystemsConfigs.StaticStreamRadius or 260) :: number
const STATIC_STREAM_RADIUS_SQ = STATIC_STREAM_RADIUS * STATIC_STREAM_RADIUS :: number
const HEADER_BYTES = 8 :: number
const MAX_RECORD_BYTES = 59 :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer
const PropertiesBuffer = PropertiesData.GetData() :: buffer
const StaticBuffer = ECSData.GetStaticData() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

const ScratchPayload = buffer.create(HEADER_BYTES + MAX_ENTITIES_PER_PACKET * MAX_RECORD_BYTES) :: buffer

local ReplicationTick = 0 :: number

local PlayerCuller = {}

PlayerCuller.RemovePlayerState = PlayerFunctions.RemovePlayerState

-- ============================================================================
-- 1. CULLING FUNCTIONS - CONE & DELTA CULLING FOR REPLICATION
-- ============================================================================

--[=[
	Culls world entities against a player's dynamic view cone, delta-checks component versions,
	and returns a single packed binary delta payload buffer.
	@param PlayerObject Player -- Target replicating player.
	@param SkipVersionSync boolean? -- Optional flag when SyncEntityVersions was already run this tick.
	@return buffer? -- Packed replication delta payload, or nil if no updates/despawns occurred.
]=]
function PlayerCuller.CullObjects(PlayerObject: Player, SkipVersionSync: boolean?): buffer?
	const EntityCount = math.min(ECSData.GetCounts().EntityECSCount, MAX_ENTITIES) :: number
	const State = PlayerFunctions.GetOrCreatePlayerState(PlayerObject, EntityCount)
	const PreviousCount = State.LastEntityCount :: number
	const WorldShrank = EntityCount < PreviousCount :: boolean

	if EntityCount <= 0 then
		State.LastEntityCount = 0
		if not WorldShrank then
			return nil
		end

		ReplicationTick += 1
		const EmptyPacket = buffer.create(HEADER_BYTES) :: buffer
		buffer.writeu16(EmptyPacket, 0, 0)
		buffer.writeu16(EmptyPacket, 2, 0)
		buffer.writeu32(EmptyPacket, 4, ReplicationTick)
		return EmptyPacket
	end

	if not SkipVersionSync then
		PlayerFunctions.SyncEntityVersions(EntityCount)
	end

	const SentVersion = State.SentVersion :: buffer
	const OriginX = State.OriginX :: number
	const OriginY = State.OriginY :: number
	const OriginZ = State.OriginZ :: number

	ViewCulling.UpdateObserverFromVectors(
		OriginX,
		OriginY,
		OriginZ,
		State.LookX,
		State.LookY,
		State.LookZ,
		State.UpX,
		State.UpY,
		State.UpZ,
		State.RightX,
		State.RightY,
		State.RightZ,
		State.ExtraBackPadding,
		State.FovDegrees
	)
	ViewCulling.PrepassDominantOccluder(EntityCount, PositionBuffer, SizeBuffer, PropertiesBuffer)

	local WriteOffset = HEADER_BYTES :: number
	local PackedCount = 0 :: number

	for i = 1, EntityCount do
		const FlagOffset = i - 1 :: number
		const VersionOffset = FlagOffset * 4 :: number
		const SentVer = buffer.readu32(SentVersion, VersionOffset) :: number
		const IsStatic = (buffer.readu8(StaticBuffer, FlagOffset) == 1) :: boolean

		if IsStatic then
			if SentVer > 0 then
				const Mask, _ = PlayerFunctions.GetEntityDeltaMask(i, SentVer)
				if Mask == 0 then
					continue
				end
			else
				const PosOffset = FlagOffset * COMPONENT_STRIDE :: number
				const Dx = buffer.readf32(PositionBuffer, PosOffset) - OriginX :: number
				const Dy = buffer.readf32(PositionBuffer, PosOffset + 4) - OriginY :: number
				const Dz = buffer.readf32(PositionBuffer, PosOffset + 8) - OriginZ :: number
				if Dx * Dx + Dy * Dy + Dz * Dz > STATIC_STREAM_RADIUS_SQ then
					continue
				end
			end
		else
			if ViewCulling.IsEntityCulled(i, PositionBuffer, SizeBuffer) then
				continue
			end
		end

		const Mask, CurrentVer = PlayerFunctions.GetEntityDeltaMask(i, SentVer)
		if Mask == 0 then
			continue
		end

		if PackedCount >= MAX_ENTITIES_PER_PACKET then
			warn("ENTITY PACKETS HAVE OVERFLOWN THE LIMIT, CURRENT ENTITY NUMBER", MAX_ENTITIES_PER_PACKET)
			break
		end

		buffer.writeu32(SentVersion, VersionOffset, CurrentVer)
		buffer.writeu16(ScratchPayload, WriteOffset, i)
		buffer.writeu8(ScratchPayload, WriteOffset + 2, Mask)
		WriteOffset += 3

		const CompOffset = FlagOffset * COMPONENT_STRIDE :: number
		if bit32.band(Mask, 1) ~= 0 then
			buffer.copy(ScratchPayload, WriteOffset, PositionBuffer, CompOffset, COMPONENT_STRIDE)
			WriteOffset += COMPONENT_STRIDE
		end

		if bit32.band(Mask, 2) ~= 0 then
			buffer.copy(ScratchPayload, WriteOffset, SizeBuffer, CompOffset, COMPONENT_STRIDE)
			WriteOffset += COMPONENT_STRIDE
		end

		if bit32.band(Mask, 4) ~= 0 then
			const DirOffset = FlagOffset * DIRECTION_STRIDE :: number
			-- Directions layout: Look (0..11), Up (12..23), Right (24..35); client reconstructs Right = Look x Up
			buffer.copy(ScratchPayload, WriteOffset, DirectionsBuffer, DirOffset, 24)
			WriteOffset += 24
		end

		if bit32.band(Mask, 8) ~= 0 then
			const VisOffset = FlagOffset * VISUAL_STRIDE :: number
			buffer.copy(ScratchPayload, WriteOffset, VisualBuffer, VisOffset, VISUAL_STRIDE)
			WriteOffset += VISUAL_STRIDE
		end

		if bit32.band(Mask, 16) ~= 0 then
			const PropOffset = FlagOffset * PROPERTIES_STRIDE :: number
			buffer.copy(ScratchPayload, WriteOffset, PropertiesBuffer, PropOffset, PROPERTIES_STRIDE)
			WriteOffset += PROPERTIES_STRIDE
		end

		PackedCount += 1
	end

	State.LastEntityCount = EntityCount

	if PackedCount == 0 and not WorldShrank then
		return nil
	end

	ReplicationTick += 1
	buffer.writeu16(ScratchPayload, 0, PackedCount)
	buffer.writeu16(ScratchPayload, 2, EntityCount)
	buffer.writeu32(ScratchPayload, 4, ReplicationTick)

	const Packet = buffer.create(WriteOffset) :: buffer
	buffer.copy(Packet, 0, ScratchPayload, 0, WriteOffset)
	return Packet
end

return PlayerCuller
