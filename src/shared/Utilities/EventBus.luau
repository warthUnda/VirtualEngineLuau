--!strict
--!native
--!optimize 2

--[=[
	@class EventBus
	Maintainability-first publish/subscribe event bus decoupling domain systems
	(Player, Physics, Camera/Culling, TextureTable, ECSBuilder) from network RemoteEvents.
]=]

-- Configs --
export type EventHandler = (...any) -> ()

export type BusInstance = {
	Subscribe: (EventName: string, Handler: EventHandler) -> (() -> ()),
	Once: (EventName: string, Handler: EventHandler) -> (() -> ()),
	Emit: (EventName: string, ...any) -> (),
	ClearEvent: (EventName: string) -> (),
	ClearAll: () -> (),
}

-- Tables --
const Events = {
	-- Outbound Client -> ReplicationSender
	RequestInitialSync = "Replication.RequestInitialSync",
	SendObserverState = "Replication.SendObserverState",
	SendPlayerState = "Replication.SendPlayerState",

	-- Inbound ReplicationReceiver -> Client Domain
	EntityDeltaReceived = "Replication.EntityDeltaReceived",
	TextureRegistryReceived = "Replication.TextureRegistryReceived",
	PlayerRegistryReceived = "Replication.PlayerRegistryReceived",

	-- Server Domain <-> ServerReplicationGateway
	ServerTexturesChanged = "Server.TexturesChanged",
	ServerPlayerRegistryChanged = "Server.PlayerRegistryChanged",
	ServerPlayerRegistryReply = "Server.PlayerRegistryReply",
	ServerPlayerStateReceived = "Server.PlayerStateReceived",
	ServerPlayerRegistryRequested = "Server.PlayerRegistryRequested",
}

local EventBus = {
	Events = Events,
}

-- Functions --
-- ============================================================================
-- 1. ISOLATED & DEFAULT PUB/SUB EVENT BUS FACTORY
-- ============================================================================

--[=[
	Creates an isolated publish/subscribe EventBus instance (used both for the VM-wide default bus and unit tests).
	@return BusInstance -- Isolated pub/sub bus table.
]=]
function EventBus.CreateBus(): BusInstance
	local ListenersByEvent = {} :: { [string]: { EventHandler } }

	const Bus = {} :: BusInstance

	function Bus.Subscribe(EventName: string, Handler: EventHandler): () -> ()
		local List = ListenersByEvent[EventName]
		if not List then
			List = {}
			ListenersByEvent[EventName] = List
		end
		table.insert(List, Handler)

		local Connected = true :: boolean
		return function()
			if not Connected then
				return
			end
			Connected = false
			const ActiveList = ListenersByEvent[EventName]
			if not ActiveList then
				return
			end
			const FoundIndex = table.find(ActiveList, Handler)
			if FoundIndex then
				table.remove(ActiveList, FoundIndex)
			end
		end
	end

	function Bus.Once(EventName: string, Handler: EventHandler): () -> ()
		local Disconnect: (() -> ())? = nil
		Disconnect = Bus.Subscribe(EventName, function(...: any)
			if Disconnect then
				Disconnect()
				Disconnect = nil
			end
			Handler(...)
		end)
		return function()
			if Disconnect then
				Disconnect()
				Disconnect = nil
			end
		end
	end

	function Bus.Emit(EventName: string, ...: any)
		const ActiveList = ListenersByEvent[EventName]
		if not ActiveList or #ActiveList == 0 then
			return
		end
		const Snapshot = table.clone(ActiveList)
		for _, Handler: EventHandler in ipairs(Snapshot) do
			Handler(...)
		end
	end

	function Bus.ClearEvent(EventName: string)
		ListenersByEvent[EventName] = nil
	end

	function Bus.ClearAll()
		table.clear(ListenersByEvent)
	end

	return Bus
end

const DefaultBus = EventBus.CreateBus()

--[=[
	Subscribes a listener callback to an event topic on the default VM-wide EventBus.
	@param EventName string -- Name of the event topic.
	@param Handler EventHandler -- Event handler callback.
	@return () -> () -- Disconnect callback.
]=]
EventBus.Subscribe = DefaultBus.Subscribe

--[=[
	Subscribes a one-time listener callback to an event topic on the default VM-wide EventBus.
	@param EventName string -- Name of the event topic.
	@param Handler EventHandler -- One-time event handler callback.
	@return () -> () -- Disconnect callback.
]=]
EventBus.Once = DefaultBus.Once

--[=[
	Fires an event topic with arguments on the default VM-wide EventBus.
	@param EventName string -- Name of the event topic.
	@param ... any -- Arguments forwarded to listeners.
]=]
EventBus.Emit = DefaultBus.Emit

--[=[
	Removes all listeners registered for an event topic on the default VM-wide EventBus.
	@param EventName string -- Name of the event topic.
]=]
EventBus.ClearEvent = DefaultBus.ClearEvent

--[=[
	Removes all listeners across all event topics on the default VM-wide EventBus.
]=]
EventBus.ClearAll = DefaultBus.ClearAll

EventBus.DefaultBus = DefaultBus

return EventBus
