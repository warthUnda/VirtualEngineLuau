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

	const ReplicatedStorage = game:GetService("ReplicatedStorage")
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))

	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number

	describe("1. Client Replication Delta Ingestion", function()
		it("should unpack server delta buffers and map server IDs to persistent local client slots", function()
			const ClientStorage = ECSMain.CreateStorage(false)
			const ECSData = ClientStorage.ECSData
			const LocalPositionBuffer = ClientStorage.PositionData.GetData()
			const LocalVisualBuffer = ClientStorage.VisualData.GetData()

			const ClientSlotByServerId = buffer.create((100 + 1) * 4)

			-- Create a synthetic replication batch for 2 server entities (ServerId = 10 and 20)
			const DeltaPositions = buffer.create(COMPONENT_STRIDE * 2)
			const _DeltaOrientations = buffer.create(COMPONENT_STRIDE * 2)
			const DeltaVisuals = buffer.create(COMPONENT_STRIDE * 2)
			const _DeltaSizes = buffer.create(COMPONENT_STRIDE * 2)
			const _DeltaDirections = buffer.create(DIRECTION_STRIDE * 2)

			-- Entity 1: ServerId = 10, Pos = (15, 25, 35)
			buffer.writef32(DeltaPositions, 0, 15)
			buffer.writef32(DeltaPositions, 4, 25)
			buffer.writef32(DeltaPositions, 8, 35)
			buffer.writeu32(DeltaVisuals, 4, 10) -- Embedded ServerId = 10

			-- Entity 2: ServerId = 20, Pos = (50, 60, 70)
			buffer.writef32(DeltaPositions, COMPONENT_STRIDE, 50)
			buffer.writef32(DeltaPositions, COMPONENT_STRIDE + 4, 60)
			buffer.writef32(DeltaPositions, COMPONENT_STRIDE + 8, 70)
			buffer.writeu32(DeltaVisuals, COMPONENT_STRIDE + 4, 20) -- Embedded ServerId = 20

			-- Ingest batch 1 (simulating ReplicationReceiver logic)
			local LocalCount = ECSData.GetCounts().EntityECSCount
			for i = 1, 2 do
				const ReadOffset = (i - 1) * COMPONENT_STRIDE
				const ServerId = buffer.readu32(DeltaVisuals, ReadOffset + 4)
				local TargetSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4)

				if TargetSlot == 0 then
					LocalCount = ECSData.RegisterEntity()
					TargetSlot = LocalCount
					buffer.writeu32(ClientSlotByServerId, ServerId * 4, TargetSlot)
				end

				const WriteOffset = (TargetSlot - 1) * COMPONENT_STRIDE
				buffer.copy(LocalPositionBuffer, WriteOffset, DeltaPositions, ReadOffset, COMPONENT_STRIDE)
				buffer.copy(LocalVisualBuffer, WriteOffset, DeltaVisuals, ReadOffset, COMPONENT_STRIDE)
			end

			expect(LocalCount).to.equal(2)
			expect(buffer.readu32(ClientSlotByServerId, 10 * 4)).to.equal(1)
			expect(buffer.readu32(ClientSlotByServerId, 20 * 4)).to.equal(2)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(15)
			expect(buffer.readf32(LocalPositionBuffer, COMPONENT_STRIDE)).to.equal(50)

			-- Now ingest batch 2: updating ServerId 10 with new position (99, 99, 99)
			buffer.writef32(DeltaPositions, 0, 99)
			buffer.writef32(DeltaPositions, 4, 99)
			buffer.writef32(DeltaPositions, 8, 99)

			const ReadOffset = 0
			const ServerId = buffer.readu32(DeltaVisuals, ReadOffset + 4)
			const ExistingSlot = buffer.readu32(ClientSlotByServerId, ServerId * 4)

			expect(ExistingSlot).to.equal(1) -- Must reuse existing slot 1!

			const WriteOffset = (ExistingSlot - 1) * COMPONENT_STRIDE
			buffer.copy(LocalPositionBuffer, WriteOffset, DeltaPositions, ReadOffset, COMPONENT_STRIDE)

			-- Entity count must still be 2, and slot 1 position must be updated
			expect(ECSData.GetCounts().EntityECSCount).to.equal(2)
			expect(buffer.readf32(LocalPositionBuffer, 0)).to.equal(99)
		end)
	end)
end
