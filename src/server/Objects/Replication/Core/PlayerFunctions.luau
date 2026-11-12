--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const PositionData = Storage.PositionData
const OrientationData = Storage.OrientationData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

export type PlayerDeltaState = {
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

local PlayerFunctions = {}

-- ============================================================================
-- 1. PLAYER DELTA STATE & CHANGE DETECTION FUNCTIONS
-- ============================================================================

--[=[
	Cleans up the delta replication state cache for a leaving player.
	@param PlayerObject Player -- Player instance to remove.
]=]
function PlayerFunctions.RemovePlayerState(PlayerObject: Player)
	PlayerStates[PlayerObject] = nil
end

Players.PlayerRemoving:Connect(PlayerFunctions.RemovePlayerState)

--[=[
	Retrieves or instantiates the cached replication shadow buffers for a player.
	@param PlayerObject Player -- Target replicating player.
	@param Character Model? -- Current player character model.
	@param EntityCount number -- Current total world entity count.
	@return PlayerDeltaState -- Player's delta tracking state.
]=]
function PlayerFunctions.GetOrCreatePlayerState(
	PlayerObject: Player,
	Character: Model?,
	EntityCount: number
): PlayerDeltaState
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

--[=[
	Checks whether an entity's position, orientation, visual, size, or directions have changed since last replication.
	@param Offset number -- Byte offset in component buffers.
	@param DirectionOffset number -- Byte offset in directions buffers.
	@param CachedPositions buffer -- Player's shadow position buffer.
	@param CachedOrientations buffer -- Player's shadow orientation buffer.
	@param CachedVisuals buffer -- Player's shadow visual buffer.
	@param CachedSizes buffer -- Player's shadow size buffer.
	@param CachedDirections buffer -- Player's shadow directions buffer.
	@return boolean -- True if any component byte differs.
]=]
function PlayerFunctions.HasEntityChanged(
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

return PlayerFunctions
