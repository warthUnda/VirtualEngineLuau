--!strict
--!native
--!optimize 2

--[=[
	@class ReplicatorExecuter
	Server replication driver broadcasting delta visibility snapshots to connected
	clients on a fixed tick interval.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)
const ServerReplicationGateway = require(script.Parent.ServerReplicationGateway)

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData

-- Configs --
const REPLICATION_TICK_INTERVAL = SystemsConfigs.ReplicationTickInterval :: number

-- Remote Events --
const Remotes = ServerReplicationGateway.InitializeGateway()
const ReplicateRemote = Remotes.ReplicateRemote

-- Functions --
-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	const EntityCount = ECSData.GetCounts().EntityECSCount :: number
	if EntityCount > 0 then
		PlayerFunctions.SyncEntityVersions(EntityCount)
	end

	for _, TargetPlayer: Player in ipairs(Players:GetPlayers()) do
		if not PlayerFunctions.IsClientReady(TargetPlayer) then
			continue
		end

		const DeltaPacket = PlayerCuller.CullObjects(TargetPlayer, true)
		if DeltaPacket then
			ReplicateRemote:FireClient(TargetPlayer, DeltaPacket)
		end
	end

	task.wait(REPLICATION_TICK_INTERVAL)
end
