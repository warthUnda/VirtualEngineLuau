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

	-- Libraries --
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const BVH = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("BVH"))
	const TestHelper = require(ServerScriptService.Server.Tests.TestHelper)

	describe("1. BVH Input Validation & Scaled Raycast Calls", function()
		it("should reject nil or malformed origins and directions safely", function()
			const Storage = ECSMain.CreateStorage(true)
			TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const Hit1, Obj1, Dist1 = BVH.Raycast(Storage, nil :: any, Vector3.new(0, 0, -1), 100)
			expect(Hit1).to.equal(nil)
			expect(Obj1).to.equal(nil)
			expect(Dist1).to.equal(0)

			const Hit2, _Obj2, Dist2 = BVH.Raycast(Storage, Vector3.zero, nil :: any, 100)
			expect(Hit2).to.equal(nil)
			expect(Dist2).to.equal(0)
		end)

		it("should reject zero-length and degenerate rays", function()
			const Storage = ECSMain.CreateStorage(true)
			TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const HitZero, _, DistZero = BVH.Raycast(Storage, Vector3.zero, Vector3.zero, 100)
			expect(HitZero).to.equal(nil)
			expect(DistZero).to.equal(0)
		end)

		it("should support direct module __call with scaled direction", function()
			const Storage = ECSMain.CreateStorage(true)
			const EntityId = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -20), Vector3.new(4, 4, 4), true)

			const Hit, _, Dist = BVH(Storage, Vector3.zero, Vector3.new(0, 0, -25))
			expect(Hit).to.equal(EntityId)
			expect(Dist).to.be.near(18, 1e-2)

			const HitShort = BVH(Storage, Vector3.zero, Vector3.new(0, 0, -15))
			expect(HitShort).to.equal(nil)
		end)
	end)

	describe("2. BVH Collisions, Rotated OBBs & Normals", function()
		it("should calculate exact hit distance and face normals on unrotated boxes", function()
			const Storage = ECSMain.CreateStorage(true)
			const BoxId = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(4, 6, 8), true)

			const HitPZ, _, DistPZ, _PosPZ, NormPZ = BVH.Raycast(Storage, Vector3.new(0, 0, 10), Vector3.new(0, 0, -1), 50)
			expect(HitPZ).to.equal(BoxId)
			expect(DistPZ).to.be.near(6, 1e-3)
			expect(NormPZ).to.equal(Vector3.new(0, 0, 1))

			const HitPX, _, DistPX, _, NormPX = BVH.Raycast(Storage, Vector3.new(10, 0, 0), Vector3.new(-1, 0, 0), 50)
			expect(HitPX).to.equal(BoxId)
			expect(DistPX).to.be.near(8, 1e-3)
			expect(NormPX).to.equal(Vector3.new(1, 0, 0))
		end)

		it("should accurately test 45-degree rotated OBBs and reject corner AABB rays", function()
			const Storage = ECSMain.CreateStorage(true)
			const RotatedCF = CFrame.new(0, 0, -20) * CFrame.Angles(0, 0, math.rad(45))
			const BeamId = TestHelper.SpawnBoxEntity(Storage, RotatedCF, Vector3.new(20, 1, 4), true)

			const HitCenter, _, DistCenter = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50)
			expect(HitCenter).to.equal(BeamId)
			expect(DistCenter).to.be.near(18, 1e-3)

			const HitCorner = BVH.Raycast(Storage, Vector3.new(-5, 5, 0), Vector3.new(0, 0, -1), 50)
			expect(HitCorner).to.equal(nil)
		end)
	end)

	describe("3. BVH Dynamic Objects & Direct Auto-Rebuild", function()
		it("should return bound OOP objects and track live movement in real time", function()
			const Storage = ECSMain.CreateStorage(true)
			const TargetOOP = { Id = "Tank1", Speed = 50 }
			const EntityId = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -15), Vector3.new(4, 4, 4), false, true, false, TargetOOP)

			const Hit1, Obj1 = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50)
			expect(Hit1).to.equal(EntityId)
			expect(Obj1).to.equal(TargetOOP)

			TestHelper.MoveEntity(Storage, EntityId, CFrame.new(30, 0, -15))

			const GhostHit = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50)
			expect(GhostHit).to.equal(nil)

			const NewHit, NewObj = BVH.Raycast(Storage, Vector3.new(30, 0, 0), Vector3.new(0, 0, -1), 50)
			expect(NewHit).to.equal(EntityId)
			expect(NewObj).to.equal(TargetOOP)
		end)

		it("should skip non-collidable entities and auto-rebuild directly when static geometry mutates", function()
			const Storage = ECSMain.CreateStorage(true)
			const _NonCollidableFront = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true, false, true)
			const StaticBack = TestHelper.SpawnBoxEntity(Storage, CFrame.new(0, 0, -20), Vector3.new(4, 4, 4), true, true, true)

			const InitialHit = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50)
			expect(InitialHit).to.equal(StaticBack)

			TestHelper.MoveEntity(Storage, StaticBack, CFrame.new(40, 0, -20))
			const AfterMoveOldRay = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50)
			expect(AfterMoveOldRay).to.equal(nil)

			const AfterMoveNewRay = BVH.Raycast(Storage, Vector3.new(40, 0, 0), Vector3.new(0, 0, -1), 50)
			expect(AfterMoveNewRay).to.equal(StaticBack)
		end)
	end)

	describe("4. BVH Broadphase AABB Queries", function()
		it("should collect all overlapping entities within query bounds", function()
			const Storage = ECSMain.CreateStorage(true)
			const Ent1 = TestHelper.SpawnBoxEntity(Storage, CFrame.new(2, 0, 0), Vector3.new(2, 2, 2), true)
			const Ent2 = TestHelper.SpawnBoxEntity(Storage, CFrame.new(-2, 0, 0), Vector3.new(2, 2, 2), false, true, false)
			TestHelper.SpawnBoxEntity(Storage, CFrame.new(100, 0, 0), Vector3.new(2, 2, 2), true)

			local Results = {}
			const Count = BVH.QueryAABB(Vector3.new(-5, -5, -5), Vector3.new(5, 5, 5), Results, Storage)
			expect(Count).to.equal(2)
			expect(table.find(Results, Ent1) ~= nil).to.equal(true)
			expect(table.find(Results, Ent2) ~= nil).to.equal(true)

			const ScalarOut = buffer.create(16 * 4)
			BVH.EnsureFresh(Storage)
			const ScalarCount = BVH.QueryAABBScalar(-5, -5, -5, 5, 5, 5, ScalarOut, 16, Storage, true)
			expect(ScalarCount).to.equal(2)
		end)
	end)
end
