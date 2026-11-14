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
	const ServerScriptService = game:GetService("ServerScriptService")
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ViewCulling = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling"))
	const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
	const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)
	const ServerStorage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
	const TestHelper = require(ServerScriptService.Server.Tests.TestHelper)

	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

	describe("1. Frustum & View Cone Culling", function()
		it("should cull entities behind or beyond near/far clipping boundaries", function()
			const PosBuf = buffer.create(COMPONENT_STRIDE * 2)
			const SizeBuf = buffer.create(COMPONENT_STRIDE * 2)

			-- Entity 1: Far behind near plane (e.g. at -50 when camera looks forward)
			buffer.writef32(PosBuf, 0, 0)
			buffer.writef32(PosBuf, 4, 0)
			buffer.writef32(PosBuf, 8, 50000) -- Beyond Far clip
			buffer.writef32(SizeBuf, 0, 2)
			buffer.writef32(SizeBuf, 4, 2)
			buffer.writef32(SizeBuf, 8, 2)

			const IsCulled = ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)
			expect(IsCulled).to.equal(true)
		end)

		it("should pass entities directly in front of the observer cone", function()
			const PosBuf = buffer.create(COMPONENT_STRIDE)
			const SizeBuf = buffer.create(COMPONENT_STRIDE)

			-- Entity at (0, 0, -20) (in default look direction -Z)
			buffer.writef32(PosBuf, 0, 0)
			buffer.writef32(PosBuf, 4, 0)
			buffer.writef32(PosBuf, 8, -20)
			buffer.writef32(SizeBuf, 0, 4)
			buffer.writef32(SizeBuf, 4, 4)
			buffer.writef32(SizeBuf, 8, 4)

			const IsCulled = ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)
			expect(IsCulled).to.equal(false)
		end)

		it("should update observer frustum and player replication state without a Character or Humanoid", function()
			const MockPlayer = ({ Character = nil } :: any) :: Player
			const Payload = buffer.create(ViewCulling.ObserverPayloadBytes)
			buffer.writef32(Payload, 0, 100)
			buffer.writef32(Payload, 4, 20)
			buffer.writef32(Payload, 8, -50)
			buffer.writef32(Payload, 12, 1)
			buffer.writef32(Payload, 16, 0)
			buffer.writef32(Payload, 20, 0)
			buffer.writef32(Payload, 24, 0)
			buffer.writef32(Payload, 28, 1)
			buffer.writef32(Payload, 32, 0)
			buffer.writef32(Payload, 36, 0)
			buffer.writef32(Payload, 40, 0)
			buffer.writef32(Payload, 44, 1)
			buffer.writef32(Payload, 48, 0)
			buffer.writef32(Payload, 52, 70)

			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, Payload, 1)
			const State = PlayerFunctions.GetOrCreatePlayerState(MockPlayer, 1)
			expect(State.ClientSynced).to.equal(true)
			expect(State.OriginX).to.be.near(100, 1e-4)

			ViewCulling.UpdateObserverFromVectors(
				State.OriginX,
				State.OriginY,
				State.OriginZ,
				State.LookX,
				State.LookY,
				State.LookZ,
				State.UpX,
				State.UpY,
				State.UpZ,
				State.RightX,
				State.RightY,
				State.RightZ,
				State.ExtraBackPadding,
				State.FovDegrees
			)

			const PosBuf = buffer.create(COMPONENT_STRIDE)
			const SizeBuf = buffer.create(COMPONENT_STRIDE)
			buffer.writef32(PosBuf, 0, 125)
			buffer.writef32(PosBuf, 4, 20)
			buffer.writef32(PosBuf, 8, -50)
			buffer.writef32(SizeBuf, 0, 4)
			buffer.writef32(SizeBuf, 4, 4)
			buffer.writef32(SizeBuf, 8, 4)

			expect(ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)).to.equal(false)
			PlayerFunctions.RemovePlayerState(MockPlayer)
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)

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

			-- 1. Look at entity -> sent once
			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, ForwardPayload, EntityId)
			const FirstPos, _, _, _, _, _, FirstCounts = PlayerCuller.CullObjects(MockPlayer)
			expect(FirstPos ~= nil).to.equal(true)
			expect(FirstCounts ~= nil and FirstCounts.EntityECSCount >= 1).to.equal(true)

			-- 2. Look away (culls entity; other map parts in +Z may replicate here)
			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, BackwardPayload, EntityId)
			PlayerCuller.CullObjects(MockPlayer)

			-- 3. Look back without entity mutating -> must NOT re-send
			PlayerFunctions.UpdateObserverFromBuffer(MockPlayer, ForwardPayload, EntityId)
			const ReenterPos = PlayerCuller.CullObjects(MockPlayer)
			expect(ReenterPos == nil).to.equal(true)

			-- 4. Mutate entity while visible -> must send updated delta
			ServerStorage.PositionData.CreateLayout((EntityId - 1) * COMPONENT_STRIDE, 2, 0, -25)
			const DeltaPos, _, _, _, _, _, DeltaCounts = PlayerCuller.CullObjects(MockPlayer)
			expect(DeltaPos ~= nil).to.equal(true)
			expect(DeltaCounts ~= nil and DeltaCounts.EntityECSCount == 1).to.equal(true)

			PlayerFunctions.RemovePlayerState(MockPlayer)
			ServerStorage.ECSData.DeleteEntity(EntityId)
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)
	end)
end
