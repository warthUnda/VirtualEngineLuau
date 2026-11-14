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

-- Storage Tables
const PositionData = Storage.PositionData
const OrientationData = Storage.OrientationData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const PropertiesData = Storage.PropertiesData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number
const OBSERVER_PAYLOAD_BYTES = 56 :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer
const PropertiesBuffer = PropertiesData.GetData() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const PROPERTIES_BUFFER_SIZE = buffer.len(PropertiesBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

export type PlayerDeltaState = {
	ClientReady: boolean,
	CharacterSeeded: boolean,
	ClientSynced: boolean,
	OriginX: number,
	OriginY: number,
	OriginZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	RightX: number,
	RightY: number,
	RightZ: number,
	ExtraBackPadding: number,
	FovDegrees: number,
	LastEntityCount: number,
	VisibleFlags: buffer,
	Positions: buffer,
	Orientations: buffer,
	Visuals: buffer,
	Sizes: buffer,
	Directions: buffer,
	Properties: buffer,
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
	Seeds a player's observer transform once from their initial character model if available.
	@param State PlayerDeltaState -- Target player delta tracking state.
	@param Character Model? -- Optional player character model.
]=]
function PlayerFunctions.TrySeedObserverFromCharacter(State: PlayerDeltaState, Character: Model?)
	if State.CharacterSeeded or State.ClientSynced or not Character or not Character.Parent then
		return
	end

	const AnchorCandidate = Character:FindFirstChild("Head")
		or Character:FindFirstChild("HumanoidRootPart")
		or Character.PrimaryPart
		or Character:FindFirstChildWhichIsA("BasePart")

	local SeedCFrame: CFrame
	if AnchorCandidate and AnchorCandidate:IsA("BasePart") then
		SeedCFrame = AnchorCandidate.CFrame
	else
		SeedCFrame = Character:GetPivot()
	end

	const Pos = SeedCFrame.Position :: Vector3
	const Look = SeedCFrame.LookVector :: Vector3
	const Up = SeedCFrame.UpVector :: Vector3
	const Right = SeedCFrame.RightVector :: Vector3

	State.CharacterSeeded = true
	State.OriginX, State.OriginY, State.OriginZ = Pos.X, Pos.Y, Pos.Z
	State.LookX, State.LookY, State.LookZ = Look.X, Look.Y, Look.Z
	State.UpX, State.UpY, State.UpZ = Up.X, Up.Y, Up.Z
	State.RightX, State.RightY, State.RightZ = Right.X, Right.Y, Right.Z
end

--[=[
	Retrieves or instantiates the cached replication shadow buffers and standalone observer state for a player.
	@param PlayerObject Player -- Target replicating player.
	@param EntityCount number -- Current total world entity count.
	@return PlayerDeltaState -- Player's delta tracking state.
]=]
function PlayerFunctions.GetOrCreatePlayerState(PlayerObject: Player, EntityCount: number): PlayerDeltaState
	local State = PlayerStates[PlayerObject] :: PlayerDeltaState?
	if not State then
		const NewState: PlayerDeltaState = {
			ClientReady = false,
			CharacterSeeded = false,
			ClientSynced = false,
			OriginX = DEFAULT_SPAWN.X,
			OriginY = DEFAULT_SPAWN.Y + PLAYER_EYE_OFFSET,
			OriginZ = DEFAULT_SPAWN.Z,
			LookX = 0,
			LookY = 0,
			LookZ = -1,
			UpX = 0,
			UpY = 1,
			UpZ = 0,
			RightX = 1,
			RightY = 0,
			RightZ = 0,
			ExtraBackPadding = 0,
			FovDegrees = DEFAULT_CAMERA_FOV,
			LastEntityCount = EntityCount,
			VisibleFlags = buffer.create(MAX_ENTITIES),
			Positions = buffer.create(COMPONENT_BUFFER_SIZE),
			Orientations = buffer.create(COMPONENT_BUFFER_SIZE),
			Visuals = buffer.create(COMPONENT_BUFFER_SIZE),
			Sizes = buffer.create(COMPONENT_BUFFER_SIZE),
			Directions = buffer.create(DIRECTION_BUFFER_SIZE),
			Properties = buffer.create(PROPERTIES_BUFFER_SIZE),
		}
		PlayerFunctions.TrySeedObserverFromCharacter(NewState, PlayerObject.Character)
		PlayerStates[PlayerObject] = NewState
		return NewState
	end

	if not State.CharacterSeeded and not State.ClientSynced then
		PlayerFunctions.TrySeedObserverFromCharacter(State, PlayerObject.Character)
	end

	if EntityCount < State.LastEntityCount then
		buffer.fill(State.VisibleFlags, EntityCount, 0, State.LastEntityCount - EntityCount)
	end

	State.LastEntityCount = EntityCount
	return State
end

--[=[
	Marks a player's Actor-hosted ReplicationReceiver as connected and clears VisibleFlags so a complete initial snapshot is delivered.
	@param PlayerObject Player -- Target replicating player.
	@param EntityCount number -- Current total world entity count.
]=]
function PlayerFunctions.MarkClientReady(PlayerObject: Player, EntityCount: number)
	const State = PlayerFunctions.GetOrCreatePlayerState(PlayerObject, EntityCount)
	State.ClientReady = true
	buffer.fill(State.VisibleFlags, 0, 0, MAX_ENTITIES)
end

--[=[
	Returns whether a player's client ReplicationReceiver has connected and signaled readiness.
	@param PlayerObject Player -- Target replicating player.
	@return boolean -- True once the client receiver is listening on ReplicateEvent.
]=]
function PlayerFunctions.IsClientReady(PlayerObject: Player): boolean
	const State = PlayerStates[PlayerObject]
	return if State then State.ClientReady else false
end

--[=[
	Ingests a 56-byte client virtual observer buffer into the player's server replication state.
	@param PlayerObject Player -- Replicating player who sent the payload.
	@param PayloadBuffer buffer -- 56-byte observer payload buffer.
	@param EntityCount number -- Current server ECS entity count.
]=]
function PlayerFunctions.UpdateObserverFromBuffer(PlayerObject: Player, PayloadBuffer: buffer, EntityCount: number)
	if typeof(PlayerObject) == "Instance" and not PlayerObject:IsDescendantOf(Players) then
		return
	end

	if typeof(PayloadBuffer) ~= "buffer" or buffer.len(PayloadBuffer) < OBSERVER_PAYLOAD_BYTES then
		return
	end

	const OriginX = buffer.readf32(PayloadBuffer, 0) :: number
	const OriginY = buffer.readf32(PayloadBuffer, 4) :: number
	const OriginZ = buffer.readf32(PayloadBuffer, 8) :: number
	const LookX = buffer.readf32(PayloadBuffer, 12) :: number
	const LookY = buffer.readf32(PayloadBuffer, 16) :: number
	const LookZ = buffer.readf32(PayloadBuffer, 20) :: number
	const UpX = buffer.readf32(PayloadBuffer, 24) :: number
	const UpY = buffer.readf32(PayloadBuffer, 28) :: number
	const UpZ = buffer.readf32(PayloadBuffer, 32) :: number
	const RightX = buffer.readf32(PayloadBuffer, 36) :: number
	const RightY = buffer.readf32(PayloadBuffer, 40) :: number
	const RightZ = buffer.readf32(PayloadBuffer, 44) :: number
	const ExtraBackPadding = buffer.readf32(PayloadBuffer, 48) :: number
	const FovDegrees = buffer.readf32(PayloadBuffer, 52) :: number

	-- Reject NaNs or degenerate basis vectors
	const SumCheck = OriginX
		+ OriginY
		+ OriginZ
		+ LookX
		+ LookY
		+ LookZ
		+ UpX
		+ UpY
		+ UpZ
		+ RightX
		+ RightY
		+ RightZ
		+ ExtraBackPadding
		+ FovDegrees :: number
	if SumCheck ~= SumCheck or math.abs(SumCheck) == math.huge then
		return
	end

	const LookLenSq = LookX * LookX + LookY * LookY + LookZ * LookZ :: number
	if LookLenSq < 0.5 or LookLenSq > 1.5 then
		return
	end

	const State = PlayerFunctions.GetOrCreatePlayerState(PlayerObject, EntityCount)
	State.CharacterSeeded = true
	State.ClientSynced = true
	State.OriginX, State.OriginY, State.OriginZ = OriginX, OriginY, OriginZ
	State.LookX, State.LookY, State.LookZ = LookX, LookY, LookZ
	State.UpX, State.UpY, State.UpZ = UpX, UpY, UpZ
	State.RightX, State.RightY, State.RightZ = RightX, RightY, RightZ
	State.ExtraBackPadding = math.clamp(ExtraBackPadding, 0, 200)
	State.FovDegrees = math.clamp(FovDegrees, 10, 120)
end

--[=[
	Checks whether an entity's position, orientation, visual, size, directions, or properties have changed since last replication.
	@param Offset number -- Byte offset in component buffers.
	@param DirectionOffset number -- Byte offset in directions buffers.
	@param PropertiesOffset number -- Byte offset in properties buffers.
	@param CachedPositions buffer -- Player's shadow position buffer.
	@param CachedOrientations buffer -- Player's shadow orientation buffer.
	@param CachedVisuals buffer -- Player's shadow visual buffer.
	@param CachedSizes buffer -- Player's shadow size buffer.
	@param CachedDirections buffer -- Player's shadow directions buffer.
	@param CachedProperties buffer -- Player's shadow properties buffer.
	@return boolean -- True if any component byte differs.
]=]
function PlayerFunctions.HasEntityChanged(
	Offset: number,
	DirectionOffset: number,
	PropertiesOffset: number,
	CachedPositions: buffer,
	CachedOrientations: buffer,
	CachedVisuals: buffer,
	CachedSizes: buffer,
	CachedDirections: buffer,
	CachedProperties: buffer
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

	for DirectionByte = 0, 32, 4 do
		if
			buffer.readu32(DirectionsBuffer, DirectionOffset + DirectionByte)
			~= buffer.readu32(CachedDirections, DirectionOffset + DirectionByte)
		then
			return true
		end
	end

	if buffer.readu32(PropertiesBuffer, PropertiesOffset) ~= buffer.readu32(CachedProperties, PropertiesOffset) then
		return true
	end

	return false
end

return PlayerFunctions
