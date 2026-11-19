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
	const RenderBVHHelper = require(SceneFolder:WaitForChild("RenderBVHHelper"))

	-- Configs --
	const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
	const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number

	describe("1. Sleeping Unanchored BVH Indexing, Idle NeedsSync Gating & Lazy Demotion", function()
		it("should BVH-cull off-screen unanchored sleeping parts, skip idle syncs, and lazily track awakened parts", function()
			const ObjectStorage = ECSMain.CreateStorage(false)
			const RenderStorage = ECSMain.CreateStorage(false)

			-- Spawn 20 off-screen unanchored sleeping parts behind the camera (Z = +300) and 1 in-front part (Z = -20)
			for i = 1, 20 do
				const Id = ObjectStorage.ECSData.RegisterEntity() :: number
				const CompOff = (Id - 1) * COMPONENT_STRIDE :: number
				ObjectStorage.PositionData.CreateLayout(CompOff, i * 6, 0, 300)
				ObjectStorage.DirectionsData.CreateLayout((Id - 1) * 36, 0, 0, -1, 0, 1, 0, 1, 0, 0)
				ObjectStorage.SizeData.CreateLayout(CompOff, 4, 4, 4)
				ObjectStorage.VisualData.CreateLayout((Id - 1) * 4, 100, 120, 140)
				ObjectStorage.PropertiesData.CreateLayout((Id - 1) * PROPERTIES_STRIDE, true, true, false, 0)
			end

			const MovableId = ObjectStorage.ECSData.RegisterEntity() :: number
			const MovCompOff = (MovableId - 1) * COMPONENT_STRIDE :: number
			ObjectStorage.PositionData.CreateLayout(MovCompOff, 0, 0, 300)
			ObjectStorage.DirectionsData.CreateLayout((MovableId - 1) * 36, 0, 0, -1, 0, 1, 0, 1, 0, 0)
			ObjectStorage.SizeData.CreateLayout(MovCompOff, 4, 4, 4)
			ObjectStorage.VisualData.CreateLayout((MovableId - 1) * 4, 220, 50, 50)
			ObjectStorage.PropertiesData.CreateLayout((MovableId - 1) * PROPERTIES_STRIDE, true, true, false, 0)

			const CamCF = CFrame.new(0, 0, 0)
			const PlayerPos = Vector3.zero
			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)

			const State = CleanerHelper.CreateCleanerState(ObjectStorage, RenderStorage)
			expect(CleanerHelper.NeedsSync(State, CamCF, 70, PlayerPos)).to.equal(true)
			expect(CleanerHelper.SyncRenderStorage(State)).to.equal(0)

			-- BVH must cull all 21 off-screen unanchored sleeping parts to 0 candidates!
			const CandCount = RenderBVHHelper.QueryFrustumCandidates(State.RenderBVH, State.CandidateIds)
			expect(CandCount).to.equal(0)

			-- Stationary camera + sleeping unanchored parts with cleared dirty flags must NOT trigger redundant syncs!
			expect(CleanerHelper.NeedsSync(State, CamCF, 70, PlayerPos)).to.equal(false)

			-- Wake MovableId and move it into the camera frustum (Z = -25)
			ObjectStorage.PositionData.CreateLayout(MovCompOff, 0, 0, -25)
			ObjectStorage.ECSData.MarkDirty(MovableId)

			expect(CleanerHelper.NeedsSync(State, CamCF, 70, PlayerPos)).to.equal(true)
			expect(CleanerHelper.SyncRenderStorage(State)).to.equal(1)
			expect(buffer.readu32(State.ObjectIdByRenderSlot, 4)).to.equal(MovableId)

			-- Once synced and dirty flag cleared, stationary scene sleeps again!
			expect(CleanerHelper.NeedsSync(State, CamCF, 70, PlayerPos)).to.equal(false)

			ViewCulling.UpdateObserverFromVectors(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 70)
		end)
	end)
end
