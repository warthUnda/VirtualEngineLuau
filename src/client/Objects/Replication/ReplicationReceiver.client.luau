--!strict
--!native
--!optimize 2

--[=[
	@class ReplicationReceiver
	Sole inbound client network receiver running inside the Controller Actor VM.
	Listens to OnClientEvent across CoreEvents remotes and publishes domain updates
	into local ECS storage, TextureTable, and EventBus—performing zero outbound sends.
]=]

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

const LocalPlayer = Players.LocalPlayer :: Player
const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
const ReplicationFolder =
	PlayerScripts:WaitForChild("Client"):WaitForChild("Objects"):WaitForChild("Replication") :: Folder

-- Libraries --
const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
const EventBus = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("EventBus"))
const ClientRemotes = require(ReplicationFolder:WaitForChild("ClientRemotes"))
const ReplicationReceiverHelper = require(ReplicationFolder:WaitForChild("ReplicationReceiverHelper"))

-- Storage --
const RequireAny: any = require
const ObjectStorage = RequireAny(SelfActor:WaitForChild("ObjectStorage")) :: ECSMain.ECSStorage

-- Configs --
const LOCAL_USER_ID = LocalPlayer.UserId :: number
const Events = EventBus.Events

-- Tables --
const ReceiverState = ReplicationReceiverHelper.CreateReceiverState(ObjectStorage, LOCAL_USER_ID)

-- Functions --
-- ============================================================================
-- 1. INBOUND ONCLIENTEVENT LISTENERS -> DOMAIN / EVENTBUS DISPATCH
-- ============================================================================

const Remotes = ClientRemotes.WaitForRemotes()

Remotes.ReplicateEvent.OnClientEvent:Connect(function(Payload: buffer)
	EventBus.Emit(Events.EntityDeltaReceived, Payload)
	ReplicationReceiverHelper.IngestPayload(ReceiverState, Payload)
end)

Remotes.TextureSyncEvent.OnClientEvent:Connect(function(Entries: any)
	EventBus.Emit(Events.TextureRegistryReceived, Entries)
	ReplicationReceiverHelper.ApplySyncedTextures(Entries)
end)

Remotes.PlayerRegistryEvent.OnClientEvent:Connect(function(Entries: any)
	ReplicationReceiverHelper.ForwardPlayerRegistry(EventBus.DefaultBus, Entries)
end)

-- Request initial world, texture, and player registry snapshots via EventBus -> ReplicationSender
EventBus.Emit(Events.RequestInitialSync)
