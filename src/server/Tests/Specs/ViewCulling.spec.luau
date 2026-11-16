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
	const ReplicatedStorage = game:GetService("ReplicatedStorage")
	const ServerScriptService = game:GetService("ServerScriptService")

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ViewCulling = require(
		SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling")
	)
	const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number

	describe("1. Frustum, View Cone & Occluder Culling", function()
		it("should cull entities behind or beyond near/far clipping boundaries", function()
			const PosBuf = buffer.create(COMPONENT_STRIDE * 2)
			const SizeBuf = buffer.create(COMPONENT_STRIDE * 2)

			buffer.writef32(PosBuf, 0, 0)
			buffer.writef32(PosBuf, 4, 0)
			buffer.writef32(PosBuf, 8, 50000)
			buffer.writef32(SizeBuf, 0, 2)
			buffer.writef32(SizeBuf, 4, 2)
			buffer.writef32(SizeBuf, 8, 2)

			expect(ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)).to.equal(true)
		end)

		it("should pass entities directly in front of the observer cone", function()
			const PosBuf = buffer.create(COMPONENT_STRIDE)
			const SizeBuf = buffer.create(COMPONENT_STRIDE)

			buffer.writef32(PosBuf, 0, 0)
			buffer.writef32(PosBuf, 4, 0)
			buffer.writef32(PosBuf, 8, -20)
			buffer.writef32(SizeBuf, 0, 4)
			buffer.writef32(SizeBuf, 4, 4)
			buffer.writef32(SizeBuf, 8, 4)

			expect(ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)).to.equal(false)
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

		it("should prepass dominant occluders regardless of entity ordering", function()
			const PosBuf = buffer.create(COMPONENT_STRIDE * 2)
			const SizeBuf = buffer.create(COMPONENT_STRIDE * 2)
			const PropBuf = buffer.create(SystemsConfigs.ECSPropertiesStride * 2)

			buffer.writef32(PosBuf, 0, 0)
			buffer.writef32(PosBuf, 4, 0)
			buffer.writef32(PosBuf, 8, -60)
			buffer.writef32(SizeBuf, 0, 2)
			buffer.writef32(SizeBuf, 4, 2)
			buffer.writef32(SizeBuf, 8, 2)
			buffer.writeu32(PropBuf, 0, bit32.lshift(1, 2))

			buffer.writef32(PosBuf, COMPONENT_STRIDE, 0)
			buffer.writef32(PosBuf, COMPONENT_STRIDE + 4, 0)
			buffer.writef32(PosBuf, COMPONENT_STRIDE + 8, -15)
			buffer.writef32(SizeBuf, COMPONENT_STRIDE, 24)
			buffer.writef32(SizeBuf, COMPONENT_STRIDE + 4, 24)
			buffer.writef32(SizeBuf, COMPONENT_STRIDE + 8, 24)
			buffer.writeu32(PropBuf, SystemsConfigs.ECSPropertiesStride, bit32.lshift(1, 2))

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
			ViewCulling.PrepassDominantOccluder(2, PosBuf, SizeBuf, PropBuf)
			expect(ViewCulling.IsEntityCulled(1, PosBuf, SizeBuf)).to.equal(true)
			expect(ViewCulling.IsEntityCulled(2, PosBuf, SizeBuf)).to.equal(false)
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)
	end)
end
