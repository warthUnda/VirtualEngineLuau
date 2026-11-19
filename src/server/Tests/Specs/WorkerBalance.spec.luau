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

	-- Libraries --
	const WorkerPartitionHelper = require(RenderRoot:WaitForChild("Controller"):WaitForChild("WorkerPartitionHelper"))

	describe("1. Asymmetric Sky-Band Baseline Cost & Near-Clip Stage Chunk Weighting", function()
		it("should weight empty sky rows during band partitioning so Worker 1 does not absorb >58% of screen height", function()
			const Height = 1000 :: number
			const WorkerCount = 3 :: number
			const RowWorkDiff = buffer.create((Height + 1) * 4)
			const CumulativeWork = buffer.create(Height * 4)
			const RowToWorker = buffer.create(Height)
			const BandStarts = table.create(WorkerCount, 0) :: { number }
			const BandEnds = table.create(WorkerCount, 0) :: { number }

			-- Simulate 420 sky rows, 180 horizon untextured cluster rows, and 400 bottom textured floor rows
			for t = 1, 900 do
				const MinY = 420 + (t % 160) :: number
				WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, 100, 140, MinY, MinY + 18, 0)
			end
			WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, 0, 999, 580, 999, 1)
			WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, 0, 999, 580, 999, 1)

			WorkerPartitionHelper.PartitionWorkerBands(
				RowWorkDiff, CumulativeWork, RowToWorker, Height, WorkerCount, BandStarts, BandEnds
			)

			expect(BandStarts[1]).to.equal(0)
			expect(BandEnds[1] < 575).to.equal(true)
			expect(BandEnds[1] + 1).to.equal(BandStarts[2])
			expect(BandEnds[2] + 1).to.equal(BandStarts[3])
			expect(BandEnds[3]).to.equal(Height - 1)
		end)

		it("should assign smaller contiguous near-clip chunks to Worker 1 while preserving total entity count", function()
			const OutCounts = table.create(3, 0) :: { number }
			const UsedWorkers = WorkerPartitionHelper.ComputeStageChunkCounts(174, 3, OutCounts)
			expect(UsedWorkers).to.equal(3)
			expect(OutCounts[1] < OutCounts[2]).to.equal(true)
			expect(OutCounts[1] + OutCounts[2] + OutCounts[3]).to.equal(174)
		end)

		it("should coalesce single-worker triangle runs and reuse exact-sized worker scatter slices", function()
			const RowToWorker = buffer.create(100)
			buffer.fill(RowToWorker, 0, 1, 50)
			buffer.fill(RowToWorker, 50, 2, 50)

			const UTris = buffer.create(3 * 32)
			const UBounds = buffer.create(3 * 4)
			buffer.writeu32(UTris, 0 + 24, 0xFF000001)
			buffer.writeu32(UTris, 32 + 24, 0xFF000002)
			buffer.writeu32(UTris, 64 + 24, 0xFF000003)
			buffer.writeu16(UBounds, 0, 10); buffer.writeu16(UBounds, 2, 20) -- W1
			buffer.writeu16(UBounds, 4, 15); buffer.writeu16(UBounds, 6, 30) -- W1 (coalesced run)
			buffer.writeu16(UBounds, 8, 45); buffer.writeu16(UBounds, 10, 55) -- W1 + W2 seam

			const OutUSlices = {} :: { buffer }
			const OutUBytes = { 0, 0 } :: { number }
			const OutTSlices = {} :: { buffer }
			const OutTBytes = { 0, 0 } :: { number }

			WorkerPartitionHelper.ScatterDualChunksToWorkers(
				{ UTris }, { UBounds }, { 3 },
				{ buffer.create(0) }, { buffer.create(0) }, { 0 },
				1, RowToWorker, 100, 2,
				OutUSlices, OutUBytes, OutTSlices, OutTBytes
			)
			const FirstSliceRef = OutUSlices[1]
			expect(OutUBytes[1]).to.equal(96)
			expect(OutUBytes[2]).to.equal(32)
			expect(buffer.readu32(OutUSlices[1], 0 + 24)).to.equal(0xFF000001)
			expect(buffer.readu32(OutUSlices[1], 32 + 24)).to.equal(0xFF000002)
			expect(buffer.readu32(OutUSlices[1], 64 + 24)).to.equal(0xFF000003)
			expect(buffer.readu32(OutUSlices[2], 0 + 24)).to.equal(0xFF000003)

			-- Second call with identical byte counts must reuse the exact buffer instance
			WorkerPartitionHelper.ScatterDualChunksToWorkers(
				{ UTris }, { UBounds }, { 3 },
				{ buffer.create(0) }, { buffer.create(0) }, { 0 },
				1, RowToWorker, 100, 2,
				OutUSlices, OutUBytes, OutTSlices, OutTBytes
			)
			expect(OutUSlices[1]).to.equal(FirstSliceRef)
		end)
	end)
end
