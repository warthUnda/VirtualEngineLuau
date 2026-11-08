task.wait(0.3)
local ReplicateEvent = game.ReplicatedStorage.CoreEvents.ReplicateEvent :: RemoteEvent

local Size = Vector3.new(3, 4, 6)

export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	EntityECSCount: number,
}

ReplicateEvent.OnClientEvent:Connect(
	function(PositionBuffer: buffer, OrientationBuffer: buffer, ColorBuffer: buffer, ECSDataTable: ECSTable)
		local PosMemOffset = 0
        local OriMemOffset = 0
        local VisMemOffset = 0
		for i = 1, ECSDataTable.EntityECSCount do
			local PositionX = buffer.readf32(PositionBuffer, PosMemOffset)
			PosMemOffset += 4
            local PositionY = buffer.readf32(PositionBuffer, PosMemOffset)
            PosMemOffset += 4
            local PositionZ = buffer.readf32(PositionBuffer, PosMemOffset)
            PosMemOffset += 4

            local OrientationX = buffer.readf32(PositionBuffer, OriMemOffset)
            OriMemOffset +=
		end
	end
)
