--!strict
--!native
--!optimize 2

--[=[
	@class ReplicationSenderHelper
	Event-driven outbound client replication router.
	Subscribes to domain events on EventBus, safely queues early startup requests
	before CoreEvents remotes finish resolving, and executes all client :FireServer calls.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const EventBus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("EventBus"))

-- Configs --
const Events = EventBus.Events

export type FireableRemote = {
	FireServer: (self: any, ...any) -> (),
}

export type ClientRemoteTargets = {
	ReplicateEvent: FireableRemote,
	TextureSyncEvent: FireableRemote,
	PlayerRegistryEvent: FireableRemote,
	ObserverStateEvent: FireableRemote,
	PlayerStateEvent: FireableRemote,
}

type QueuedOutboundMessage = {
	Topic: string,
	Payload: buffer?,
}

export type SenderState = {
	Remotes: ClientRemoteTargets?,
	Queue: { QueuedOutboundMessage },
	Disconnects: { () -> () },
}

-- Tables --
local ReplicationSenderHelper = {}

-- Functions --
-- ============================================================================
-- 1. EVENT-DRIVEN OUTBOUND CLIENT NETWORK SENDER
-- ============================================================================

--[=[
	Copies a transient buffer payload when startup queueing is required before remotes attach.
	@param Source buffer -- Source payload buffer.
	@return buffer -- Cloned immutable buffer snapshot.
]=]
function ReplicationSenderHelper.ClonePayloadBuffer(Source: buffer): buffer
	const Len = buffer.len(Source) :: number
	const Copy = buffer.create(Len) :: buffer
	buffer.copy(Copy, 0, Source, 0, Len)
	return Copy
end

--[=[
	Dispatches a single outbound topic directly to its mapped RemoteEvent / UnreliableRemoteEvent.
	@param Remotes ClientRemoteTargets -- Active client remote targets.
	@param Topic string -- Canonical EventBus outbound topic.
	@param Payload buffer? -- Optional binary buffer payload.
]=]
function ReplicationSenderHelper.DispatchToRemote(
	Remotes: ClientRemoteTargets,
	Topic: string,
	Payload: buffer?
)
	if Topic == Events.RequestInitialSync then
		Remotes.ReplicateEvent:FireServer()
		Remotes.TextureSyncEvent:FireServer()
		Remotes.PlayerRegistryEvent:FireServer()
	elseif Topic == Events.SendObserverState and Payload then
		Remotes.ObserverStateEvent:FireServer(Payload)
	elseif Topic == Events.SendPlayerState and Payload then
		Remotes.PlayerStateEvent:FireServer(Payload)
	end
end

--[=[
	Subscribes to all outbound client replication events on Bus and buffers early emissions until AttachRemotes runs.
	@param Bus EventBus.BusInstance -- Target EventBus instance.
	@return SenderState -- Active sender subscription and queue state.
]=]
function ReplicationSenderHelper.CreateSender(Bus: EventBus.BusInstance): SenderState
	const State: SenderState = {
		Remotes = nil,
		Queue = {},
		Disconnects = {},
	}

	table.insert(State.Disconnects, Bus.Subscribe(Events.RequestInitialSync, function()
		if State.Remotes then
			ReplicationSenderHelper.DispatchToRemote(State.Remotes, Events.RequestInitialSync, nil)
			return
		end
		table.insert(State.Queue, { Topic = Events.RequestInitialSync, Payload = nil })
	end))

	table.insert(State.Disconnects, Bus.Subscribe(Events.SendObserverState, function(Payload: buffer)
		if typeof(Payload) ~= "buffer" then
			return
		end
		if State.Remotes then
			ReplicationSenderHelper.DispatchToRemote(State.Remotes, Events.SendObserverState, Payload)
			return
		end
		table.insert(State.Queue, {
			Topic = Events.SendObserverState,
			Payload = ReplicationSenderHelper.ClonePayloadBuffer(Payload),
		})
	end))

	table.insert(State.Disconnects, Bus.Subscribe(Events.SendPlayerState, function(Payload: buffer)
		if typeof(Payload) ~= "buffer" then
			return
		end
		if State.Remotes then
			ReplicationSenderHelper.DispatchToRemote(State.Remotes, Events.SendPlayerState, Payload)
			return
		end
		table.insert(State.Queue, {
			Topic = Events.SendPlayerState,
			Payload = ReplicationSenderHelper.ClonePayloadBuffer(Payload),
		})
	end))

	return State
end

--[=[
	Binds resolved RemoteEvent targets to SenderState and flushes any queued startup messages in order.
	@param State SenderState -- Active sender state.
	@param Remotes ClientRemoteTargets -- Resolved client remote targets.
]=]
function ReplicationSenderHelper.AttachRemotes(State: SenderState, Remotes: ClientRemoteTargets)
	State.Remotes = Remotes
	for _, Item: QueuedOutboundMessage in ipairs(State.Queue) do
		ReplicationSenderHelper.DispatchToRemote(Remotes, Item.Topic, Item.Payload)
	end
	table.clear(State.Queue)
end

--[=[
	Disconnects all EventBus subscriptions owned by SenderState.
	@param State SenderState -- Active sender state to clean up.
]=]
function ReplicationSenderHelper.DisconnectSender(State: SenderState)
	for _, DisconnectFn: () -> () in ipairs(State.Disconnects) do
		DisconnectFn()
	end
	table.clear(State.Disconnects)
	table.clear(State.Queue)
	State.Remotes = nil
end

return ReplicationSenderHelper
