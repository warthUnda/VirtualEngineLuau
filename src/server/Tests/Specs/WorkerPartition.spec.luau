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

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")

	-- Libraries --
	const BufferHelper = require(RenderRoot:WaitForChild("Core"):WaitForChild("BufferHelper"))
	const RenderMath = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderMath"))
	const WorkerPartitionHelper = require(RenderRoot:WaitForChild("Controller"):WaitForChild("WorkerPartitionHelper"))

	describe("1. Dynamic Parallel Worker Load Balancing & Exact Z-Buffer Invariance", function()
		it("should evenly split horizon-clustered triangles across all 3 workers instead of overloading 1 actor", function()
			const Height = 100 :: number
			const WorkerCount = 3 :: number
			const Stride = 56 :: number
			const TriangleCount = 60 :: number
			const Capacity = TriangleCount * Stride :: number

			const RowWorkDiff = buffer.create((Height + 1) * 4)
			const CumulativeWork = buffer.create(Height * 4)
			const RowToWorker = buffer.create(Height)
			const StagedTriangles = buffer.create(Capacity)
			const StagedBounds = buffer.create(TriangleCount * 4)
			const BandStarts = table.create(WorkerCount, 0) :: { number }
			const BandEnds = table.create(WorkerCount, 0) :: { number }
			const WorkerOffsets = table.create(WorkerCount, 0) :: { number }
			const BufferTable = {
				buffer.create(Capacity),
				buffer.create(Capacity),
				buffer.create(Capacity),
			} :: { buffer }

			for idx = 0, TriangleCount - 1 do
				const MinY = 38 + (idx % 22) :: number
				const MaxY = MinY + 2 :: number
				buffer.writeu16(StagedBounds, idx * 4, MinY)
				buffer.writeu16(StagedBounds, idx * 4 + 2, MaxY)
				buffer.writeu32(StagedTriangles, idx * Stride + 48, 0xFF112233 + idx)
				WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, 10, 89, MinY, MaxY, 1)
			end

			WorkerPartitionHelper.PartitionWorkerBands(
				RowWorkDiff,
				CumulativeWork,
				RowToWorker,
				Height,
				WorkerCount,
				BandStarts,
				BandEnds
			)
			WorkerPartitionHelper.DispatchStagedTriangles(
				StagedTriangles,
				StagedBounds,
				TriangleCount,
				RowToWorker,
				WorkerOffsets,
				BufferTable,
				Capacity
			)

			expect(BandStarts[1]).to.equal(0)
			expect(BandEnds[1] + 1).to.equal(BandStarts[2])
			expect(BandEnds[2] + 1).to.equal(BandStarts[3])
			expect(BandEnds[3]).to.equal(Height - 1)

			const Count1 = WorkerOffsets[1] // Stride :: number
			const Count2 = WorkerOffsets[2] // Stride :: number
			const Count3 = WorkerOffsets[3] // Stride :: number
			expect(Count1 >= 15 and Count1 <= 30).to.equal(true)
			expect(Count2 >= 15 and Count2 <= 30).to.equal(true)
			expect(Count3 >= 15 and Count3 <= 30).to.equal(true)

			for Y = 0, Height do
				expect(buffer.readi32(RowWorkDiff, Y * 4)).to.equal(0)
			end
		end)

		it("should produce bit-for-bit identical Z-buffered pixels across dynamic worker bands and occluded textured spans", function()
			const Width = 32 :: number
			const Height = 32 :: number
			const WorkerCount = 3 :: number
			const Stride = 56 :: number
			const TotalPixels = Width * Height :: number

			const CheckerTex = buffer.create(4 * 4 * 4)
			for TexY = 0, 3 do
				for TexX = 0, 3 do
					const IsLight = ((TexX + TexY) % 2 == 0) :: boolean
					const Color = if IsLight then 0xFF44AAFF else 0xFFCC2244 :: number
					buffer.writeu32(CheckerTex, (TexY * 4 + TexX) * 4, Color)
				end
			end
			const TexMap = { [1] = CheckerTex }

			const StagedTris = buffer.create(3 * Stride)
			const StagedBounds = buffer.create(3 * 4)
			const RowWorkDiff = buffer.create((Height + 1) * 4)

			local function WriteTestTri(
				Slot: number,
				X0: number,
				Y0: number,
				X1: number,
				Y1: number,
				X2: number,
				Y2: number,
				InvZ: number,
				Color: number,
				TexId: number
			)
				const Area = (X2 - X0) * (Y1 - Y0) - (Y2 - Y0) * (X1 - X0) :: number
				const ScaledInvZ = InvZ / Area :: number
				const Base = Slot * Stride :: number
				buffer.writei16(StagedTris, Base, X0)
				buffer.writei16(StagedTris, Base + 2, Y0)
				buffer.writef32(StagedTris, Base + 4, ScaledInvZ)
				buffer.writef32(StagedTris, Base + 8, 0)
				buffer.writef32(StagedTris, Base + 12, 0)

				buffer.writei16(StagedTris, Base + 16, X1)
				buffer.writei16(StagedTris, Base + 18, Y1)
				buffer.writef32(StagedTris, Base + 20, ScaledInvZ)
				buffer.writef32(StagedTris, Base + 24, 0)
				buffer.writef32(StagedTris, Base + 28, ScaledInvZ)

				buffer.writei16(StagedTris, Base + 32, X2)
				buffer.writei16(StagedTris, Base + 34, Y2)
				buffer.writef32(StagedTris, Base + 36, ScaledInvZ)
				buffer.writef32(StagedTris, Base + 40, ScaledInvZ)
				buffer.writef32(StagedTris, Base + 44, 0)

				buffer.writeu32(StagedTris, Base + 48, Color)
				buffer.writeu32(StagedTris, Base + 52, TexId)

				const MinX = math.min(X0, X1, X2) :: number
				const MaxX = math.max(X0, X1, X2) :: number
				const MinY = math.min(Y0, Y1, Y2) :: number
				const MaxY = math.max(Y0, Y1, Y2) :: number
				buffer.writeu16(StagedBounds, Slot * 4, MinY)
				buffer.writeu16(StagedBounds, Slot * 4 + 2, MaxY)
				WorkerPartitionHelper.RecordTriangleRowWork(RowWorkDiff, MinX, MaxX, MinY, MaxY, TexId)
			end

			WriteTestTri(0, 6, 10, 6, 24, 24, 10, 0.5, 0xFF228833, 0)
			WriteTestTri(1, 2, 8, 2, 28, 30, 8, 0.2, 0xFFCCCCCC, 1)
			WriteTestTri(2, 10, 12, 10, 20, 20, 12, 0.8, 0xFFDD5511, 0)

			const RefPixels = buffer.create(TotalPixels * 4)
			const RefZ = buffer.create(TotalPixels * 4)
			BufferHelper.ClearBuffers(TotalPixels, RefPixels, RefZ)
			RenderMath.DrawTriangleBatch(StagedTris, 3 * Stride, TexMap, 4, 4, Width, Height, RefPixels, RefZ)

			expect(buffer.readu32(RefPixels, (13 * Width + 11) * 4)).to.equal(0xFFDD5511)
			expect(buffer.readu32(RefPixels, (11 * Width + 7) * 4)).to.equal(0xFF228833)

			const CumulativeWork = buffer.create(Height * 4)
			const RowToWorker = buffer.create(Height)
			const BandStarts = table.create(WorkerCount, 0) :: { number }
			const BandEnds = table.create(WorkerCount, 0) :: { number }
			const WorkerOffsets = table.create(WorkerCount, 0) :: { number }
			const WorkerCmds = {
				buffer.create(3 * Stride),
				buffer.create(3 * Stride),
				buffer.create(3 * Stride),
			} :: { buffer }

			WorkerPartitionHelper.PartitionWorkerBands(
				RowWorkDiff,
				CumulativeWork,
				RowToWorker,
				Height,
				WorkerCount,
				BandStarts,
				BandEnds
			)
			WorkerPartitionHelper.DispatchStagedTriangles(
				StagedTris,
				StagedBounds,
				3,
				RowToWorker,
				WorkerOffsets,
				WorkerCmds,
				3 * Stride
			)

			const FinalPixels = buffer.create(TotalPixels * 4)
			const RowStride = Width * 4 :: number
			for w = 1, WorkerCount do
				const WorkerPix = buffer.create(TotalPixels * 4)
				const WorkerZ = buffer.create(TotalPixels * 4)
				BufferHelper.ClearBuffers(TotalPixels, WorkerPix, WorkerZ)

				const BStart = BandStarts[w] :: number
				const BEnd = BandEnds[w] :: number
				local DMin = Height :: number
				local DMax = -1 :: number
				if WorkerOffsets[w] > 0 and BStart <= BEnd then
					DMin, DMax = RenderMath.DrawTriangleBatch(
						WorkerCmds[w],
						WorkerOffsets[w],
						TexMap,
						4,
						4,
						Width,
						Height,
						WorkerPix,
						WorkerZ,
						BStart,
						BEnd
					)
				end

				if DMin <= DMax then
					const ClampedMin = math.max(BStart, DMin) :: number
					const ClampedMax = math.min(BEnd, DMax) :: number
					const DirtyBytes = (ClampedMax - ClampedMin + 1) * RowStride :: number
					const CompactSlice = buffer.create(DirtyBytes)
					buffer.copy(CompactSlice, 0, WorkerPix, (ClampedMin - BStart) * RowStride, DirtyBytes)
					BufferHelper.CompositeWorkerBand(FinalPixels, CompactSlice, Width, BStart, BEnd, ClampedMin, ClampedMax, true)
				else
					BufferHelper.CompositeWorkerBand(FinalPixels, buffer.create(0), Width, BStart, BEnd, DMin, DMax, true)
				end
			end

			for Offset = 0, TotalPixels * 4 - 4, 4 do
				expect(buffer.readu32(FinalPixels, Offset)).to.equal(buffer.readu32(RefPixels, Offset))
			end
		end)
	end)
end
