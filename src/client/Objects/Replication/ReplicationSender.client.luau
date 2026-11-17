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

-- Tables --
const SenderState = ReplicationSenderHelper.CreateSender(EventBus.DefaultBus)

-- Functions --
-- ============================================================================
-- 1. ATTACH RESOLVED REMOTES & FLUSH QUEUED DOMAIN EVENTS
-- ============================================================================

const Remotes = ClientRemotes.WaitForRemotes()
const UntypedRemotes: any = Remotes
const RemoteTargets = UntypedRemotes :: ReplicationSenderHelper.ClientRemoteTargets
ReplicationSenderHelper.AttachRemotes(SenderState, RemoteTargets)
