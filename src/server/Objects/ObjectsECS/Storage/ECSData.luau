--!native
--!optimize 2

local Storage = script.Parent
local PositionBuffer = require(Storage:WaitForChild("PositionData")).GetData() :: buffer
local OrientationBuffer = require(Storage:WaitForChild("OrientationData")).GetData() :: buffer
local VisualBuffer = require(Storage:WaitForChild("VisualData")).GetData() :: buffer
local SizeBuffer = require(Storage:WaitForChild("SizeData")).GetData() :: buffer
local DirectionsBuffer = require(Storage:WaitForChild("DirectionsData")).GetData() :: buffer

const COMPONENT_STRIDE = 12 :: number
const DIRECTION_STRIDE = 36 :: number

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
	local Counts = ECSData.ECSDataTable
	local NextCount = Counts.EntityECSCount + 1

	Counts.EntityECSCount = NextCount
	Counts.OrientationECSCount = NextCount
	Counts.PositionECSCount = NextCount
	Counts.VisualECSCount = NextCount
	Counts.SizeECSCount = NextCount
	Counts.DirectionsECSCount = NextCount

	return NextCount
end

function ECSData.DeleteEntity(EntityId: number)
	local Counts = ECSData.ECSDataTable
	local LastEntityId = Counts.EntityECSCount

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

	local NewCount = LastEntityId - 1
	Counts.EntityECSCount = NewCount
	Counts.OrientationECSCount = NewCount
	Counts.PositionECSCount = NewCount
	Counts.VisualECSCount = NewCount
	Counts.SizeECSCount = NewCount
	Counts.DirectionsECSCount = NewCount
end

return ECSData
