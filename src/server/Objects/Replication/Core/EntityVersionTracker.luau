--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

-- Buffers
const PositionBuffer = Storage.PositionData.GetData() :: buffer
const VisualBuffer = Storage.VisualData.GetData() :: buffer
const SizeBuffer = Storage.SizeData.GetData() :: buffer
const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
const ActiveFlags = ECSData.GetActiveFlags() :: buffer
const VersionBuffer = ECSData.GetVersionBuffer() :: buffer
const DirtyFlags = ECSData.GetDirtyFlags() :: buffer

const COMPONENT_BUFFER_SIZE = buffer.len(PositionBuffer) :: number
const VISUAL_BUFFER_SIZE = buffer.len(VisualBuffer) :: number
const DIRECTION_BUFFER_SIZE = buffer.len(DirectionsBuffer) :: number
const PROPERTIES_BUFFER_SIZE = buffer.len(PropertiesBuffer) :: number
const MAX_ENTITIES = COMPONENT_BUFFER_SIZE // COMPONENT_STRIDE :: number

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

-- Tables --
local EntityVersionTracker = {
	MaxEntities = MAX_ENTITIES,
}

-- Functions --
-- ============================================================================
-- 1. SHADOW BUFFER DIFFING & PER-COMPONENT VERSION TRACKING
-- ============================================================================

--[=[
	Scans active entities once per tick against the server-wide shadow copy to advance per-component versions.
	@param EntityCount number -- Current high-water entity index bound.
]=]
function EntityVersionTracker.SyncEntityVersions(EntityCount: number)
	const ClampedCount = math.clamp(math.floor(EntityCount), 0, MAX_ENTITIES) :: number
	for i = 1, ClampedCount do
		const FlagOffset = i - 1 :: number
		if buffer.readu8(ActiveFlags, FlagOffset) == 0 then
			continue
		end

		const VersionOffset = FlagOffset * 4 :: number
		const CompOffset = FlagOffset * COMPONENT_STRIDE :: number
		const DirOffset = FlagOffset * DIRECTION_STRIDE :: number
		const VisOffset = FlagOffset * VISUAL_STRIDE :: number
		const PropOffset = FlagOffset * PROPERTIES_STRIDE :: number
		const CurrentVer = buffer.readu32(VersionBuffer, VersionOffset) :: number

		if buffer.readu8(DirtyFlags, FlagOffset) == 2 or CurrentVer == 0 then
			const SpawnVer = CurrentVer + 1 :: number
			buffer.copy(ShadowPositions, CompOffset, PositionBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.copy(ShadowSizes, CompOffset, SizeBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.copy(ShadowDirections, DirOffset, DirectionsBuffer, DirOffset, DIRECTION_STRIDE)
			buffer.writeu32(ShadowVisuals, VisOffset, buffer.readu32(VisualBuffer, VisOffset))
			buffer.writeu32(ShadowProperties, PropOffset, buffer.readu32(PropertiesBuffer, PropOffset))
			buffer.writeu32(VersionBuffer, VersionOffset, SpawnVer)
			buffer.writeu32(PosVersions, VersionOffset, SpawnVer)
			buffer.writeu32(SizeVersions, VersionOffset, SpawnVer)
			buffer.writeu32(BasisVersions, VersionOffset, SpawnVer)
			buffer.writeu32(VisualVersions, VersionOffset, SpawnVer)
			buffer.writeu32(PropVersions, VersionOffset, SpawnVer)
			buffer.writeu8(DirtyFlags, FlagOffset, 0)
			continue
		end

		const NextVer = CurrentVer + 1 :: number
		local AnyChanged = false :: boolean

		if
			buffer.readu32(PositionBuffer, CompOffset) ~= buffer.readu32(ShadowPositions, CompOffset)
			or buffer.readu32(PositionBuffer, CompOffset + 4) ~= buffer.readu32(ShadowPositions, CompOffset + 4)
			or buffer.readu32(PositionBuffer, CompOffset + 8) ~= buffer.readu32(ShadowPositions, CompOffset + 8)
		then
			AnyChanged = true
			buffer.copy(ShadowPositions, CompOffset, PositionBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.writeu32(PosVersions, VersionOffset, NextVer)
		end

		if
			buffer.readu32(SizeBuffer, CompOffset) ~= buffer.readu32(ShadowSizes, CompOffset)
			or buffer.readu32(SizeBuffer, CompOffset + 4) ~= buffer.readu32(ShadowSizes, CompOffset + 4)
			or buffer.readu32(SizeBuffer, CompOffset + 8) ~= buffer.readu32(ShadowSizes, CompOffset + 8)
		then
			AnyChanged = true
			buffer.copy(ShadowSizes, CompOffset, SizeBuffer, CompOffset, COMPONENT_STRIDE)
			buffer.writeu32(SizeVersions, VersionOffset, NextVer)
		end

		for DirByte = 0, 32, 4 do
			if buffer.readu32(DirectionsBuffer, DirOffset + DirByte) ~= buffer.readu32(ShadowDirections, DirOffset + DirByte) then
				AnyChanged = true
				buffer.copy(ShadowDirections, DirOffset, DirectionsBuffer, DirOffset, DIRECTION_STRIDE)
				buffer.writeu32(BasisVersions, VersionOffset, NextVer)
				break
			end
		end

		if buffer.readu32(VisualBuffer, VisOffset) ~= buffer.readu32(ShadowVisuals, VisOffset) then
			AnyChanged = true
			buffer.writeu32(ShadowVisuals, VisOffset, buffer.readu32(VisualBuffer, VisOffset))
			buffer.writeu32(VisualVersions, VersionOffset, NextVer)
		end

		if buffer.readu32(PropertiesBuffer, PropOffset) ~= buffer.readu32(ShadowProperties, PropOffset) then
			AnyChanged = true
			buffer.writeu32(ShadowProperties, PropOffset, buffer.readu32(PropertiesBuffer, PropOffset))
			buffer.writeu32(PropVersions, VersionOffset, NextVer)
		end

		if AnyChanged then
			buffer.writeu32(VersionBuffer, VersionOffset, NextVer)
			buffer.writeu8(DirtyFlags, FlagOffset, 0)
		end
	end
end

--[=[
	Computes the 5-bit component delta mask for an entity relative to a player's SentVersion.
	@param EntityId number -- 1-based entity ID.
	@param SentVersion number -- Last entity version delivered to the player (0 if never sent).
	@return (number, number) -- (ComponentMask, CurrentEntityVersion).
]=]
function EntityVersionTracker.GetEntityDeltaMask(EntityId: number, SentVersion: number): (number, number)
	if EntityId ~= EntityId or EntityId < 1 or EntityId > MAX_ENTITIES or EntityId % 1 ~= 0 then
		return 0, 0
	end
	const VersionOffset = (EntityId - 1) * 4 :: number
	const CurrentVer = buffer.readu32(VersionBuffer, VersionOffset) :: number
	if SentVersion == 0 then
		return 0x1F, CurrentVer
	end
	if SentVersion >= CurrentVer then
		return 0, CurrentVer
	end

	local Mask = 0 :: number
	if buffer.readu32(PosVersions, VersionOffset) > SentVersion then Mask += 1 end
	if buffer.readu32(SizeVersions, VersionOffset) > SentVersion then Mask += 2 end
	if buffer.readu32(BasisVersions, VersionOffset) > SentVersion then Mask += 4 end
	if buffer.readu32(VisualVersions, VersionOffset) > SentVersion then Mask += 8 end
	if buffer.readu32(PropVersions, VersionOffset) > SentVersion then Mask += 16 end
	return Mask, CurrentVer
end

return EntityVersionTracker
