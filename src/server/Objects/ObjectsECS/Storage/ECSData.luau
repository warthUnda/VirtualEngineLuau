local ECSData = {}

ECSData.ECSDataTable = {
	OrientationECSCount = 0,
	PositionECSCount = 0,
	VisualECSCount = 0,

	EntityECSCount = 0,
}

function ECSData.GetCounts(): { [string]: number }
	return ECSData.ECSDataTable
end

-- Call once per entity registered into the ECS to keep all component counts in sync.
-- Returns the 1-based id of the newly registered entity.
function ECSData.RegisterEntity(): number
	local Counts = ECSData.ECSDataTable

	Counts.EntityECSCount += 1
	Counts.OrientationECSCount += 1
	Counts.PositionECSCount += 1
	Counts.VisualECSCount += 1

	return Counts.EntityECSCount
end

return ECSData
