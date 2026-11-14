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
const OrientationData = Storage.OrientationData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const PropertiesData = Storage.PropertiesData
const ECSData = Storage.ECSData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES_PER_PACKET = math.max(1, SystemsConfigs.MaxEntitiesPerReplicationPacket or 256) :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer
const PropertiesBuffer = PropertiesData.GetData() :: buffer
const StaticBuffer = ECSData.GetStaticData() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const PROPERTIES_BUFFER_SIZE = buffer.len(PropertiesBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

const ScratchPositions = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchOrientations = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchVisuals = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchSizes = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchDirections = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer
const ScratchProperties = buffer.create(PROPERTIES_BUFFER_SIZE) :: buffer

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

local PlayerCuller = {}

PlayerCuller.RemovePlayerState = PlayerFunctions.RemovePlayerState

-- ============================================================================
-- 1. CULLING FUNCTIONS - CONE & DELTA CULLING FOR REPLICATION
-- ============================================================================

--[=[
	Culls world entities against a player's dynamic view cone, delta-checks mutations, and returns packed replication buffers.
	@param PlayerObject Player -- Target replicating player.
	@return (buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?) -- DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts.
]=]
function PlayerCuller.CullObjects(
	PlayerObject: Player
): (buffer?, buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?)
	const EntityCount = math.min(ECSData.GetCounts().EntityECSCount, MAX_ENTITIES) :: number
	if EntityCount <= 0 then
		return nil, nil, nil, nil, nil, nil, nil
	end

	const State = PlayerFunctions.GetOrCreatePlayerState(PlayerObject, EntityCount)

	const VisibleFlags = State.VisibleFlags :: buffer
	const CachedPositions = State.Positions :: buffer
	const CachedOrientations = State.Orientations :: buffer
	const CachedVisuals = State.Visuals :: buffer
	const CachedSizes = State.Sizes :: buffer
	const CachedDirections = State.Directions :: buffer
	const CachedProperties = State.Properties :: buffer

	ViewCulling.UpdateObserverFromVectors(
		State.OriginX,
		State.OriginY,
		State.OriginZ,
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

	local WriteOffset = 0 :: number
	local DirectionWriteOffset = 0 :: number
	local PropertiesWriteOffset = 0 :: number
	local PackedCount = 0 :: number

	for i = 1, EntityCount do
		const FlagOffset = i - 1 :: number
		const IsStatic = (buffer.readu8(StaticBuffer, FlagOffset) == 1) :: boolean

		if not IsStatic and ViewCulling.IsEntityCulled(i, PositionBuffer, SizeBuffer) then
			continue
		end

		const ReadOffset = FlagOffset * COMPONENT_STRIDE :: number
		const DirectionReadOffset = FlagOffset * DIRECTION_STRIDE :: number
		const PropertiesReadOffset = FlagOffset * PROPERTIES_STRIDE :: number
		const HasReplicated = buffer.readu8(VisibleFlags, FlagOffset) :: number

		if
			HasReplicated == 1
			and not PlayerFunctions.HasEntityChanged(
				ReadOffset,
				DirectionReadOffset,
				PropertiesReadOffset,
				CachedPositions,
				CachedOrientations,
				CachedVisuals,
				CachedSizes,
				CachedDirections,
				CachedProperties
			)
		then
			continue
		end

		buffer.writeu8(VisibleFlags, FlagOffset, 1)

		buffer.copy(CachedPositions, ReadOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(CachedOrientations, ReadOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(CachedVisuals, ReadOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(CachedSizes, ReadOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(CachedDirections, DirectionReadOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)
		buffer.copy(CachedProperties, PropertiesReadOffset, PropertiesBuffer, PropertiesReadOffset, PROPERTIES_STRIDE)

		buffer.copy(ScratchPositions, WriteOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchOrientations, WriteOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchVisuals, WriteOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.writeu32(ScratchVisuals, WriteOffset + 4, i)
		buffer.copy(ScratchSizes, WriteOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchDirections, DirectionWriteOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)
		buffer.copy(ScratchProperties, PropertiesWriteOffset, PropertiesBuffer, PropertiesReadOffset, PROPERTIES_STRIDE)

		WriteOffset += COMPONENT_STRIDE
		DirectionWriteOffset += DIRECTION_STRIDE
		PropertiesWriteOffset += PROPERTIES_STRIDE
		PackedCount += 1

		if PackedCount >= MAX_ENTITIES_PER_PACKET then
			warn("ENTITY PACKETS HAVE OVERFLOWN THE LIMIT, CURRENT ENTITY NUMBER", MAX_ENTITIES_PER_PACKET)
			break
		end
	end

	if WriteOffset == 0 then
		return nil, nil, nil, nil, nil, nil, nil
	end

	const DeltaPositions = buffer.create(WriteOffset) :: buffer
	const DeltaOrientations = buffer.create(WriteOffset) :: buffer
	const DeltaVisuals = buffer.create(WriteOffset) :: buffer
	const DeltaSizes = buffer.create(WriteOffset) :: buffer
	const DeltaDirections = buffer.create(DirectionWriteOffset) :: buffer
	const DeltaProperties = buffer.create(PropertiesWriteOffset) :: buffer

	buffer.copy(DeltaPositions, 0, ScratchPositions, 0, WriteOffset)
	buffer.copy(DeltaOrientations, 0, ScratchOrientations, 0, WriteOffset)
	buffer.copy(DeltaVisuals, 0, ScratchVisuals, 0, WriteOffset)
	buffer.copy(DeltaSizes, 0, ScratchSizes, 0, WriteOffset)
	buffer.copy(DeltaDirections, 0, ScratchDirections, 0, DirectionWriteOffset)
	buffer.copy(DeltaProperties, 0, ScratchProperties, 0, PropertiesWriteOffset)

	const VisibleCount = WriteOffset // COMPONENT_STRIDE :: number

	const Counts: ECSTable = {
		OrientationECSCount = VisibleCount,
		PositionECSCount = VisibleCount,
		VisualECSCount = VisibleCount,
		SizeECSCount = VisibleCount,
		DirectionsECSCount = VisibleCount,
		EntityECSCount = VisibleCount,
	}

	return DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, DeltaProperties, Counts
end

return PlayerCuller
