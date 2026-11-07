local Players = game:GetService("Players")

local PlayerEye = require(game.ServerScriptService.Server.Objects.Replication.Core.PlayerEye)

local ReplicateEvent = game.ReplicatedStorage.CoreEvents.ReplicateEvent :: RemoteEvent

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		local DeltaBuffer, ByteCount = PlayerEye.CullObjects(Player)
		if DeltaBuffer and ByteCount > 0 then
			ReplicateEvent:FireClient(Player, DeltaBuffer, ByteCount)
		end
	end

	task.wait()
end
