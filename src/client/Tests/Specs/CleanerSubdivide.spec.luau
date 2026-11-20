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
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")
	const SceneFolder = RenderRoot:WaitForChild("Scene")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const ViewCulling = require(RenderRoot:WaitForChild("Core"):WaitForChild("ViewCulling"))
	const CleanerHelper = require(SceneFolder:WaitForChild("CleanerHelper"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	-- Local Functions --
	local function SpawnPart(
		Storage: ECSMain.ECSStorage,
		Pos: Vector3,
		Size: Vector3,
		ColorR: number,
		ShapeId: number?
	): number
		const EntityId = Storage.ECSData.RegisterEntity(true) :: number
		const CompOff = (EntityId - 1) * COMPONENT_STRIDE :: number
		Storage.PositionData.CreateLayout(CompOff, Pos.X, Pos.Y, Pos.Z)
		Storage.DirectionsData.CreateLayout((EntityId - 1) * 36, 0, 0, -1, 0, 1, 0, 1, 0, 0)
		Storage.SizeData.CreateLayout(CompOff, Size.X, Size.Y, Size.Z)
		Storage.VisualData.CreateLayout((EntityId - 1) * 4, ColorR, 120, 160)
		Storage.PropertiesData.CreateLayout((EntityId - 1) * PROPERTIES_STRIDE, true, true, true, 0, 0, ShapeId or 0)
		return EntityId
	end

	describe("1. Temporary Mean-Size Subdivision of Massive Parts in Render Culling", function()
		it("should subdivide massive parts into mean-sized temporary RenderStorage entries without mutating ObjectStorage", function()
			const ObjectStorage = ECSMain.CreateStorage(false)
			const RenderStorage = ECSMain.CreateStorage(false)

			for i = 1, 5 do
				SpawnPart(ObjectStorage, Vector3.new((i - 3) * 8, 2, -25), Vector3.new(6, 6, 6), 40 + i, 0)
			end
			const MassiveId = SpawnPart(ObjectStorage, Vector3.new(0, -4, -32), Vector3.new(36, 0.4, 36), 200, 4)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
			const State = CleanerHelper.CreateCleanerState(ObjectStorage, RenderStorage)
			const RenderCount = CleanerHelper.SyncRenderStorage(State)

			-- ObjectStorage must stay completely untouched at 6 entities and original 36x0.4x36 size
			expect(ObjectStorage.ECSData.GetCounts().EntityECSCount).to.equal(6)
			expect(ObjectStorage.ECSData.GetCounts().ActiveEntityCount).to.equal(6)
			const ObjSizes = ObjectStorage.SizeData.GetData()
			const MassiveCompOff = (MassiveId - 1) * COMPONENT_STRIDE :: number
			expect(buffer.readf32(ObjSizes, MassiveCompOff)).to.be.near(36, 1e-3)
			expect(buffer.readf32(ObjSizes, MassiveCompOff + 8)).to.be.near(36, 1e-3)

			-- RenderStorage should contain the 5 normal parts + 16 subdivided (9x0.4x9) temporary parts = 21
			expect(RenderCount).to.equal(21)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(21)

			const RenSizes = RenderStorage.SizeData.GetData()
			local SubChunkCount = 0 :: number
			for Slot = 1, RenderCount do
				const Off = (Slot - 1) * COMPONENT_STRIDE :: number
				const SX = buffer.readf32(RenSizes, Off) :: number
				const SZ = buffer.readf32(RenSizes, Off + 8) :: number
				expect(SX <= 12).to.equal(true)
				expect(SZ <= 12).to.equal(true)
				if math.abs(SX - 9) < 1e-2 and math.abs(SZ - 9) < 1e-2 then
					SubChunkCount += 1
				end
			end
			expect(SubChunkCount).to.equal(16)

			-- Deleting the massive part from ObjectStorage must clean up all temporary subdivided slots
			ObjectStorage.ECSData.DeleteEntity(MassiveId)
			const AfterDeleteCount = CleanerHelper.SyncRenderStorage(State)
			expect(AfterDeleteCount).to.equal(5)
			expect(RenderStorage.ECSData.GetCounts().EntityECSCount).to.equal(5)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)

		it("should frustum-cull behind-camera sub-parts of massive planes instead of staging the entire plane", function()
			const ObjectStorage = ECSMain.CreateStorage(false)
			const RenderStorage = ECSMain.CreateStorage(false)

			for i = 1, 5 do
				SpawnPart(ObjectStorage, Vector3.new((i - 3) * 6, 2, -20), Vector3.new(6, 6, 6), 80, 0)
			end
			-- Plane spanning Z = -40 .. +80 (mostly behind the camera at origin looking -Z)
			SpawnPart(ObjectStorage, Vector3.new(0, -3, 20), Vector3.new(60, 0.4, 120), 180, 4)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
			const State = CleanerHelper.CreateCleanerState(ObjectStorage, RenderStorage)
			const RenderCount = CleanerHelper.SyncRenderStorage(State)

			expect(RenderCount > 6).to.equal(true)
			expect(RenderCount < 55).to.equal(true)
			expect(ObjectStorage.ECSData.GetCounts().EntityECSCount).to.equal(6)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)
	end)
end
