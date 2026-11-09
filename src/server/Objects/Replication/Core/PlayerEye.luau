local PlayerEye = {}

local RENDER_DISTANCE = 200 :: number
local COMPONENT_STRIDE = 12 :: number -- 3 x f32 per entity (position, orientation, visual, size)
local DIRECTION_STRIDE = 36 :: number -- look + up + right, 3 x f32 each

local PositionData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.PositionData)
local OrientationData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.OrientationData)
local VisualData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.VisualData)
local SizeData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.SizeData)
local DirectionsData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.DirectionsData)
local ECSData = require(game.ServerScriptService.Server.Objects.ObjectsECS.Storage.ECSData)

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	EntityECSCount: number,
}

-- Returns the position, orientation, visual, size and directions components of every entity
-- within RENDER_DISTANCE of the player, packed with the ECS strides, along with the counts
-- describing the snapshot. Entities further away are culled.
function PlayerEye.CullObjects(PlayerObject: Player): (buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?)
	local Character = PlayerObject.Character
	if not Character then
		return nil, nil, nil, nil, nil, nil
	end

	local Head = Character:FindFirstChild("Head")
	if not Head or not Head:IsA("BasePart") then
		return nil, nil, nil, nil, nil, nil
	end

	local HeadPosition = Head.Position :: Vector3
	local EntityCount = ECSData.GetCounts().EntityECSCount :: number
	local PositionBuffer = PositionData.GetData() :: buffer
	local OrientationBuffer = OrientationData.GetData() :: buffer
	local VisualBuffer = VisualData.GetData() :: buffer
	local SizeBuffer = SizeData.GetData() :: buffer
	local DirectionsBuffer = DirectionsData.GetData() :: buffer

	local ComponentDeltaSize = EntityCount * COMPONENT_STRIDE :: number
	local DeltaPositions = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaOrientations = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaVisuals = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaSizes = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaDirections = buffer.create(EntityCount * DIRECTION_STRIDE) :: buffer

	local WriteOffset = 0 :: number
	local DirectionWriteOffset = 0 :: number

	for i = 1, EntityCount do
		local ReadOffset = (i - 1) * COMPONENT_STRIDE :: number
		local DirectionReadOffset = (i - 1) * DIRECTION_STRIDE :: number

		local X = buffer.readf32(PositionBuffer, ReadOffset) :: number
		local Y = buffer.readf32(PositionBuffer, ReadOffset + 4) :: number
		local Z = buffer.readf32(PositionBuffer, ReadOffset + 8) :: number

		if (Vector3.new(X, Y, Z) - HeadPosition).Magnitude >= RENDER_DISTANCE then
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

	local VisibleCount: number = WriteOffset // COMPONENT_STRIDE

	local Counts: ECSTable = {
		OrientationECSCount = VisibleCount,
		PositionECSCount = VisibleCount,
		VisualECSCount = VisibleCount,
		SizeECSCount = VisibleCount,
		DirectionsECSCount = VisibleCount,
		EntityECSCount = VisibleCount,
	}

	return DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts
end

-- Same as CullObjects, but culls against the renderer's camera position instead of the
-- player's head. Reads every entity out of the ECS buffers, keeps only the ones whose
-- distance to the camera is under RENDER_DISTANCE (using the distance formula), and packs
-- the survivors back into the component/direction buffers.
function PlayerEye.CullObjectsByCamera(): (buffer?, buffer?, buffer?, buffer?, buffer?, ECSTable?)
	local EntityCount = ECSData.GetCounts().EntityECSCount :: number
	local PositionBuffer = PositionData.GetData() :: buffer
	local OrientationBuffer = OrientationData.GetData() :: buffer
	local VisualBuffer = VisualData.GetData() :: buffer
	local SizeBuffer = SizeData.GetData() :: buffer
	local DirectionsBuffer = DirectionsData.GetData() :: buffer

	local ComponentDeltaSize = EntityCount * COMPONENT_STRIDE :: number
	local DeltaPositions = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaOrientations = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaVisuals = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaSizes = buffer.create(ComponentDeltaSize) :: buffer
	local DeltaDirections = buffer.create(EntityCount * DIRECTION_STRIDE) :: buffer

	local WriteOffset = 0 :: number
	local DirectionWriteOffset = 0 :: number
	local RenderDistanceSquared = RENDER_DISTANCE * RENDER_DISTANCE :: number

	for i = 1, EntityCount do
		local ReadOffset = (i - 1) * COMPONENT_STRIDE :: number
		local DirectionReadOffset = (i - 1) * DIRECTION_STRIDE :: number

		local X = buffer.readf32(PositionBuffer, ReadOffset) :: number
		local Y = buffer.readf32(PositionBuffer, ReadOffset + 4) :: number
		local Z = buffer.readf32(PositionBuffer, ReadOffset + 8) :: number

		-- Distance formula: sqrt((X - CamX)^2 + (Y - CamY)^2 + (Z - CamZ)^2). aka petagoras
		-- Both sides are squared so the sqrt is skipped for the comparison.

		buffer.copy(DeltaPositions, WriteOffset, PositionBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaOrientations, WriteOffset, OrientationBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaVisuals, WriteOffset, VisualBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaSizes, WriteOffset, SizeBuffer, ReadOffset, COMPONENT_STRIDE)
		buffer.copy(DeltaDirections, DirectionWriteOffset, DirectionsBuffer, DirectionReadOffset, DIRECTION_STRIDE)

		WriteOffset += COMPONENT_STRIDE
		DirectionWriteOffset += DIRECTION_STRIDE
	end

	local VisibleCount: number = WriteOffset // COMPONENT_STRIDE

	local Counts: ECSTable = {
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
