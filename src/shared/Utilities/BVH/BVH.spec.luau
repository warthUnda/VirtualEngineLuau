--!optimize 2

return function()
	const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared") :: Folder

	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const BVH = require(script.Parent)

	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	local function SpawnBoxEntity(
		Storage: ECSMain.ECSStorage,
		BoxCFrame: CFrame,
		Size: Vector3,
		IsStatic: boolean?,
		CanCollide: boolean?,
		Anchored: boolean?,
		DynamicObject: any?
	): (number, number)
		const StaticFlag = if IsStatic ~= nil then IsStatic else true
		const CollideFlag = if CanCollide ~= nil then CanCollide else true
		const AnchoredFlag = if Anchored ~= nil then Anchored else StaticFlag

		const EntityId = Storage.ECSData.RegisterEntity(StaticFlag) :: number
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number

		const Pos = BoxCFrame.Position
		const Look = BoxCFrame.LookVector
		const Up = BoxCFrame.UpVector
		const Right = BoxCFrame.RightVector

		Storage.PositionData.CreateLayout(CompOffset, Pos.X, Pos.Y, Pos.Z)
		Storage.OrientationData.CreateLayout(CompOffset, Look.X, Look.Y, Look.Z)
		Storage.SizeData.CreateLayout(CompOffset, Size.X, Size.Y, Size.Z)
		Storage.DirectionsData.CreateLayout(
			DirOffset,
			Look.X,
			Look.Y,
			Look.Z,
			Up.X,
			Up.Y,
			Up.Z,
			Right.X,
			Right.Y,
			Right.Z
		)
		Storage.PropertiesData.CreateLayout(PropOffset, CollideFlag, true, AnchoredFlag, 0)

		local DynamicId = 0 :: number
		if DynamicObject ~= nil then
			DynamicId = Storage.DynamicObjectsList.AddObject(DynamicObject, EntityId)
		end

		return EntityId, DynamicId
	end

	local function MoveEntity(Storage: ECSMain.ECSStorage, EntityId: number, NewCFrame: CFrame)
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

		const Pos = NewCFrame.Position
		const Look = NewCFrame.LookVector
		const Up = NewCFrame.UpVector
		const Right = NewCFrame.RightVector

		Storage.PositionData.CreateLayout(CompOffset, Pos.X, Pos.Y, Pos.Z)
		Storage.OrientationData.CreateLayout(CompOffset, Look.X, Look.Y, Look.Z)
		Storage.DirectionsData.CreateLayout(
			DirOffset,
			Look.X,
			Look.Y,
			Look.Z,
			Up.X,
			Up.Y,
			Up.Z,
			Right.X,
			Right.Y,
			Right.Z
		)
	end

	describe("1. Input Validation & Malformed Arguments", function()
		it("should safely reject nil, non-Vector3, and malformed Origin or Direction arguments", function()
			const Storage = ECSMain.CreateStorage(true)
			SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const Hit1, Obj1, Dist1 = BVH.Raycast(nil, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(Hit1).to.equal(nil)
			expect(Obj1).to.equal(nil)
			expect(Dist1).to.equal(0)

			const Hit2, Obj2, Dist2 = BVH.Raycast(Vector3.zero, nil, 100, nil, Storage)
			expect(Hit2).to.equal(nil)
			expect(Obj2).to.equal(nil)
			expect(Dist2).to.equal(0)

			const Hit3, Obj3, Dist3 = BVH.Raycast("invalid", 12345, 100, nil, Storage)
			expect(Hit3).to.equal(nil)
			expect(Obj3).to.equal(nil)
			expect(Dist3).to.equal(0)
		end)

		it("should safely reject zero-length, sub-epsilon, NaN, and Infinite rays", function()
			const Storage = ECSMain.CreateStorage(true)
			SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const HitZero, _, DistZero = BVH.Raycast(Vector3.zero, Vector3.zero, 100, nil, Storage)
			expect(HitZero).to.equal(nil)
			expect(DistZero).to.equal(0)

			const HitTiny = BVH.Raycast(Vector3.zero, Vector3.new(1e-12, 0, 0), 100, nil, Storage)
			expect(HitTiny).to.equal(nil)

			const NaN = 0 / 0
			const HitNaNDir = BVH.Raycast(Vector3.zero, Vector3.new(NaN, 0, -1), 100, nil, Storage)
			expect(HitNaNDir).to.equal(nil)

			const HitNaNOrigin = BVH.Raycast(Vector3.new(0, NaN, 0), Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(HitNaNOrigin).to.equal(nil)

			const HitInfOrigin = BVH.Raycast(Vector3.new(math.huge, 0, 0), Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(HitInfOrigin).to.equal(nil)

			const HitInfDir = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -math.huge), 100, nil, Storage)
			expect(HitInfDir).to.equal(nil)
		end)

		it("should safely reject zero, negative, and NaN MaxDistance values", function()
			const Storage = ECSMain.CreateStorage(true)
			SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const HitZeroDist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 0, nil, Storage)
			expect(HitZeroDist).to.equal(nil)

			const HitNegDist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), -25, nil, Storage)
			expect(HitNegDist).to.equal(nil)

			const HitNaNDist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 0 / 0, nil, Storage)
			expect(HitNaNDist).to.equal(nil)
		end)

		it("should support all calling signatures including __call and workspace:Raycast-style scaled direction", function()
			const Storage = ECSMain.CreateStorage(true)
			const EntityId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -20), Vector3.new(4, 4, 4), true)

			-- Signature A: (Origin, Direction, MaxDist, Ignore, Storage)
			const HitA = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(HitA).to.equal(EntityId)

			-- Signature B: (Storage, Origin, Direction, MaxDist, Ignore)
			const HitB = BVH.Raycast(Storage, Vector3.zero, Vector3.new(0, 0, -1), 50, nil)
			expect(HitB).to.equal(EntityId)

			-- Signature C: Direct module __call (Origin, ScaledDirection, Storage) where Magnitude = MaxDist
			const HitC, _, DistC = BVH(Vector3.zero, Vector3.new(0, 0, -25), Storage)
			expect(HitC).to.equal(EntityId)
			expect(math.abs(DistC - 18) < 1e-3).to.equal(true)

			-- Scaled direction that stops short of the target (length 15 < 18)
			const HitShort = BVH(Vector3.zero, Vector3.new(0, 0, -15), Storage)
			expect(HitShort).to.equal(nil)
		end)
	end)

	describe("2. Empty, Non-Collidable & Client-Mode Storage States", function()
		it("should return nil on an empty ECSStorage", function()
			const Storage = ECSMain.CreateStorage(true)
			const HitId, DynObj, Dist, Pos, Norm = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)

			expect(HitId).to.equal(nil)
			expect(DynObj).to.equal(nil)
			expect(Dist).to.equal(100)
			expect(Pos).to.equal(nil)
			expect(Norm).to.equal(nil)
		end)

		it("should ignore entities that have CanCollide set to false", function()
			const Storage = ECSMain.CreateStorage(true)
			SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(6, 6, 6), true, false, true)
			const SolidId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -25), Vector3.new(6, 6, 6), true, true, true)

			const HitId, _, Dist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(HitId).to.equal(SolidId)
			expect(math.abs(Dist - 22) < 1e-3).to.equal(true)
		end)

		it("should work on Client-style ECSStorage where StaticBuffer is nil and PropertiesBuffer is zeroed", function()
			const ClientStorage = ECSMain.CreateStorage(false)
			const EntityId = ClientStorage.ECSData.RegisterEntity(false)
			ClientStorage.PositionData.CreateLayout(0, 0, 0, -15)
			ClientStorage.SizeData.CreateLayout(0, 4, 4, 4)
			-- Leave DirectionsBuffer and PropertiesBuffer completely untouched (all 0s)

			const HitId, _, Dist, _, Normal = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 50, nil, ClientStorage)
			expect(HitId).to.equal(EntityId)
			expect(math.abs(Dist - 13) < 1e-3).to.equal(true)
			expect(Normal).to.equal(Vector3.new(0, 0, 1))
		end)

		it("should clear stale BVH nodes when all entities are deleted from storage", function()
			const Storage = ECSMain.CreateStorage(true)
			const EntityId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), true)

			const FirstHit = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(FirstHit).to.equal(EntityId)

			Storage.ECSData.DeleteEntity(EntityId)

			const AfterDeleteHit = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(AfterDeleteHit).to.equal(nil)
		end)
	end)

	describe("3. Degenerate Topologies & Tree Partitioning Stress Vectors", function()
		it("should handle 50 coincident entities at the exact same centroid without infinite recursion", function()
			const Storage = ECSMain.CreateStorage(true)
			for _ = 1, 50 do
				SpawnBoxEntity(Storage, CFrame.new(0, 0, -20), Vector3.new(4, 4, 4), true)
			end

			const HitId, _, Dist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(HitId ~= nil).to.equal(true)
			expect(math.abs(Dist - 18) < 1e-3).to.equal(true)
		end)

		it("should handle 150 collinear entities without exceeding traversal stack capacity", function()
			const Storage = ECSMain.CreateStorage(true)
			local ClosestExpectedId = 0
			for i = 150, 1, -1 do
				const Id = SpawnBoxEntity(Storage, CFrame.new(0, 0, -i * 5), Vector3.new(2, 2, 2), true)
				if i == 1 then
					ClosestExpectedId = Id
				end
			end

			const HitId, _, Dist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 1000, nil, Storage)
			expect(HitId).to.equal(ClosestExpectedId)
			expect(math.abs(Dist - 4) < 1e-3).to.equal(true)
		end)

		it("should sanitize negative size components properly", function()
			const Storage = ECSMain.CreateStorage(true)
			const EntityId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(-4, -4, -4), true)

			const HitId, _, Dist = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(HitId).to.equal(EntityId)
			expect(math.abs(Dist - 8) < 1e-3).to.equal(true)
		end)
	end)

	describe("4. Geometric Accuracy, Rotated OBBs & Surface Normals", function()
		it("should return exact hit distances, positions, and outward normals on all 6 box faces", function()
			const Storage = ECSMain.CreateStorage(true)
			const BoxId = SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(4, 6, 8), true)

			-- +Z face (ray from Z = 10 shooting -Z)
			const HitPZ, _, DistPZ, PosPZ, NormPZ = BVH.Raycast(Vector3.new(0, 0, 10), Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(HitPZ).to.equal(BoxId)
			expect(math.abs(DistPZ - 6) < 1e-3).to.equal(true)
			expect(((PosPZ :: Vector3) - Vector3.new(0, 0, 4)).Magnitude < 1e-3).to.equal(true)
			expect(NormPZ).to.equal(Vector3.new(0, 0, 1))

			-- -Z face (ray from Z = -10 shooting +Z)
			const HitNZ, _, DistNZ, _, NormNZ = BVH.Raycast(Vector3.new(0, 0, -10), Vector3.new(0, 0, 1), 50, nil, Storage)
			expect(HitNZ).to.equal(BoxId)
			expect(math.abs(DistNZ - 6) < 1e-3).to.equal(true)
			expect(NormNZ).to.equal(Vector3.new(0, 0, -1))

			-- +X face (ray from X = 10 shooting -X)
			const HitPX, _, DistPX, _, NormPX = BVH.Raycast(Vector3.new(10, 0, 0), Vector3.new(-1, 0, 0), 50, nil, Storage)
			expect(HitPX).to.equal(BoxId)
			expect(math.abs(DistPX - 8) < 1e-3).to.equal(true)
			expect(NormPX).to.equal(Vector3.new(1, 0, 0))

			-- -X face (ray from X = -10 shooting +X)
			const HitNX, _, DistNX, _, NormNX = BVH.Raycast(Vector3.new(-10, 0, 0), Vector3.new(1, 0, 0), 50, nil, Storage)
			expect(HitNX).to.equal(BoxId)
			expect(math.abs(DistNX - 8) < 1e-3).to.equal(true)
			expect(NormNX).to.equal(Vector3.new(-1, 0, 0))

			-- +Y face (ray from Y = 10 shooting -Y)
			const HitPY, _, DistPY, _, NormPY = BVH.Raycast(Vector3.new(0, 10, 0), Vector3.new(0, -1, 0), 50, nil, Storage)
			expect(HitPY).to.equal(BoxId)
			expect(math.abs(DistPY - 7) < 1e-3).to.equal(true)
			expect(NormPY).to.equal(Vector3.new(0, 1, 0))

			-- -Y face (ray from Y = -10 shooting +Y)
			const HitNY, _, DistNY, _, NormNY = BVH.Raycast(Vector3.new(0, -10, 0), Vector3.new(0, 1, 0), 50, nil, Storage)
			expect(HitNY).to.equal(BoxId)
			expect(math.abs(DistNY - 7) < 1e-3).to.equal(true)
			expect(NormNY).to.equal(Vector3.new(0, -1, 0))
		end)

		it("should accurately test rotated OBBs and reject rays that only clip the world AABB corner", function()
			const Storage = ECSMain.CreateStorage(true)
			const RotatedCF = CFrame.new(0, 0, -20) * CFrame.Angles(0, 0, math.rad(45))
			-- Thin beam (20 wide along local X, 1 thick along local Y, 4 deep along Z) rotated 45 deg
			const BeamId = SpawnBoxEntity(Storage, RotatedCF, Vector3.new(20, 1, 4), true)

			-- Ray through center (0, 0, 0) -> hits the rotated beam at Z = -18
			const HitCenter, _, DistCenter, _, NormCenter = BVH.Raycast(
				Vector3.new(0, 0, 0),
				Vector3.new(0, 0, -1),
				50,
				nil,
				Storage
			)
			expect(HitCenter).to.equal(BeamId)
			expect(math.abs(DistCenter - 18) < 1e-3).to.equal(true)
			expect(((NormCenter :: Vector3) - Vector3.new(0, 0, 1)).Magnitude < 1e-3).to.equal(true)

			-- Ray at (-5, 5, 0) -> inside the world AABB [-7.4, 7.4] x [-7.4, 7.4], but misses the 45-deg diagonal beam!
			const HitCorner = BVH.Raycast(Vector3.new(-5, 5, 0), Vector3.new(0, 0, -1), 50, nil, Storage)
			expect(HitCorner).to.equal(nil)

			-- Ray hitting the rotated top-left face vertically from (0, 10, -20) downward
			const HitDiag, _, _, _, NormDiag = BVH.Raycast(
				Vector3.new(0, 10, -20),
				Vector3.new(0, -1, 0),
				50,
				nil,
				Storage
			)
			expect(HitDiag).to.equal(BeamId)
			expect(((NormDiag :: Vector3) - RotatedCF.UpVector).Magnitude < 1e-3).to.equal(true)
		end)

		it("should handle rays starting strictly inside an entity bounding box", function()
			const Storage = ECSMain.CreateStorage(true)
			const BoxId = SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(10, 10, 10), true)

			const HitId, _, Dist, Pos, Norm = BVH.Raycast(
				Vector3.new(1, 1, 1),
				Vector3.new(0, 0, -1),
				50,
				nil,
				Storage
			)
			expect(HitId).to.equal(BoxId)
			expect(Dist).to.equal(0)
			expect(Pos).to.equal(Vector3.new(1, 1, 1))
			expect(Norm ~= nil).to.equal(true)
		end)
	end)

	describe("5. Dynamic OOP Objects & Live Movement Vectors", function()
		it("should return the bound Dynamic OOP Object when hitting an entity registered with AddObject", function()
			const Storage = ECSMain.CreateStorage(true)
			const EnemyOOP = { Name = "BossGoblin", Health = 250 }

			SpawnBoxEntity(Storage, CFrame.new(0, 0, -30), Vector3.new(6, 6, 6), true)
			const EnemyEntityId = SpawnBoxEntity(
				Storage,
				CFrame.new(0, 0, -15),
				Vector3.new(4, 6, 4),
				false,
				true,
				false,
				EnemyOOP
			)

			const HitEntityId, HitDynObj, Dist = BVH.Raycast(
				Vector3.zero,
				Vector3.new(0, 0, -1),
				100,
				nil,
				Storage
			)
			expect(HitEntityId).to.equal(EnemyEntityId)
			expect(HitDynObj).to.equal(EnemyOOP)
			expect(math.abs(Dist - 13) < 1e-3).to.equal(true)
		end)

		it("should track Dynamic OOP Objects moving across the map in real time without ghost hits", function()
			const Storage = ECSMain.CreateStorage(true)
			const VehicleOOP = { Type = "HoverTank", Speed = 80 }

			const TankEntityId = SpawnBoxEntity(
				Storage,
				CFrame.new(0, 0, -15),
				Vector3.new(4, 4, 4),
				false,
				true,
				false,
				VehicleOOP
			)

			-- Initial hit at (0, 0, -15)
			const Hit1, Obj1 = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(Hit1).to.equal(TankEntityId)
			expect(Obj1).to.equal(VehicleOOP)

			-- Move tank to (50, 0, -15) without manually calling BVH.Rebuild
			MoveEntity(Storage, TankEntityId, CFrame.new(50, 0, -15))

			-- Ray at old position (0, 0, -15) must NOT ghost-hit!
			const GhostHit, GhostObj = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(GhostHit).to.equal(nil)
			expect(GhostObj).to.equal(nil)

			-- Ray at new position (50, 0, -15) MUST hit and return VehicleOOP!
			const NewHit, NewObj, NewDist = BVH.Raycast(
				Vector3.new(50, 0, 0),
				Vector3.new(0, 0, -1),
				100,
				nil,
				Storage
			)
			expect(NewHit).to.equal(TankEntityId)
			expect(NewObj).to.equal(VehicleOOP)
			expect(math.abs(NewDist - 13) < 1e-3).to.equal(true)
		end)

		it("should detect in-place mutations to Static entities (position, size, or late BindEntity) automatically", function()
			const Storage = ECSMain.CreateStorage(true)
			const WallId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -15), Vector3.new(4, 4, 4), true, true, true)

			-- Build static BVH via initial raycast
			const InitialHit, InitialObj = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(InitialHit).to.equal(WallId)
			expect(InitialObj).to.equal(nil)

			-- Late-bind a Dynamic OOP object to the static entity and teleport it to (0, 30, -15)
			const DestructibleOOP = { Type = "BreakableWall", Integrity = 100 }
			const DynId = Storage.DynamicObjectsList.AddObject(DestructibleOOP, WallId)
			MoveEntity(Storage, WallId, CFrame.new(0, 30, -15))

			-- Old position should miss
			const OldRayHit = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, nil, Storage)
			expect(OldRayHit).to.equal(nil)

			-- New position should hit and return the newly bound OOP object
			const MovedHit, MovedObj = BVH.Raycast(
				Vector3.new(0, 30, 0),
				Vector3.new(0, 0, -1),
				100,
				nil,
				Storage
			)
			expect(MovedHit).to.equal(WallId)
			expect(MovedObj).to.equal(DestructibleOOP)

			-- Now remove the Dynamic OOP object; entity should still hit as a plain entity with nil DynamicObject
			Storage.DynamicObjectsList.RemoveObject(DynId)
			const AfterRemoveHit, AfterRemoveObj = BVH.Raycast(
				Vector3.new(0, 30, 0),
				Vector3.new(0, 0, -1),
				100,
				nil,
				Storage
			)
			expect(AfterRemoveHit).to.equal(WallId)
			expect(AfterRemoveObj).to.equal(nil)
		end)

		it("should hit standalone unbound OOP objects in DynamicObjectsList using their CFrame/Position and Size", function()
			const Storage = ECSMain.CreateStorage(true)
			SpawnBoxEntity(Storage, CFrame.new(0, 0, -40), Vector3.new(6, 6, 6), true)

			const StandaloneShieldOOP = {
				Name = "EnergyShield",
				CFrame = CFrame.new(0, 0, -15),
				Size = Vector3.new(6, 6, 2),
			}
			Storage.DynamicObjectsList.AddObject(StandaloneShieldOOP)

			const HitEntityId, HitDynObj, Dist = BVH.Raycast(
				Vector3.zero,
				Vector3.new(0, 0, -1),
				100,
				nil,
				Storage
			)
			expect(HitEntityId).to.equal(nil)
			expect(HitDynObj).to.equal(StandaloneShieldOOP)
			expect(math.abs(Dist - 14) < 1e-3).to.equal(true)
		end)
	end)

	describe("6. Ignore Filter Failure Vectors", function()
		it("should support ignoring by EntityId, by Dynamic OOP Object reference, or by ignore table", function()
			const Storage = ECSMain.CreateStorage(true)
			const FrontOOP = { Role = "Caster" }
			const MidOOP = { Role = "Teammate" }
			const BackOOP = { Role = "Target" }

			const FrontId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -10), Vector3.new(4, 4, 4), false, true, false, FrontOOP)
			const MidId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -20), Vector3.new(4, 4, 4), true, true, true, MidOOP)
			const BackId = SpawnBoxEntity(Storage, CFrame.new(0, 0, -30), Vector3.new(4, 4, 4), true, true, true, BackOOP)

			-- Ignore FrontId by number -> hits MidId
			const HitMid, ObjMid = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, FrontId, Storage)
			expect(HitMid).to.equal(MidId)
			expect(ObjMid).to.equal(MidOOP)

			-- Ignore FrontOOP by OOP object reference -> hits MidId
			const HitMid2, ObjMid2 = BVH.Raycast(Vector3.zero, Vector3.new(0, 0, -1), 100, FrontOOP, Storage)
			expect(HitMid2).to.equal(MidId)
			expect(ObjMid2).to.equal(MidOOP)

			-- Ignore both FrontId and MidOOP via table -> hits BackId
			const HitBack, ObjBack = BVH.Raycast(
				Vector3.zero,
				Vector3.new(0, 0, -1),
				100,
				{ FrontId, MidOOP },
				Storage
			)
			expect(HitBack).to.equal(BackId)
			expect(ObjBack).to.equal(BackOOP)
		end)
	end)

	describe("7. QueryAABB Spatial Broadphase Vectors", function()
		it("should find all static and dynamic entities overlapping the AABB and handle inverted bounds", function()
			const Storage = ECSMain.CreateStorage(true)
			const StaticIn = SpawnBoxEntity(Storage, CFrame.new(2, 0, 0), Vector3.new(2, 2, 2), true)
			const DynamicIn = SpawnBoxEntity(Storage, CFrame.new(-2, 0, 0), Vector3.new(2, 2, 2), false, true, false)
			SpawnBoxEntity(Storage, CFrame.new(100, 0, 0), Vector3.new(2, 2, 2), true) -- Outside
			SpawnBoxEntity(Storage, CFrame.new(0, 0, 0), Vector3.new(2, 2, 2), true, false, true) -- CanCollide = false

			local Results = {} :: { number }
			-- Pass inverted min/max corners to verify auto-normalization
			const Count = BVH.QueryAABB(
				Vector3.new(5, 5, 5),
				Vector3.new(-5, -5, -5),
				Results,
				Storage
			)

			expect(Count).to.equal(2)
			const FoundStatic = table.find(Results, StaticIn) ~= nil
			const FoundDynamic = table.find(Results, DynamicIn) ~= nil
			expect(FoundStatic).to.equal(true)
			expect(FoundDynamic).to.equal(true)
		end)
	end)
end
