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
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const EventBus = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("EventBus"))
	const ReplicationReceiverHelper = require(ReplicationFolder:WaitForChild("ReplicationReceiverHelper"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const VISUAL_STRIDE = SystemsConfigs.ECSVisualStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
	const HEADER_BYTES = 8 :: number
	const MASK_DESPAWN = 0x80 :: number

	describe("1. Client Replication Delta Ingestion & Free-List Despawns", function()
		it("should unpack binary delta payloads, reconstruct Right vector, and recycle despawned slots", function()
			const ClientStorage = ECSMain.CreateStorage(false)
			const ECSData = ClientStorage.ECSData
			const LocalPositionBuffer = ClientStorage.PositionData.GetData()
			const LocalDirectionsBuffer = ClientStorage.DirectionsData.GetData()
			const LocalVisualBuffer = ClientStorage.VisualData.GetData()
			const LocalPropertiesBuffer = ClientStorage.PropertiesData.GetData()

			const ReceiverState = ReplicationReceiverHelper.CreateReceiverState(ClientStorage, 501)

			const LinkedPlayerRecord = {
				ClassName = "PlayerService",
				UserId = 501,
				EntityId = 0,
			}
			ClientStorage.DynamicObjectsList.SetObjectAtId(1, LinkedPlayerRecord, nil)

			local function BuildBinaryPacket(
				UpdatedCount: number,
				WorldEntityCount: number,
				Entries: {
					{
						ServerId: number,
						Mask: number,
						Pos: Vector3?,
						VisualRGBA: number?,
						Look: Vector3?,
						Up: Vector3?,
						PropReg: number?,
					}
				}
			): buffer
				const Payload = buffer.create(HEADER_BYTES + UpdatedCount * 64)
				buffer.writeu16(Payload, 0, UpdatedCount)
				buffer.writeu16(Payload, 2, WorldEntityCount)
				buffer.writeu32(Payload, 4, 1)

				local WriteOffset = HEADER_BYTES
				for _, Entry in ipairs(Entries) do
					buffer.writeu16(Payload, WriteOffset, Entry.ServerId)
					buffer.writeu8(Payload, WriteOffset + 2, Entry.Mask)
					WriteOffset += 3
					if Entry.Mask == MASK_DESPAWN then
						continue
					end

					if bit32.band(Entry.Mask, 1) ~= 0 and Entry.Pos then
						buffer.writef32(Payload, WriteOffset, Entry.Pos.X)
						buffer.writef32(Payload, WriteOffset + 4, Entry.Pos.Y)
						buffer.writef32(Payload, WriteOffset + 8, Entry.Pos.Z)
						WriteOffset += COMPONENT_STRIDE
					end
					if bit32.band(Entry.Mask, 4) ~= 0 and Entry.Look and Entry.Up then
						buffer.writef32(Payload, WriteOffset, Entry.Look.X)
						buffer.writef32(Payload, WriteOffset + 4, Entry.Look.Y)
						buffer.writef32(Payload, WriteOffset + 8, Entry.Look.Z)
						buffer.writef32(Payload, WriteOffset + 12, Entry.Up.X)
						buffer.writef32(Payload, WriteOffset + 16, Entry.Up.Y)
						buffer.writef32(Payload, WriteOffset + 20, Entry.Up.Z)
						WriteOffset += 24
					end
					if bit32.band(Entry.Mask, 8) ~= 0 and Entry.VisualRGBA then
						buffer.writeu32(Payload, WriteOffset, Entry.VisualRGBA)
						WriteOffset += VISUAL_STRIDE
					end
					if bit32.band(Entry.Mask, 16) ~= 0 and Entry.PropReg then
						buffer.writeu32(Payload, WriteOffset, Entry.PropReg)
						WriteOffset += PROPERTIES_STRIDE
					end
				end

				const Trimmed = buffer.create(WriteOffset)
				buffer.copy(Trimmed, 0, Payload, 0, WriteOffset)
				return Trimmed
			end

			-- Packet 1: Spawn ServerId = 1 and ServerId = 2
			const Packet1 = BuildBinaryPacket(2, 2, {
				{
					ServerId = 1,
					Mask = 1 + 4 + 8 + 16,
					Pos = Vector3.new(15, 25, 35),
					Look = Vector3.new(0, 0, -1),
					Up = Vector3.new(0, 1, 0),
					VisualRGBA = 0xFF00AAFF,
					PropReg = ECSMain.PackProperties(true, true, true, 1, 0, 1),
				},
				{
					ServerId = 2,
					Mask = 1,
					Pos = Vector3.new(50, 60, 70),
				},
			})
			ReplicationReceiverHelper.IngestPayload(ReceiverState, Packet1)

			expect(ECSData.GetCounts().ActiveEntityCount).to.equal(2)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 1 * 4)).to.equal(1)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 2 * 4)).to.equal(2)
			expect(LinkedPlayerRecord.EntityId).to.equal(1)
			expect(ECSMain.CanEntityCollide(buffer.readu32(LocalPropertiesBuffer, 0))).to.equal(false)
			expect(buffer.readf32(LocalDirectionsBuffer, 24)).to.be.near(1, 1e-4)
			expect(buffer.readu32(LocalVisualBuffer, 0)).to.equal(0xFF00AAFF)

			-- Packet 2: Despawn first slot ServerId = 1 via MASK_DESPAWN and move ServerId = 2 (slot 2 stays at 2!)
			const Packet2 = BuildBinaryPacket(2, 2, {
				{ ServerId = 1, Mask = MASK_DESPAWN },
				{ ServerId = 2, Mask = 1, Pos = Vector3.new(99, 99, 99) },
			})
			ReplicationReceiverHelper.IngestPayload(ReceiverState, Packet2)

			expect(ECSData.GetCounts().ActiveEntityCount).to.equal(1)
			expect(ECSData.IsEntityActive(1)).to.equal(false)
			expect(ECSData.IsEntityActive(2)).to.equal(true)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 1 * 4)).to.equal(0)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 2 * 4)).to.equal(2)
			expect(buffer.readf32(LocalPositionBuffer, COMPONENT_STRIDE)).to.equal(99)

			-- Packet 3: Spawn ServerId = 3 -> must recycle freed local slot 1
			const Packet3 = BuildBinaryPacket(1, 3, {
				{ ServerId = 3, Mask = 1, Pos = Vector3.new(7, 8, 9) },
			})
			ReplicationReceiverHelper.IngestPayload(ReceiverState, Packet3)
			expect(buffer.readu32(ReceiverState.ClientSlotByServerId, 3 * 4)).to.equal(1)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(7)

			-- Verify inbound PlayerRegistryEvent routes onto EventBus without domain systems touching RemoteEvents
			const TestBus = EventBus.CreateBus()
			local ReceivedRegistryCount = 0 :: number
			TestBus.Subscribe(EventBus.Events.PlayerRegistryReceived, function(Entries: { any })
				ReceivedRegistryCount = #Entries
			end)
			ReplicationReceiverHelper.ForwardPlayerRegistry(TestBus, { { UserId = 501, DynamicId = 1 } })
			expect(ReceivedRegistryCount).to.equal(1)
		end)
	end)
end
