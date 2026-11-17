--!strict
--!native
--!optimize 2

--[=[
	@class ClientRemotes
	Single client-side directory inside client/Objects/Replication resolving all CoreEvents
	RemoteEvent and UnreliableRemoteEvent instances for ReplicationSender and ReplicationReceiver.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const OBSERVER_REMOTE_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const TEXTURE_SYNC_REMOTE_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string
const PLAYER_STATE_REMOTE_NAME = SystemsConfigs.PlayerStateRemoteEventName :: string
const PLAYER_REGISTRY_REMOTE_NAME = SystemsConfigs.PlayerRegistryRemoteEventName :: string

export type ClientRemoteSet = {
	ReplicateEvent: RemoteEvent,
	TextureSyncEvent: RemoteEvent,
	PlayerRegistryEvent: RemoteEvent,
	ObserverStateEvent: UnreliableRemoteEvent,
	PlayerStateEvent: UnreliableRemoteEvent,
}

-- Variables --
local CachedRemotes: ClientRemoteSet? = nil

-- Tables --
local ClientRemotes = {}

-- Functions --
-- ============================================================================
-- 1. CENTRALIZED CLIENT REMOTE EVENT RESOLUTION
-- ============================================================================

--[=[
	Waits for and caches all 5 replication RemoteEvent / UnreliableRemoteEvent instances in CoreEvents.
	@return ClientRemoteSet -- Resolved client remote event bundle.
]=]
function ClientRemotes.WaitForRemotes(): ClientRemoteSet
	if CachedRemotes then
		return CachedRemotes
	end

	const CoreEvents = ReplicatedStorage:WaitForChild(CORE_EVENTS_FOLDER_NAME) :: Folder
	const Resolved: ClientRemoteSet = {
		ReplicateEvent = CoreEvents:WaitForChild(REPLICATE_REMOTE_NAME) :: RemoteEvent,
		TextureSyncEvent = CoreEvents:WaitForChild(TEXTURE_SYNC_REMOTE_NAME) :: RemoteEvent,
		PlayerRegistryEvent = CoreEvents:WaitForChild(PLAYER_REGISTRY_REMOTE_NAME) :: RemoteEvent,
		ObserverStateEvent = CoreEvents:WaitForChild(OBSERVER_REMOTE_NAME) :: UnreliableRemoteEvent,
		PlayerStateEvent = CoreEvents:WaitForChild(PLAYER_STATE_REMOTE_NAME) :: UnreliableRemoteEvent,
	}
	CachedRemotes = Resolved
	return Resolved
end

return ClientRemotes
