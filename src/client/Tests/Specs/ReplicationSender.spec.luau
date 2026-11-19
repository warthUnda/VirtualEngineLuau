--!strict
--!native
--!optimize 2

return function()
	const SpecEnv = getfenv() :: {
		describe: (string, () -> ()) -> (),
		it: (string, () -> ()) -> (),
		expect: (any) -> any,
	}
	const describe = SpecEnv.describe
	const it = SpecEnv.it
	const expect = SpecEnv.expect

	-- Services --
	const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder
	const ReplicationFolder =
		script.Parent.Parent.Parent:WaitForChild("Objects"):WaitForChild("Replication") :: Folder

	-- Libraries --
	const EventBus = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("EventBus"))
	const ReplicationSenderHelper = require(ReplicationFolder:WaitForChild("ReplicationSenderHelper"))

	describe("1. EventBus Pub/Sub & ReplicationSender Outbound Routing", function()
		it("should subscribe, emit, support Once, and disconnect cleanly on isolated EventBus instances", function()
			const Bus = EventBus.CreateBus()
			local CallCount = 0 :: number
			local LastValue = "" :: string

			const Disconnect = Bus.Subscribe("TestTopic", function(Val: string)
				CallCount += 1
				LastValue = Val
			end)

			local OnceCount = 0 :: number
			Bus.Once("TestTopic", function()
				OnceCount += 1
			end)

			Bus.Emit("TestTopic", "Alpha")
			Bus.Emit("TestTopic", "Bravo")
			expect(CallCount).to.equal(2)
			expect(OnceCount).to.equal(1)
			expect(LastValue).to.equal("Bravo")

			Disconnect()
			Bus.Emit("TestTopic", "Charlie")
			expect(CallCount).to.equal(2)
		end)

		it("should queue outbound events before remotes attach and route all client FireServer calls through ReplicationSender", function()
			const Bus = EventBus.CreateBus()
			const Events = EventBus.Events
			const Sender = ReplicationSenderHelper.CreateSender(Bus)

			local ReplicateReadyCalls = 0 :: number
			local TextureRequestCalls = 0 :: number
			local RegistryRequestCalls = 0 :: number
			local LastObserverBuf: buffer? = nil
			local LastPlayerBuf: buffer? = nil

			const ObsBuf = buffer.create(56)
			buffer.writef32(ObsBuf, 0, 12.5)
			const PlrBuf = buffer.create(20)
			buffer.writef32(PlrBuf, 0, -42.0)

			-- Emit before Remotes attach: must queue safely without dropping handshakes
			Bus.Emit(Events.RequestInitialSync)
			Bus.Emit(Events.SendPlayerState, PlrBuf)

			const MockRemotes = {
				ReplicateEvent = {
					FireServer = function(_Self: any)
						ReplicateReadyCalls += 1
					end,
				},
				TextureSyncEvent = {
					FireServer = function(_Self: any)
						TextureRequestCalls += 1
					end,
				},
				PlayerRegistryEvent = {
					FireServer = function(_Self: any)
						RegistryRequestCalls += 1
					end,
				},
				ObserverStateEvent = {
					FireServer = function(_Self: any, Payload: buffer)
						LastObserverBuf = Payload
					end,
				},
				PlayerStateEvent = {
					FireServer = function(_Self: any, Payload: buffer)
						LastPlayerBuf = Payload
					end,
				},
			}

			ReplicationSenderHelper.AttachDispatcher(Sender, function(Topic: string, Payload: buffer?)
				if Topic == Events.RequestInitialSync then
					MockRemotes.ReplicateEvent:FireServer()
					MockRemotes.TextureSyncEvent:FireServer()
					MockRemotes.PlayerRegistryEvent:FireServer()
				elseif Topic == Events.SendObserverState and Payload then
					MockRemotes.ObserverStateEvent:FireServer(Payload)
				elseif Topic == Events.SendPlayerState and Payload then
					MockRemotes.PlayerStateEvent:FireServer(Payload)
				end
			end)
			expect(ReplicateReadyCalls).to.equal(1)
			expect(TextureRequestCalls).to.equal(1)
			expect(RegistryRequestCalls).to.equal(1)
			expect(LastPlayerBuf ~= nil).to.equal(true)
			if LastPlayerBuf then
				expect(buffer.len(LastPlayerBuf)).to.equal(20)
				expect(buffer.readf32(LastPlayerBuf, 0)).to.equal(-42.0)
			end

			-- Emit after Dispatcher attaches: must dispatch immediately
			Bus.Emit(Events.SendObserverState, ObsBuf)
			expect(LastObserverBuf).to.equal(ObsBuf)

			ReplicationSenderHelper.DisconnectSender(Sender)
		end)
	end)
end
