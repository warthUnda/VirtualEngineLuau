--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const LOCAL_USER_ID = LocalPlayer.UserId :: number
-- The render controller runs inside an Actor, and every Actor owns an isolated Luau VM with its
-- own copy of each required ModuleScript. The receiver therefore has to live in that same Actor,
-- otherwise it fills the PlayerScripts copy of the ECS that nothing ever reads and the controller
-- keeps seeing an entity count of 0. It is cloned into the controller Actor by RenderBootstrap.
const SelfActor = script:GetActor() :: Actor?
if not SelfActor then
	return
end

const PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") :: PlayerScripts
const ReplicationFolder = PlayerScripts:WaitForChild("Client")
	:WaitForChild("Objects")
	:WaitForChild("Replication")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const ReplicationReceiverHelper = require(ReplicationFolder:WaitForChild("ReplicationReceiverHelper"))

-- Storage --
const RequireAny: any = require
const ObjectStorage = RequireAny(SelfActor:WaitForChild("ObjectStorage")) :: ECSMain.ECSStorage
const ReceiverState = ReplicationReceiverHelper.CreateReceiverState(ObjectStorage, LOCAL_USER_ID)

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string

-- Remote Events --
const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
const ReplicateEvent = CoreEvents:WaitForChild(REPLICATE_REMOTE_EVENT_NAME) :: RemoteEvent

-- ============================================================================
-- 1. LISTENER - MERGES REPLICATED DELTAS INTO THE LOCAL ECS
-- ============================================================================

ReplicateEvent.OnClientEvent:Connect(function(Payload: buffer)
	ReplicationReceiverHelper.IngestPayload(ReceiverState, Payload)
end)

-- Notify server that the Controller Actor's ReplicationReceiver listener is connected and ready for initial snapshot
ReplicateEvent:FireServer()
