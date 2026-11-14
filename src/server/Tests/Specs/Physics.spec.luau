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
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const PhysicsMath = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Physics"):WaitForChild("Core"):WaitForChild("PhysicsMath"))
	const PhysicsLibrary = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Physics"):WaitForChild("PhysicsLibrary"))
	const ServerStorage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
	const TestHelper = require(ServerScriptService.Server.Tests.TestHelper)

	describe("1. Player Velocity Kinematics & Wish Direction", function()
		it("should decelerate on ground when wish direction is zero", function()
			const InitialVelX = 20 :: number
			const InitialVelZ = 0 :: number
			const NextX, _NextY, _NextZ, Grounded = PhysicsMath.StepPlayerVelocity(
				InitialVelX, 0, InitialVelZ,
				0, 0, 0,
				false, true,
				1 / 60
			)

			expect(NextX < InitialVelX).to.equal(true)
			expect(NextX > 0).to.equal(true)
			expect(Grounded).to.equal(true)
		end)

		it("should accelerate toward wish direction when moving", function()
			const _NextX, _, NextZ = PhysicsMath.StepPlayerVelocity(
				0, 0, 0,
				0, -1, 1,
				false, true,
				1 / 60
			)

			expect(NextZ < 0).to.equal(true)
		end)

		it("should apply upward jump velocity when jump is requested on ground", function()
			const _, NextY, _, Grounded = PhysicsMath.StepPlayerVelocity(
				0, 0, 0,
				0, 0, 0,
				true, true,
				1 / 60
			)

			expect(NextY > 0).to.equal(true)
			expect(Grounded).to.equal(false)
		end)
	end)

	describe("2. Dynamic Object Velocity, Drag & Forces", function()
		it("should accelerate dynamic objects based on force and inverse mass", function()
			const Mass = 10 :: number
			const InvMass = 1 / Mass :: number
			const ForceX = 100 :: number -- 10 m/s^2 accel
			const Dt = 0.1 :: number

			const NextX, NextY, _ = PhysicsMath.StepObjectVelocity(
				0, 0, 0,
				ForceX, 0, 0,
				InvMass, false,
				Dt
			)

			expect(NextX > 0.9).to.equal(true)
			-- Gravity should accelerate downward
			expect(NextY < 0).to.equal(true)
		end)
	end)

	describe("3. Box vs ECS OBB Contact Detection", function()
		it("should detect overlap between moving box and static ECS box", function()
			const Storage = ECSMain.CreateStorage(true)
			const BoxId = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(4, 4, 4), true)

			const CompOffset = (BoxId - 1) * SystemsConfigs.ECSComponentStride :: number
			const DirOffset = (BoxId - 1) * SystemsConfigs.ECSDirectionStride :: number

			const Overlaps, NormX, NormY, NormZ, Depth = PhysicsMath.TestBoxVsOBB(
				0, 0, 2.5, -- Penetrating +Z face by 0.5 studs (box size 4 -> half 2, body half 1 -> sum 3 > 2.5)
				1, 1, 1,
				CompOffset,
				DirOffset,
				Storage.PositionData.GetData(),
				Storage.SizeData.GetData(),
				Storage.DirectionsData.GetData()
			)

			expect(Overlaps).to.equal(true)
			expect(Depth > 0).to.equal(true)
			expect(NormZ > 0.9).to.equal(true)
			expect(math.abs(NormX) < 1e-4).to.equal(true)
			expect(math.abs(NormY) < 1e-4).to.equal(true)
		end)

		it("should reject boxes that do not intersect", function()
			const Storage = ECSMain.CreateStorage(true)
			const BoxId = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(4, 4, 4), true)

			const CompOffset = (BoxId - 1) * SystemsConfigs.ECSComponentStride :: number
			const DirOffset = (BoxId - 1) * SystemsConfigs.ECSDirectionStride :: number

			const Overlaps = PhysicsMath.TestBoxVsOBB(
				0, 0, 20, -- Far away
				1, 1, 1,
				CompOffset,
				DirOffset,
				Storage.PositionData.GetData(),
				Storage.SizeData.GetData(),
				Storage.DirectionsData.GetData()
			)

			expect(Overlaps).to.equal(false)
		end)
	end)

	describe("4. PhysicsLibrary Public API Interface", function()
		it("should expose player position and velocity setters and getters safely", function()
			const TestPos = Vector3.new(12, 34, 56)
			PhysicsLibrary.SetPlayerPosition(TestPos)
			const CurrentPos = PhysicsLibrary.GetPlayerPosition()
			expect((CurrentPos - TestPos).Magnitude).to.be.near(0, 1e-2)

			const TestVel = Vector3.new(5, 10, -5)
			PhysicsLibrary.SetPlayerVelocity(TestVel)
			const CurrentVel = PhysicsLibrary.GetPlayerVelocity()
			expect((CurrentVel - TestVel).Magnitude).to.be.near(0, 1e-2)
		end)

		it("should simulate unanchored entities with prepackaged defaults and reject anchored entities", function()
			const AnchoredId = TestHelper.SpawnBoxEntity(ServerStorage, CFrame.new(0, 50, 0), Vector3.new(2, 2, 2), true)
			const UnanchoredId = TestHelper.SpawnBoxEntity(ServerStorage, CFrame.new(10, 50, 0), Vector3.new(2, 2, 2), false)

			-- Anchored entity must be rejected
			expect(PhysicsLibrary.SimulateInstance(AnchoredId)).to.equal(false)

			-- Unanchored entity must immediately start simulating with prepackaged defaults when parameters are nil
			expect(PhysicsLibrary.SimulateInstance(UnanchoredId)).to.equal(true)

			PhysicsLibrary.StopSimulatingInstance(UnanchoredId)
		end)
	end)
end
