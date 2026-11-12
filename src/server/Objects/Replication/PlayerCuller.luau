--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const PositionData = Storage.PositionData
const OrientationData = Storage.OrientationData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const ECSData = Storage.ECSData
const ViewCulling = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Core")
		:WaitForChild("ViewCulling")
)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer
const StaticBuffer = ECSData.GetStaticData() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

const ScratchPositions = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchOrientations = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchVisuals = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchSizes = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ScratchDirections = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

type PlayerDeltaState = {
	Character: Model?,
	LastEntityCount: number,
	VisibleFlags: buffer,
	Positions: buffer,
	Orientations: buffer,
	Visuals: buffer,
	Sizes: buffer,
	Directions: buffer,
}

-- Tables --
local PlayerStates = {} :: { [Player]: PlayerDeltaState }

local PlayerCuller = {}

function PlayerCuller.RemovePlayerState(PlayerObject: Player)
	PlayerStates[PlayerObject] = nil
end

Players.PlayerRemoving:Connect(PlayerCuller.RemovePlayerState)

local function GetOrCreatePlayerState(PlayerObject: Player, Character: Model?, EntityCount: number): PlayerDeltaState
	local State = PlayerStates[PlayerObject] :: PlayerDeltaState?
	if not State then
		const NewState: PlayerDeltaState = {
			Character = Character,
			LastEntityCount = EntityCount,
			VisibleFlags = buffer.create(MAX_ENTITIES),
			Positions = buffer.create(COMPONENT_BUFFER_SIZE),
			Orientations = buffer.create(COMPONENT_BUFFER_SIZE),
			Visuals = buffer.create(COMPONENT_BUFFER_SIZE),
			Sizes = buffer.create(COMPONENT_BUFFER_SIZE),
			Directions = buffer.create(DIRECTION_BUFFER_SIZE),
		}
		PlayerStates[PlayerObject] = NewState
		return NewState
	end

	if State.Character ~= Character then
		State.Character = Character
		buffer.fill(State.VisibleFlags, 0, 0)
	elseif EntityCount < State.LastEntityCount then
		buffer.fill(State.VisibleFlags, EntityCount, 0, State.LastEntityCount - EntityCount)
	end

	State.LastEntityCount = EntityCount
	return State
end

local function HasEntityChanged(
	Offset: number,
	DirectionOffset: number,
	CachedPositions: buffer,
	CachedOrientations: buffer,
	CachedVisuals: buffer,
	CachedSizes: buffer,
	CachedDirections: buffer
): boolean
	if
		buffer.readu32(PositionBuffer, Offset) ~= buffer.readu32(CachedPositions, Offset)
		or buffer.readu32(PositionBuffer, Offset + 4) ~= buffer.readu32(CachedPositions, Offset + 4)
		or buffer.readu32(PositionBuffer, Offset + 8) ~= buffer.readu32(CachedPositions, Offset + 8)
	then
		return true
	end

	if
		buffer.readu32(OrientationBuffer, Offset) ~= buffer.readu32(CachedOrientations, Offset)
		or buffer.readu32(OrientationBuffer, Offset + 4) ~= buffer.readu32(CachedOrientations, Offset + 4)
		or buffer.readu32(OrientationBuffer, Offset + 8) ~= buffer.readu32(CachedOrientations, Offset + 8)
	then
		return true
	end

	if buffer.readu32(VisualBuffer, Offset) ~= buffer.readu32(CachedVisuals, Offset) then
		return true
	end

	if
		buffer.readu32(SizeBuffer, Offset) ~= buffer.readu32(CachedSizes, Offset)
		or buffer.readu32(SizeBuffer, Offset + 4) ~= buffer.readu32(CachedSizes, Offset + 4)
		or buffer.readu32(SizeBuffer, Offset + 8) ~= buffer.readu32(CachedSizes, Offset + 8)
	then
		return true
	end

	if
		buffer.readu32(DirectionsBuffer, DirectionOffset) ~= buffer.readu32(CachedDirections, DirectionOffset)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 4) ~= buffer.readu32(CachedDirections, DirectionOffset + 4)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 8) ~= buffer.readu32(CachedDirections, DirectionOffset + 8)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 12) ~= buffer.readu32(CachedDirections, DirectionOffset + 12)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 16) ~= buffer.readu32(CachedDirections, DirectionOffset + 16)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 20) ~= buffer.readu32(CachedDirections, DirectionOffset + 20)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 24) ~= buffer.readu32(CachedDirections, DirectionOffset + 24)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 28) ~= buffer.readu32(CachedDirections, DirectionOffset + 28)
		or buffer.readu32(DirectionsBuffer, DirectionOffset + 32) ~= buffer.readu32(CachedDirections, DirectionOffset + 32)
	then
		return true
	end

	return false
end

-- ============================================================================
-- 1. CULLING FUNCTIONS - CONE & DELTA CULLING FOR REPLICATION
-- ============================================================================

-- Returns only the newly visible or changed entities inside the player's view cone,
-- packed with the ECS strides, along with the delta counts.
function PlayerCuller.CullObjects(PlayerObject: Player): (buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?)
	const Head = ViewCulling.GetObserverHead(PlayerObject) :: BasePart?
	if not Head then
		return nil, nil, nil, nil, nil, nil
	end

	const EntityCount = math.min(ECSData.GetCounts().EntityECSCount, MAX_ENTITIES) :: number
	const State = GetOrCreatePlayerState(PlayerObject, PlayerObject.Character, EntityCount)

	const VisibleFlags = State.VisibleFlags :: buffer
	const CachedPositions = State.Positions :: buffer
	const CachedOrientations = State.Orientations :: buffer
	const CachedVisuals = State.Visuals :: buffer
	const CachedSizes = State.Sizes :: buffer
	const CachedDirections = State.Directions :: buffer

	ViewCulling.UpdateDynamicView(Head)

	local WriteOffset = 0 :: number
	local DirectionWriteOffset = 0 :: number

	for i = 1, EntityCount do
		const FlagOffset = i - 1 :: number
		const IsStatic = buffer.readu8(StaticBuffer, FlagOffset) == 1 :: boolean

		if not IsStatic and ViewCulling.IsEntityCulled(i, PositionBuffer, SizeBuffer) then
			buffer.writeu8(VisibleFlags, FlagOffset, 0)
			continue
		end

		const ReadOffset = FlagOffset * COMPONENT_STRIDE :: number
		const DirectionReadOffset = FlagOffset * DIRECTION_STRIDE :: number
		const WasVisible = buffer.readu8(VisibleFlags, FlagOffset) :: number

		if
			WasVisible == 1
			and not HasEntityChanged(
				ReadOffset,
				DirectionReadOffset,
				CachedPositions,
				CachedOrientations,
				CachedVisuals,
				CachedSizes,
				CachedDirections
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

		buffer.copy(ScratchPositions, WriteOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchOrientations, WriteOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchVisuals, WriteOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.writeu32(ScratchVisuals, WriteOffset + 4, i)
		buffer.copy(ScratchSizes, WriteOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(ScratchDirections, DirectionWriteOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)

		WriteOffset += COMPONENT_STRIDE
		DirectionWriteOffset += DIRECTION_STRIDE
	end

	if WriteOffset == 0 then
		return nil, nil, nil, nil, nil, nil
	end

	const DeltaPositions = buffer.create(WriteOffset) :: buffer
	const DeltaOrientations = buffer.create(WriteOffset) :: buffer
	const DeltaVisuals = buffer.create(WriteOffset) :: buffer
	const DeltaSizes = buffer.create(WriteOffset) :: buffer
	const DeltaDirections = buffer.create(DirectionWriteOffset) :: buffer

	buffer.copy(DeltaPositions, 0, ScratchPositions, 0, WriteOffset)
	buffer.copy(DeltaOrientations, 0, ScratchOrientations, 0, WriteOffset)
	buffer.copy(DeltaVisuals, 0, ScratchVisuals, 0, WriteOffset)
	buffer.copy(DeltaSizes, 0, ScratchSizes, 0, WriteOffset)
	buffer.copy(DeltaDirections, 0, ScratchDirections, 0, DirectionWriteOffset)

	const VisibleCount = WriteOffset // COMPONENT_STRIDE :: number

	const Counts: ECSTable = {
		OrientationECSCount = VisibleCount,
		PositionECSCount = VisibleCount,
		VisualECSCount = VisibleCount,
		SizeECSCount = VisibleCount,
		DirectionsECSCount = VisibleCount,
		EntityECSCount = VisibleCount,
	}

	return DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts
end

return PlayerCuller
