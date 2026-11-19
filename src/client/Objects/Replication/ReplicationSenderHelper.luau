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

export type OutboundDispatcher = (Topic: string, Payload: buffer?) -> ()

type QueuedOutboundMessage = {
	Topic: string,
	Payload: buffer?,
}

export type SenderState = {
	Dispatcher: OutboundDispatcher?,
	Queue: { QueuedOutboundMessage },
	Disconnects: { () -> () },
}

-- Tables --
local ReplicationSenderHelper = {}

-- Functions --
-- ============================================================================
-- 1. EVENT-DRIVEN OUTBOUND CLIENT NETWORK QUEUE & SUBSCRIPTIONS
-- ============================================================================

--[=[
	Copies a transient buffer payload when startup queueing is required before a dispatcher attaches.
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
	Subscribes to all outbound client replication events on Bus and buffers early emissions until AttachDispatcher runs.
	@param Bus EventBus.BusInstance -- Target EventBus instance.
	@return SenderState -- Active sender subscription and queue state.
]=]
function ReplicationSenderHelper.CreateSender(Bus: EventBus.BusInstance): SenderState
	const State: SenderState = {
		Dispatcher = nil,
		Queue = {},
		Disconnects = {},
	}

	table.insert(State.Disconnects, Bus.Subscribe(Events.RequestInitialSync, function()
		if State.Dispatcher then
			State.Dispatcher(Events.RequestInitialSync, nil)
			return
		end
		table.insert(State.Queue, { Topic = Events.RequestInitialSync, Payload = nil })
	end))

	table.insert(State.Disconnects, Bus.Subscribe(Events.SendObserverState, function(Payload: buffer)
		if typeof(Payload) ~= "buffer" then
			return
		end
		if State.Dispatcher then
			State.Dispatcher(Events.SendObserverState, Payload)
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
		if State.Dispatcher then
			State.Dispatcher(Events.SendPlayerState, Payload)
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
	Binds an outbound topic dispatcher callback to SenderState and flushes any queued startup messages in order.
	@param State SenderState -- Active sender state.
	@param Dispatcher OutboundDispatcher -- Callback routing `(Topic, Payload)` to `:FireServer`.
]=]
function ReplicationSenderHelper.AttachDispatcher(State: SenderState, Dispatcher: OutboundDispatcher)
	State.Dispatcher = Dispatcher
	for _, Item: QueuedOutboundMessage in ipairs(State.Queue) do
		Dispatcher(Item.Topic, Item.Payload)
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
	State.Dispatcher = nil
end

return ReplicationSenderHelper
