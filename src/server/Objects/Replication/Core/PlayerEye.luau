--!native
--!optimize 2

-- Services --
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const StorageFolder = ServerScriptService.Server.Objects.ObjectsECS.Storage :: Folder

-- Modules --
const PositionData = require(StorageFolder.PositionData) :: ModuleScript
const OrientationData = require(StorageFolder.OrientationData) :: ModuleScript
const VisualData = require(StorageFolder.VisualData) :: ModuleScript
const SizeData = require(StorageFolder.SizeData) :: ModuleScript
const DirectionsData = require(StorageFolder.DirectionsData) :: ModuleScript
const ECSData = require(StorageFolder.ECSData) :: ModuleScript

-- Configs --
const RENDER_DISTANCE = 200 :: number
const RENDER_DISTANCE_SQUARED = RENDER_DISTANCE * RENDER_DISTANCE :: number
const COMPONENT_STRIDE = 12 :: number -- 3 x f32 per entity (position, orientation, visual, size)
const DIRECTION_STRIDE = 36 :: number -- look + up + right, 3 x f32 each

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

local PlayerEye = {}

-- ============================================================================
-- 1. CULLING FUNCTIONS - DISTANCE CULLING FOR REPLICATION
-- ============================================================================

-- Returns the position, orientation, visual, size and directions components of every entity
-- within RENDER_DISTANCE of the player, packed with the ECS strides, along with the counts
-- describing the snapshot. Entities further away are culled.
function PlayerEye.CullObjects(PlayerObject: Player): (buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?)
	const Character = PlayerObject.Character :: Model?
	if not Character then
		return nil, nil, nil, nil, nil, nil
	end

	const Head = Character:FindFirstChild("Head") :: Instance?
	if not Head or not Head:IsA("BasePart") then
		return nil, nil, nil, nil, nil, nil
	end

	const HeadPosition = Head.Position :: Vector3
	const HeadX: number, HeadY: number, HeadZ: number = HeadPosition.X, HeadPosition.Y, HeadPosition.Z
	const EntityCount = ECSData.GetCounts().EntityECSCount :: number

	const ComponentDeltaSize = EntityCount * COMPONENT_STRIDE :: number
	const DeltaPositions = buffer.create(ComponentDeltaSize) :: buffer
	const DeltaOrientations = buffer.create(ComponentDeltaSize) :: buffer
	const DeltaVisuals = buffer.create(ComponentDeltaSize) :: buffer
	const DeltaSizes = buffer.create(ComponentDeltaSize) :: buffer
	const DeltaDirections = buffer.create(EntityCount * DIRECTION_STRIDE) :: buffer

	local WriteOffset = 0 :: number
	local DirectionWriteOffset = 0 :: number

	for i = 1, EntityCount do
		const ReadOffset = (i - 1) * COMPONENT_STRIDE :: number
		const DirectionReadOffset = (i - 1) * DIRECTION_STRIDE :: number

		const Dx = buffer.readf32(PositionBuffer, ReadOffset) - HeadX :: number
		const Dy = buffer.readf32(PositionBuffer, ReadOffset + 4) - HeadY :: number
		const Dz = buffer.readf32(PositionBuffer, ReadOffset + 8) - HeadZ :: number

		if Dx * Dx + Dy * Dy + Dz * Dz >= RENDER_DISTANCE_SQUARED then
			continue
		end

		buffer.copy(DeltaPositions, WriteOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaOrientations, WriteOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaVisuals, WriteOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaSizes, WriteOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaDirections, DirectionWriteOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)

		WriteOffset += COMPONENT_STRIDE
		DirectionWriteOffset += DIRECTION_STRIDE
	end

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

return PlayerEye
