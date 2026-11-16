--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData
const PositionData = Storage.PositionData
const VisualData = Storage.VisualData
const SizeData = Storage.SizeData
const DirectionsData = Storage.DirectionsData
const PropertiesData = Storage.PropertiesData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const DEFAULT_SPAWN = SystemsConfigs.PlayerDefaultSpawnPosition :: Vector3
const PLAYER_EYE_OFFSET = SystemsConfigs.CameraPlayerEyeOffset :: number
const DEFAULT_CAMERA_FOV = SystemsConfigs.DefaultCameraFOV :: number
const OBSERVER_PAYLOAD_BYTES = 56 :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer
const PropertiesBuffer = PropertiesData.GetData() :: buffer
const VersionBuffer = ECSData.GetVersionBuffer() :: buffer
const DirtyFlags = ECSData.GetDirtyFlags() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const VISUAL_BUFFER_SIZE = buffer.len(VisualBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const PROPERTIES_BUFFER_SIZE = buffer.len(PropertiesBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

-- Single server-wide shadow copy for change detection across all players
const ShadowPositions = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ShadowSizes = buffer.create(COMPONENT_BUFFER_SIZE) :: buffer
const ShadowDirections = buffer.create(DIRECTION_BUFFER_SIZE) :: buffer
const ShadowVisuals = buffer.create(VISUAL_BUFFER_SIZE) :: buffer
const ShadowProperties = buffer.create(PROPERTIES_BUFFER_SIZE) :: buffer

const PosVersions = buffer.create(MAX_ENTITIES * 4) :: buffer
const SizeVersions = buffer.create(MAX_ENTITIES * 4) :: buffer
const BasisVersions = buffer.create(MAX_ENTITIES * 4) :: buffer
const VisualVersions = buffer.create(MAX_ENTITIES * 4) :: buffer
const PropVersions = buffer.create(MAX_ENTITIES * 4) :: buffer

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
	SentVersion: buffer,
	ForceResync: buffer,
}

-- Tables --
local PlayerStates = {} :: { [Player]: PlayerDeltaState }

ECSData.SetSwapPopCallback(function(DeletedEntityId: number, MovedFromEntityId: number)
	if DeletedEntityId ~= MovedFromEntityId and DeletedEntityId >= 1 and DeletedEntityId <= MAX_ENTITIES then
		const FlagOffset = DeletedEntityId - 1 :: number
		const VersionOffset = FlagOffset * 4 :: number
		for _, State in pairs(PlayerStates) do
			if buffer.readu32(State.SentVersion, VersionOffset) > 0 then
				buffer.writeu8(State.ForceResync, FlagOffset, 1)
				buffer.writeu32(State.SentVersion, VersionOffset, 0)
			end
		end
	end
end)

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
			SentVersion = buffer.create(MAX_ENTITIES * 4),
			ForceResync = buffer.create(MAX_ENTITIES),
		}
		PlayerFunctions.TrySeedObserverFromCharacter(NewState, PlayerObject.Character)
		PlayerStates[PlayerObject] = NewState
		return NewState
	end

	if not State.CharacterSeeded and not State.ClientSynced then
		PlayerFunctions.TrySeedObserverFromCharacter(State, PlayerObject.Character)
	end

	if EntityCount < State.LastEntityCount then
		const ShrankCount = State.LastEntityCount - EntityCount :: number
		buffer.fill(State.SentVersion, EntityCount * 4, 0, ShrankCount * 4)
		buffer.fill(State.ForceResync, EntityCount, 0, ShrankCount)
	end

	return State
end

--[=[
	Marks a player's Actor-hosted ReplicationReceiver as connected and clears SentVersion so a complete initial snapshot is delivered.
	@param PlayerObject Player -- Target replicating player.
	@param EntityCount number -- Current total world entity count.
]=]
function PlayerFunctions.MarkClientReady(PlayerObject: Player, EntityCount: number)
	const State = PlayerFunctions.GetOrCreatePlayerState(PlayerObject, EntityCount)
	State.ClientReady = true
	buffer.fill(State.SentVersion, 0, 0, MAX_ENTITIES * 4)
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
	Scans active entities once per tick against the server-wide shadow copy to advance per-component
	version numbers without duplicating shadow buffers per player.
	@param EntityCount number -- Current total world entity count.
]=]
function PlayerFunctions.SyncEntityVersions(EntityCount: number)
	for i = 1, EntityCount do
		const FlagOffset = i - 1 :: number
		const VersionOffset = FlagOffset * 4 :: number
		const CompOffset = FlagOffset * COMPONENT_STRIDE :: number
		const DirOffset = FlagOffset * DIRECTION_STRIDE :: number
		const VisOffset = FlagOffset * VISUAL_STRIDE :: number
		const PropOffset = FlagOffset * PROPERTIES_STRIDE :: number

		local CurrentVer = buffer.readu32(VersionBuffer, VersionOffset) :: number
		local NextVer = CurrentVer :: number
		local AnyChanged = false :: boolean

		if
			buffer.readu32(PositionBuffer, CompOffset) ~= buffer.readu32(ShadowPositions, CompOffset)
			or buffer.readu32(PositionBuffer, CompOffset + 4) ~= buffer.readu32(ShadowPositions, CompOffset + 4)
			or buffer.readu32(PositionBuffer, CompOffset + 8) ~= buffer.readu32(ShadowPositions, CompOffset + 8)
		then
			if not AnyChanged then
				NextVer = CurrentVer + 1
				AnyChanged = true
			end
			buffer.copy(ShadowPositions, CompOffset, PositionBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.writeu32(PosVersions, VersionOffset, NextVer)
		end

		if
			buffer.readu32(SizeBuffer, CompOffset) ~= buffer.readu32(ShadowSizes, CompOffset)
			or buffer.readu32(SizeBuffer, CompOffset + 4) ~= buffer.readu32(ShadowSizes, CompOffset + 4)
			or buffer.readu32(SizeBuffer, CompOffset + 8) ~= buffer.readu32(ShadowSizes, CompOffset + 8)
		then
			if not AnyChanged then
				NextVer = CurrentVer + 1
				AnyChanged = true
			end
			buffer.copy(ShadowSizes, CompOffset, SizeBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.writeu32(SizeVersions, VersionOffset, NextVer)
		end

		for DirByte = 0, 32, 4 do
			if
				buffer.readu32(DirectionsBuffer, DirOffset + DirByte)
				~= buffer.readu32(ShadowDirections, DirOffset + DirByte)
			then
				if not AnyChanged then
					NextVer = CurrentVer + 1
					AnyChanged = true
				end
				buffer.copy(ShadowDirections, DirOffset, DirectionsBuffer, DirOffset, DIRECTION_STRIDE)
				buffer.writeu32(BasisVersions, VersionOffset, NextVer)
				break
			end
		end

		if buffer.readu32(VisualBuffer, VisOffset) ~= buffer.readu32(ShadowVisuals, VisOffset) then
			if not AnyChanged then
				NextVer = CurrentVer + 1
				AnyChanged = true
			end
			buffer.writeu32(ShadowVisuals, VisOffset, buffer.readu32(VisualBuffer, VisOffset))
			buffer.writeu32(VisualVersions, VersionOffset, NextVer)
		end

		if buffer.readu32(PropertiesBuffer, PropOffset) ~= buffer.readu32(ShadowProperties, PropOffset) then
			if not AnyChanged then
				NextVer = CurrentVer + 1
				AnyChanged = true
			end
			buffer.writeu32(ShadowProperties, PropOffset, buffer.readu32(PropertiesBuffer, PropOffset))
			buffer.writeu32(PropVersions, VersionOffset, NextVer)
		end

		if AnyChanged then
			buffer.writeu32(VersionBuffer, VersionOffset, NextVer)
			buffer.writeu8(DirtyFlags, FlagOffset, 0)
		elseif CurrentVer == 0 then
			buffer.writeu32(VersionBuffer, VersionOffset, 1)
			buffer.writeu32(PosVersions, VersionOffset, 1)
			buffer.writeu32(SizeVersions, VersionOffset, 1)
			buffer.writeu32(BasisVersions, VersionOffset, 1)
			buffer.writeu32(VisualVersions, VersionOffset, 1)
			buffer.writeu32(PropVersions, VersionOffset, 1)
		end
	end
end

--[=[
	Computes the 5-bit component delta mask for an entity relative to a player's SentVersion.
	@param EntityId number -- 1-based entity ID.
	@param SentVersion number -- Last entity version delivered to the player (0 if never sent).
	@return (number, number) -- (ComponentMask, CurrentEntityVersion).
]=]
function PlayerFunctions.GetEntityDeltaMask(EntityId: number, SentVersion: number): (number, number)
	const VersionOffset = (EntityId - 1) * 4 :: number
	const CurrentVer = buffer.readu32(VersionBuffer, VersionOffset) :: number
	if SentVersion == 0 then
		return 0x1F, CurrentVer
	end
	if SentVersion >= CurrentVer then
		return 0, CurrentVer
	end

	local Mask = 0 :: number
	if buffer.readu32(PosVersions, VersionOffset) > SentVersion then
		Mask += 1
	end
	if buffer.readu32(SizeVersions, VersionOffset) > SentVersion then
		Mask += 2
	end
	if buffer.readu32(BasisVersions, VersionOffset) > SentVersion then
		Mask += 4
	end
	if buffer.readu32(VisualVersions, VersionOffset) > SentVersion then
		Mask += 8
	end
	if buffer.readu32(PropVersions, VersionOffset) > SentVersion then
		Mask += 16
	end
	return Mask, CurrentVer
end

return PlayerFunctions
