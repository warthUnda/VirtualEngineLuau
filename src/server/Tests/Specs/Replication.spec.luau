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
	const ViewCulling = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("ViewCulling"))

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
	end)
end
