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
	const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	-- Storage --
	const ServerStorage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ViewCulling = require(
		SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling")
	)
	const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
	const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)
	const TestHelper = require(ServerScriptService.Server.Tests.TestHelper)

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const MASK_DESPAWN = 0x80 :: number

	describe("1. Replication Delta Culling & Free-List Despawns", function()
		it("should not re-send unchanged entities when leaving and re-entering the observer frustum", function()
			const EntityId = TestHelper.SpawnBoxEntity(ServerStorage, CFrame.new(0, 0, -25), Vector3.new(4, 4, 4), false)
			const MockPlayer = ({ Character = nil } :: any) :: Player

			const ForwardPayload = buffer.create(ViewCulling.ObserverPayloadBytes)
			buffer.writef32(ForwardPayload, 12, 0)
			buffer.writef32(ForwardPayload, 16, 0)
			buffer.writef32(ForwardPayload, 20, -1)
			buffer.writef32(ForwardPayload, 24, 0)
			buffer.writef32(ForwardPayload, 28, 1)
			buffer.writef32(ForwardPayload, 32, 0)
			buffer.writef32(ForwardPayload, 36, 1)
			buffer.writef32(ForwardPayload, 40, 0)
			buffer.writef32(ForwardPayload, 44, 0)
			buffer.writef32(ForwardPayload, 52, 70)

			const BackwardPayload = buffer.create(ViewCulling.ObserverPayloadBytes)
			buffer.writef32(BackwardPayload, 12, 0)
			buffer.writef32(BackwardPayload, 16, 0)
			buffer.writef32(BackwardPayload, 20, 1)
			buffer.writef32(BackwardPayload, 24, 0)
			buffer.writef32(BackwardPayload, 28, 1)
			buffer.writef32(BackwardPayload, 32, 0)
			buffer.writef32(BackwardPayload, 36, -1)
			buffer.writef32(BackwardPayload, 40, 0)
			buffer.writef32(BackwardPayload, 44, 0)
			buffer.writef32(BackwardPayload, 52, 70)

			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, ForwardPayload, ServerStorage.ECSData.GetCounts().EntityECSCount)
			local TotalInitialSent = 0 :: number
			for _ = 1, 64 do
				const BatchPacket = PlayerCuller.CullObjects(MockPlayer)
				if not BatchPacket then
					break
				end
				TotalInitialSent += buffer.readu16(BatchPacket, 0)
			end
			expect(TotalInitialSent >= 1).to.equal(true)

			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, BackwardPayload, ServerStorage.ECSData.GetCounts().EntityECSCount)
			for _ = 1, 64 do
				const AwayPacket = PlayerCuller.CullObjects(MockPlayer)
				if not AwayPacket then
					break
				end
			end

			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, ForwardPayload, ServerStorage.ECSData.GetCounts().EntityECSCount)
			const ReenterPacket = PlayerCuller.CullObjects(MockPlayer)
			expect(ReenterPacket == nil).to.equal(true)

			ServerStorage.PositionData.CreateLayout((EntityId - 1) * COMPONENT_STRIDE, 2, 0, -25)
			const DeltaPacket = PlayerCuller.CullObjects(MockPlayer)
			expect(DeltaPacket ~= nil).to.equal(true)
			if DeltaPacket then
				expect(buffer.readu16(DeltaPacket, 0)).to.equal(1)
				expect(buffer.readu16(DeltaPacket, 8)).to.equal(EntityId)
				expect(bit32.band(buffer.readu8(DeltaPacket, 10), 1)).to.equal(1)
			end

			ServerStorage.ECSData.DeleteEntity(EntityId)
			const DespawnPacket = PlayerCuller.CullObjects(MockPlayer)
			expect(DespawnPacket ~= nil).to.equal(true)
			if DespawnPacket then
				expect(buffer.readu16(DespawnPacket, 0)).to.equal(1)
				expect(buffer.readu16(DespawnPacket, 8)).to.equal(EntityId)
				expect(buffer.readu8(DespawnPacket, 10)).to.equal(MASK_DESPAWN)
			end

			PlayerFunctions.RemovePlayerState(MockPlayer)
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)

		it("should emit a compact 3-byte MASK_DESPAWN record for deleted middle slots without disturbing later entities", function()
			const FrontEntity = TestHelper.SpawnBoxEntity(ServerStorage, CFrame.new(0, 0, -25), Vector3.new(4, 4, 4), false)
			const BehindTailEntity = TestHelper.SpawnBoxEntity(ServerStorage, CFrame.new(0, 0, 80), Vector3.new(4, 4, 4), false)
			const MockPlayer = ({ Character = nil } :: any) :: Player

			const ForwardPayload = buffer.create(ViewCulling.ObserverPayloadBytes)
			buffer.writef32(ForwardPayload, 12, 0)
			buffer.writef32(ForwardPayload, 16, 0)
			buffer.writef32(ForwardPayload, 20, -1)
			buffer.writef32(ForwardPayload, 24, 0)
			buffer.writef32(ForwardPayload, 28, 1)
			buffer.writef32(ForwardPayload, 32, 0)
			buffer.writef32(ForwardPayload, 36, 1)
			buffer.writef32(ForwardPayload, 40, 0)
			buffer.writef32(ForwardPayload, 44, 0)
			buffer.writef32(ForwardPayload, 52, 70)

			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, ForwardPayload, ServerStorage.ECSData.GetCounts().EntityECSCount)
			for _ = 1, 64 do
				const InitPacket = PlayerCuller.CullObjects(MockPlayer)
				if not InitPacket then
					break
				end
			end

			ServerStorage.ECSData.DeleteEntity(FrontEntity)
			const DespawnPacket = PlayerCuller.CullObjects(MockPlayer)
			expect(DespawnPacket ~= nil).to.equal(true)
			if DespawnPacket then
				expect(buffer.readu16(DespawnPacket, 0)).to.equal(1)
				expect(buffer.readu16(DespawnPacket, 8)).to.equal(FrontEntity)
				expect(buffer.readu8(DespawnPacket, 10)).to.equal(MASK_DESPAWN)
				expect(buffer.len(DespawnPacket)).to.equal(11)
			end

			ServerStorage.ECSData.DeleteEntity(BehindTailEntity)
			PlayerFunctions.RemovePlayerState(MockPlayer)
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)
	end)
end
