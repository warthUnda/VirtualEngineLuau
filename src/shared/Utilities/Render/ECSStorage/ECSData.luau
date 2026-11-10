--!native
--!optimize 2

-- Static References --
const Storage = script.Parent :: Folder

-- Modules --
const PositionData = require(Storage:WaitForChild("PositionData")) :: ModuleScript
const OrientationData = require(Storage:WaitForChild("OrientationData")) :: ModuleScript
const VisualData = require(Storage:WaitForChild("VisualData")) :: ModuleScript
const SizeData = require(Storage:WaitForChild("SizeData")) :: ModuleScript
const DirectionsData = require(Storage:WaitForChild("DirectionsData")) :: ModuleScript

-- Configs --
const COMPONENT_STRIDE = 12 :: number
const DIRECTION_STRIDE = 36 :: number

-- Buffers
const PositionBuffer = PositionData.GetData() :: buffer
const OrientationBuffer = OrientationData.GetData() :: buffer
const VisualBuffer = VisualData.GetData() :: buffer
const SizeBuffer = SizeData.GetData() :: buffer
const DirectionsBuffer = DirectionsData.GetData() :: buffer

local ECSData = {}

ECSData.ECSDataTable = {
	OrientationECSCount = 0,
	PositionECSCount = 0,
	VisualECSCount = 0,
	SizeECSCount = 0,
	DirectionsECSCount = 0,

	EntityECSCount = 0,
}

function ECSData.GetCounts(): { [string]: number }
	return ECSData.ECSDataTable
end

-- Call once per entity registered into the ECS to keep all component counts in sync.
-- Returns the 1-based id of the newly registered entity.
function ECSData.RegisterEntity(): number
	const Counts = ECSData.ECSDataTable
	const NextCount = Counts.EntityECSCount + 1 :: number

	Counts.EntityECSCount = NextCount
	Counts.OrientationECSCount = NextCount
	Counts.PositionECSCount = NextCount
	Counts.VisualECSCount = NextCount
	Counts.SizeECSCount = NextCount
	Counts.DirectionsECSCount = NextCount

	return NextCount
end

function ECSData.SetEntityCount(EntityCount: number)
	const Counts = ECSData.ECSDataTable

	Counts.EntityECSCount = EntityCount
	Counts.OrientationECSCount = EntityCount
	Counts.PositionECSCount = EntityCount
	Counts.VisualECSCount = EntityCount
	Counts.SizeECSCount = EntityCount
	Counts.DirectionsECSCount = EntityCount
end

function ECSData.DeleteEntity(EntityId: number)
	const Counts = ECSData.ECSDataTable
	const LastEntityId = Counts.EntityECSCount :: number

	if EntityId < 1 or EntityId > LastEntityId then
		return
	end

	if EntityId ~= LastEntityId then
		const TargetOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const LastOffset = (LastEntityId - 1) * COMPONENT_STRIDE :: number

		buffer.copy(PositionBuffer, TargetOffset, PositionBuffer, LastOffset, COMPONENT_STRIDE)
		buffer.copy(OrientationBuffer, TargetOffset, OrientationBuffer, LastOffset, COMPONENT_STRIDE)
		buffer.copy(VisualBuffer, TargetOffset, VisualBuffer, LastOffset, COMPONENT_STRIDE)
		buffer.copy(SizeBuffer, TargetOffset, SizeBuffer, LastOffset, COMPONENT_STRIDE)

		const TargetDirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const LastDirOffset = (LastEntityId - 1) * DIRECTION_STRIDE :: number
		buffer.copy(DirectionsBuffer, TargetDirOffset, DirectionsBuffer, LastDirOffset, DIRECTION_STRIDE)
	end

	const NewCount = LastEntityId - 1 :: number
	Counts.EntityECSCount = NewCount
	Counts.OrientationECSCount = NewCount
	Counts.PositionECSCount = NewCount
	Counts.VisualECSCount = NewCount
	Counts.SizeECSCount = NewCount
	Counts.DirectionsECSCount = NewCount
end

return ECSData
