--!strict
--!native
--!optimize 2

--[=[
	@class ReplicationSender
	Sole outbound client network sender running inside the Controller Actor VM.
	Subscribes to domain events on EventBus before yielding on RemoteEvents so startup
	handshakes and state updates are never dropped, and executes all client :FireServer calls.
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
const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
const ReplicationFolder =
	PlayerScripts:WaitForChild("Client"):WaitForChild("Objects"):WaitForChild("Replication") :: Folder

-- Libraries --
const EventBus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("EventBus"))
const ClientRemotes = require(ReplicationFolder:WaitForChild("ClientRemotes"))
const ReplicationSenderHelper = require(ReplicationFolder:WaitForChild("ReplicationSenderHelper"))

-- Configs --
const Events = EventBus.Events

-- Tables --
const SenderState = ReplicationSenderHelper.CreateSender(EventBus.DefaultBus)

-- Functions --
-- ============================================================================
-- 1. ATTACH RESOLVED REMOTES & ROUTE OUTBOUND EVENTBUS TOPICS -> :FIRESERVER
-- ============================================================================

const Remotes = ClientRemotes.WaitForRemotes()
ReplicationSenderHelper.AttachDispatcher(SenderState, function(Topic: string, Payload: buffer?)
	if Topic == Events.RequestInitialSync then
		Remotes.ReplicateEvent:FireServer()
		Remotes.TextureSyncEvent:FireServer()
		Remotes.PlayerRegistryEvent:FireServer()
	elseif Topic == Events.SendObserverState and Payload then
		Remotes.ObserverStateEvent:FireServer(Payload)
	elseif Topic == Events.SendPlayerState and Payload then
		Remotes.PlayerStateEvent:FireServer(Payload)
	end
end)
