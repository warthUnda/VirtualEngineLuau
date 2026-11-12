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
	const PhysicsControllerHelper = require(
		SharedFolder:WaitForChild("Utilities")
			:WaitForChild("Physics")
			:WaitForChild("Controller")
			:WaitForChild("PhysicsControllerHelper")
	)

	const MAX_WISH_SCALE = SystemsConfigs.PlayerMaxWishScale :: number

	describe("1. Player Input Vector Normalization & Wish Clamping", function()
		it("should normalize raw diagonal keyboard input and clamp wish scale", function()
			-- Diagonal key press (W + D): raw wish (1, -1)
			const UnitX, UnitZ, Scale, Jump = PhysicsControllerHelper.FlushPlayerIntent(1, -1, 1.5, true)

			const Length = math.sqrt(UnitX * UnitX + UnitZ * UnitZ)
			expect(Length).to.be.near(1.0, 1e-4)
			expect(Scale <= MAX_WISH_SCALE).to.equal(true)
			expect(Jump).to.equal(true)
		end)

		it("should handle zero input gracefully without NaNs", function()
			const UnitX, UnitZ, Scale, Jump = PhysicsControllerHelper.FlushPlayerIntent(0, 0, 0, false)

			expect(UnitX).to.equal(0)
			expect(UnitZ).to.equal(0)
			expect(Scale).to.equal(0)
			expect(Jump).to.equal(false)
		end)
	end)
end
