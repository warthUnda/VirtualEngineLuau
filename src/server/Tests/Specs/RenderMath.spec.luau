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
	const MathModule = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("MathModule"))
	const BufferHelper = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("BufferHelper"))
	const VerticeFile = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("VerticeFile"))
	const TextureTable = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable"))
	const RenderMath = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("RenderMath"))
	const RenderControllerHelper = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Controller"):WaitForChild("RenderControllerHelper"))
	const WorkerPartitionHelper = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Controller"):WaitForChild("WorkerPartitionHelper"))

	describe("1. 2D Edge Functions & Geometric Tests", function()
		it("should return correct signed determinant for 2D edge queries", function()
			-- Directed edge from (0, 0) to (10, 0)
			const Above = MathModule.EdgeFunction(0, 0, 10, 0, 5, 5)
			const Below = MathModule.EdgeFunction(0, 0, 10, 0, 5, -5)
			const OnEdge = MathModule.EdgeFunction(0, 0, 10, 0, 5, 0)

			expect(Above < 0).to.equal(true)
			expect(Below > 0).to.equal(true)
			expect(OnEdge).to.equal(0)
		end)
	end)

	describe("2. Camera-Space Frustum Guardband & Projection", function()
		it("should reject vertices behind the near plane or beyond far plane", function()
			const BehindNear = vector.create(0, 0, 0.05) -- < 0.1 near clip
			const InFront = vector.create(0, 0, 10)
			const BeyondFar = vector.create(0, 0, 50000)

			expect(MathModule.IsVertexInside(BehindNear, 1.5, 1.5)).to.equal(false)
			expect(MathModule.IsVertexInside(InFront, 1.5, 1.5)).to.equal(true)
			expect(MathModule.IsVertexInside(BeyondFar, 1.5, 1.5)).to.equal(false)
		end)

		it("should project 3D camera-space vertices onto integer 2D screen coordinates", function()
			const OutBuffer = buffer.create(20)
			const Vertex = vector.create(2, 4, 10)
			const FocalLength = 100 :: number
			const HalfW = 160 :: number
			const HalfH = 120 :: number

			MathModule.ProjectVertexUV(OutBuffer, 0, Vertex, 0, 0, FocalLength, HalfW, HalfH)

			const ProjX = buffer.readf32(OutBuffer, 0)
			const ProjY = buffer.readf32(OutBuffer, 4)
			const InvZ = buffer.readf32(OutBuffer, 8)

			-- Expected: X = floor(2/10 * 100 + 160) = 180
			-- Expected: Y = floor(-4/10 * 100 + 120) = 80
			expect(ProjX).to.equal(180)
			expect(ProjY).to.equal(80)
			expect(InvZ).to.be.near(0.1, 1e-4)
		end)
	end)

	describe("3. Sutherland-Hodgman Polygon Clipping", function()
		it("should clip a triangle straddling a plane and produce a quad", function()
			const InputBuf = buffer.create(3 * 20)
			const OutputBuf = buffer.create(6 * 20)

			-- Triangle vertices: (0, 0, 2), (2, 0, -2), (-2, 0, -2) straddling plane Z = 0
			BufferHelper.WriteVec3(InputBuf, 0, vector.create(0, 0, 2))
			BufferHelper.WriteVec3(InputBuf, 20, vector.create(2, 0, -2))
			BufferHelper.WriteVec3(InputBuf, 40, vector.create(-2, 0, -2))

			-- Plane normal (0, 0, 1) offset 0 (keeps vertices with Z >= 0)
			const ClippedCount = MathModule.ClipPolygonUV(InputBuf, 3, OutputBuf, vector.create(0, 0, 1), 0)
			-- Triangle crossing plane creates 3 vertices inside half-space
			expect(ClippedCount).to.equal(3)
		end)
	end)

	describe("4. Buffer Helper Operations & SIMD Serialization", function()
		it("should round-trip vector3 values accurately through buffers", function()
			const TestBuf = buffer.create(12)
			const Original = vector.create(123.45, -678.9, 0.001)

			BufferHelper.WriteVec3(TestBuf, 0, Original)
			const ReadBack = BufferHelper.ReadVec3(TestBuf, 0)

			expect(math.abs(ReadBack.x - Original.x) < 1e-3).to.equal(true)
			expect(math.abs(ReadBack.y - Original.y) < 1e-3).to.equal(true)
			expect(math.abs(ReadBack.z - Original.z) < 1e-3).to.equal(true)
		end)

		it("should clear pixel and Z buffers cleanly", function()
			const PixBuf = buffer.create(16)
			const ZBuf = buffer.create(16)

			buffer.fill(PixBuf, 0, 255, 16)
			buffer.fill(ZBuf, 0, 255, 16)

			BufferHelper.ClearBuffers(4, PixBuf, ZBuf)

			-- Z buffer must be all zeroes
			for i = 0, 12, 4 do
				expect(buffer.readf32(ZBuf, i)).to.equal(0)
			end
		end)
	end)

	describe("5. Perspective-Correct Texture Mapping & UV Clipping", function()
		it("should project UV coordinates alongside screen positions", function()
			const OutBuffer = buffer.create(20)
			const Vertex = vector.create(2, 4, 10)

			MathModule.ProjectVertexUV(OutBuffer, 0, Vertex, 0.75, 0.25, 100, 160, 120)

			expect(buffer.readf32(OutBuffer, 0)).to.equal(180)
			expect(buffer.readf32(OutBuffer, 4)).to.equal(80)
			expect(buffer.readf32(OutBuffer, 8)).to.be.near(0.1, 1e-4)
			expect(buffer.readf32(OutBuffer, 12)).to.be.near(0.75, 1e-4)
			expect(buffer.readf32(OutBuffer, 16)).to.be.near(0.25, 1e-4)
		end)

		it("should interpolate UVs when clipping a polygon against a plane", function()
			const InputBuf = buffer.create(3 * 20)
			const OutputBuf = buffer.create(6 * 20)

			-- Vertex 0 at Z = 2, UV = (0, 0)
			BufferHelper.WriteVec3(InputBuf, 0, vector.create(0, 0, 2))
			buffer.writef32(InputBuf, 12, 0)
			buffer.writef32(InputBuf, 16, 0)

			-- Vertex 1 at Z = -2, UV = (1, 0)
			BufferHelper.WriteVec3(InputBuf, 20, vector.create(2, 0, -2))
			buffer.writef32(InputBuf, 32, 1)
			buffer.writef32(InputBuf, 36, 0)

			-- Vertex 2 at Z = -2, UV = (0, 1)
			BufferHelper.WriteVec3(InputBuf, 40, vector.create(-2, 0, -2))
			buffer.writef32(InputBuf, 52, 0)
			buffer.writef32(InputBuf, 56, 1)

			const ClippedCount = MathModule.ClipPolygonUV(InputBuf, 3, OutputBuf, vector.create(0, 0, 1), 0)
			expect(ClippedCount).to.equal(3)
			-- Output slot 0 is intersection of V2 -> V0: UV = (0, 0.5)
			expect(buffer.readf32(OutputBuf, 16)).to.be.near(0.5, 1e-4)
			-- Output slot 2 is intersection of V0 -> V1: UV = (0.5, 0)
			expect(buffer.readf32(OutputBuf, 40 + 12)).to.be.near(0.5, 1e-4)
		end)

		it("should rasterize textured triangles with solid texture buffers", function()
			-- Fill a 2x2 solid red texture to verify tinting + sampling
			const SolidTex = buffer.create(2 * 2 * 4)
			for i = 0, 12, 4 do
				buffer.writeu32(SolidTex, i, 0xFF0000FF) -- RGBA (255, 0, 0, 255)
			end

			const PixBuf = buffer.create(16 * 16 * 4)
			const ZBuf = buffer.create(16 * 16 * 4)
			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)

			-- Winding for positive area: (Vertex2X - Vertex0X)*(Vertex1Y - Vertex0Y) - (Vertex2Y - Vertex0Y)*(Vertex1X - Vertex0X) > 0
			-- V0=(2,2), V1=(2,10), V2=(10,2) -> (8)*(8) - (0)*(0) = 64
			const Area = 64 :: number
			const InvArea = 1 / Area :: number
			const WhiteColor = 0xFFFFFFFF :: number

			MathModule.RasterizeTriangleSpan(
				2, 2, InvArea, 0, 0,
				2, 10, InvArea, 0, InvArea,
				10, 2, InvArea, InvArea, 0,
				WhiteColor,
				SolidTex,
				2,
				2,
				16,
				16,
				16 * 4,
				PixBuf,
				ZBuf
			)

			-- Pixel at (3, 3) is inside the triangle and should be red (255, 0, 0, 255)
			const Sampled = buffer.readu32(PixBuf, (3 * 16 + 3) * 4)
			expect(bit32.band(Sampled, 0xFF)).to.equal(255)
			expect(bit32.band(bit32.rshift(Sampled, 8), 0xFF)).to.equal(0)
			expect(bit32.band(bit32.rshift(Sampled, 16), 0xFF)).to.equal(0)
		end)

		it("should translate texture IDs and deduplicate URLs in TextureTable", function()
			-- Snapshot live Workspace decal entries so this unit test does not disturb runtime state
			const SavedEntries = table.clone(TextureTable.Entries)
			const SavedIdToName = table.clone(TextureTable.IdToName)
			const SavedNameToId = table.clone(TextureTable.NameToId)
			const SavedIdToUrl = table.clone(TextureTable.IdToUrl)
			const SavedUrlToId = table.clone(TextureTable.UrlToId)
			const SavedCachedBuffers = table.clone(TextureTable.CachedBuffers)

			TextureTable.ResetEntries()
			expect(TextureTable.TranslateIdToName(1)).to.equal("")
			expect(TextureTable.GetTextureBuffer(1)).to.equal(nil)

			const DecodedEmpty, WasDecoded = TextureTable.DecodeRawUrl("")
			expect(DecodedEmpty).to.equal(nil)
			expect(WasDecoded).to.equal(false)

			-- Test dynamic URL registration & duplicate URL ignoring
			TextureTable.ResetEntries()
			const FirstId: number, FirstCreated: boolean = TextureTable.RegisterUrl("rbxassetid://111111", "TestDecalA", false)
			const DupId: number, DupCreated: boolean = TextureTable.RegisterUrl("rbxassetid://111111", "TestDecalDup", false)
			const SecondId: number, SecondCreated: boolean = TextureTable.RegisterUrl("rbxassetid://222222", "TestDecalB", false)

			expect(FirstId).to.equal(1)
			expect(FirstCreated).to.equal(true)
			expect(DupId).to.equal(1)
			expect(DupCreated).to.equal(false)
			expect(SecondId).to.equal(2)
			expect(SecondCreated).to.equal(true)
			expect(TextureTable.TranslateIdToName(1)).to.equal("TestDecalA")
			expect(TextureTable.TranslateNameToId("TestDecalB")).to.equal(2)
			expect(TextureTable.Entries[1].Url).to.equal("rbxassetid://111111")
			expect(TextureTable.Entries[1].Name).to.equal("TestDecalA")
			expect(TextureTable.Entries[2].Url).to.equal("rbxassetid://222222")
			expect(TextureTable.Entries[2].Name).to.equal("TestDecalB")

			-- Restore previous entries so runtime Workspace decals remain intact
			TextureTable.ResetEntries()
			for Id: number, Entry in pairs(SavedEntries) do
				TextureTable.Entries[Id] = Entry
			end
			for Id: number, Name: string in pairs(SavedIdToName) do
				TextureTable.IdToName[Id] = Name
			end
			for Name: string, Id: number in pairs(SavedNameToId) do
				TextureTable.NameToId[Name] = Id
			end
			for Id: number, Url: string in pairs(SavedIdToUrl) do
				TextureTable.IdToUrl[Id] = Url
			end
			for Url: string, Id: number in pairs(SavedUrlToId) do
				TextureTable.UrlToId[Url] = Id
			end
			for Id: number, Buf: buffer in pairs(SavedCachedBuffers) do
				TextureTable.CachedBuffers[Id] = Buf
			end

			-- Verify RenderMath.DrawTriangleBatch selects per-triangle textures by TextureId
			const SolidGreen = buffer.create(2 * 2 * 4)
			const SolidBlue = buffer.create(2 * 2 * 4)
			for i = 0, 12, 4 do
				buffer.writeu32(SolidGreen, i, 0xFF00FF00)
				buffer.writeu32(SolidBlue, i, 0xFFFF0000)
			end
			const BatchTextures = {
				[1] = SolidGreen,
				[2] = SolidBlue,
			}

			const CmdBuf = buffer.create(56)
			const Area = 64 :: number
			const InvArea = 1 / Area :: number
			local function WriteTriCmd(TexId: number, Color: number)
				buffer.writei16(CmdBuf, 0, 2)
				buffer.writei16(CmdBuf, 2, 2)
				buffer.writef32(CmdBuf, 4, InvArea)
				buffer.writef32(CmdBuf, 8, 0)
				buffer.writef32(CmdBuf, 12, 0)
				buffer.writei16(CmdBuf, 16, 2)
				buffer.writei16(CmdBuf, 18, 10)
				buffer.writef32(CmdBuf, 20, InvArea)
				buffer.writef32(CmdBuf, 24, 0)
				buffer.writef32(CmdBuf, 28, InvArea)
				buffer.writei16(CmdBuf, 32, 10)
				buffer.writei16(CmdBuf, 34, 2)
				buffer.writef32(CmdBuf, 36, InvArea)
				buffer.writef32(CmdBuf, 40, InvArea)
				buffer.writef32(CmdBuf, 44, 0)
				buffer.writeu32(CmdBuf, 48, Color)
				buffer.writeu32(CmdBuf, 52, TexId)
			end
			WriteTriCmd(2, 0xFFFFFFFF)

			const PixBuf = buffer.create(16 * 16 * 4)
			const ZBuf = buffer.create(16 * 16 * 4)
			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)

			RenderMath.DrawTriangleBatch(CmdBuf, 56, BatchTextures, 2, 2, 16, 16, PixBuf, ZBuf)
			const Sampled = buffer.readu32(PixBuf, (3 * 16 + 3) * 4)
			expect(bit32.band(Sampled, 0xFF)).to.equal(0)
			expect(bit32.band(bit32.rshift(Sampled, 8), 0xFF)).to.equal(0)
			expect(bit32.band(bit32.rshift(Sampled, 16), 0xFF)).to.equal(255)

			-- Verify TextureId = 0 renders untextured solid PackedColor
			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)
			WriteTriCmd(0, 0xFF112233)
			RenderMath.DrawTriangleBatch(CmdBuf, 56, BatchTextures, 2, 2, 16, 16, PixBuf, ZBuf)
			expect(buffer.readu32(PixBuf, (3 * 16 + 3) * 4)).to.equal(0xFF112233)

			-- Verify band-clamped rasterization + CompositeWorkerBand only touches band rows
			const WorkerBandPix = buffer.create(16 * 8 * 4)
			const WorkerBandZ = buffer.create(16 * 8 * 4)
			BufferHelper.ClearBuffers(16 * 8, WorkerBandPix, WorkerBandZ)
			RenderMath.DrawTriangleBatch(CmdBuf, 56, BatchTextures, 2, 2, 16, 16, WorkerBandPix, WorkerBandZ, 4, 11)

			const FinalPix = buffer.create(16 * 16 * 4)
			buffer.fill(FinalPix, 0, 0)
			BufferHelper.CompositeWorkerBand(FinalPix, WorkerBandPix, 16, 4, 11, 4, 11)
			expect(buffer.readu32(FinalPix, (5 * 16 + 3) * 4)).to.equal(0xFF112233)
			expect(buffer.readu32(FinalPix, (3 * 16 + 3) * 4)).to.equal(0)
		end)

		it("should expose all 5 unit shape meshes and face UV axis indices from VerticeFile", function()
			expect(VerticeFile.GetShapeName(0)).to.equal("Cube")
			expect(VerticeFile.GetShapeName(1)).to.equal("Sphere")
			expect(VerticeFile.GetShapeName(2)).to.equal("Cylinder")
			expect(VerticeFile.GetShapeName(3)).to.equal("Triangle")
			expect(VerticeFile.GetShapeName(4)).to.equal("Plane")
			const CubeShape = VerticeFile.GetShapeData(0)
			expect(CubeShape.IsAxisAligned).to.equal(true)
			expect(VerticeFile.GetShapeData(1).IsAxisAligned).to.equal(false)
			expect(VerticeFile.GetShapeData(4).IsAxisAligned).to.equal(true)
			for _, Face in CubeShape.Faces do
				expect(Face.UAxisIndex >= 1 and Face.UAxisIndex <= 3).to.equal(true)
				expect(Face.VAxisIndex >= 1 and Face.VAxisIndex <= 3).to.equal(true)
				expect(Face.UAxisIndex ~= Face.VAxisIndex).to.equal(true)
			end
		end)

		it("should reject OBBs outside camera-space X/Y frustum guardband", function()
			const CubeShape = VerticeFile.GetShapeData(0)
			const VertexCount = #CubeShape.LocalVertices
			const PosBuf = buffer.create(12)
			const SizeBuf = buffer.create(12)
			const DirBuf = buffer.create(36)
			const CamVertsBuf = buffer.create(VertexCount * 12)

			BufferHelper.WriteVec3(PosBuf, 0, vector.create(0, 0, -20))
			BufferHelper.WriteVec3(SizeBuf, 0, vector.create(2, 2, 2))
			BufferHelper.WriteVec3(DirBuf, 0, vector.create(0, 0, -1))
			BufferHelper.WriteVec3(DirBuf, 12, vector.create(0, 1, 0))
			BufferHelper.WriteVec3(DirBuf, 24, vector.create(1, 0, 0))

			const OnScreen = RenderMath.TransformShapeCameraVertices(
				PosBuf,
				DirBuf,
				SizeBuf,
				0,
				0,
				CubeShape.LocalVertices,
				VertexCount,
				CamVertsBuf,
				vector.create(0, 0, 0),
				vector.create(1, 0, 0),
				vector.create(0, 1, 0),
				vector.create(0, 0, -1),
				vector.create(0, 1, 0),
				1.0,
				1.0
			)
			expect(OnScreen).to.equal(true)

			BufferHelper.WriteVec3(PosBuf, 0, vector.create(100, 0, -20))
			const OffScreenRight = RenderMath.TransformShapeCameraVertices(
				PosBuf,
				DirBuf,
				SizeBuf,
				0,
				0,
				CubeShape.LocalVertices,
				VertexCount,
				CamVertsBuf,
				vector.create(0, 0, 0),
				vector.create(1, 0, 0),
				vector.create(0, 1, 0),
				vector.create(0, 0, -1),
				vector.create(0, 1, 0),
				1.0,
				1.0
			)
			expect(OffScreenRight).to.equal(false)
		end)
	end)

	describe("6. Render Target FPS Config & Frame Pacing Accumulator", function()
		it("should expose RenderTargetFPS set to 40 in RenderConfig and SystemsConfigs", function()
			expect(SystemsConfigs.RenderTargetFPS).to.equal(40)
			expect(SystemsConfigs.Render.RenderTargetFPS).to.equal(40)
		end)

		it("should pace 60 Hz and 120 Hz RenderStepped ticks to exact 40 FPS without drift", function()
			const TargetInterval = 1 / (SystemsConfigs.RenderTargetFPS :: number) :: number

			local Accumulator60 = 0 :: number
			local DrawnAt60Hz = 0 :: number
			for _ = 1, 600 do
				local ShouldDraw = false :: boolean
				ShouldDraw, Accumulator60 =
					RenderControllerHelper.StepFrameAccumulator(Accumulator60, 1 / 60, TargetInterval, false)
				if ShouldDraw then
					DrawnAt60Hz += 1
				end
			end
			expect(DrawnAt60Hz).to.equal(400)

			local Accumulator120 = 0 :: number
			local DrawnAt120Hz = 0 :: number
			for _ = 1, 120 do
				local ShouldDraw = false :: boolean
				ShouldDraw, Accumulator120 =
					RenderControllerHelper.StepFrameAccumulator(Accumulator120, 1 / 120, TargetInterval, false)
				if ShouldDraw then
					DrawnAt120Hz += 1
				end
			end
			expect(DrawnAt120Hz).to.equal(40)
		end)

		it("should prevent catch-up bursts after lag spikes and preserve readiness when workers are in flight", function()
			const TargetInterval = 0.025 :: number

			-- 250ms lag spike should draw once and clamp remainder below one interval
			local ShouldDrawSpike = false :: boolean
			local RemainderAfterSpike = 0 :: number
			ShouldDrawSpike, RemainderAfterSpike =
				RenderControllerHelper.StepFrameAccumulator(0, 0.25, TargetInterval, false)
			expect(ShouldDrawSpike).to.equal(true)
			expect(RemainderAfterSpike < TargetInterval).to.equal(true)

			local ShouldDrawNextTick = false :: boolean
			ShouldDrawNextTick, RemainderAfterSpike =
				RenderControllerHelper.StepFrameAccumulator(RemainderAfterSpike, 1 / 60, TargetInterval, false)
			expect(ShouldDrawNextTick).to.equal(false)

			-- When workers are still in flight at budget threshold, hold primed at TargetInterval
			local ShouldDrawBlocked = false :: boolean
			local HeldAccumulator = 0 :: number
			ShouldDrawBlocked, HeldAccumulator =
				RenderControllerHelper.StepFrameAccumulator(0.01667, 0.01667, TargetInterval, true)
			expect(ShouldDrawBlocked).to.equal(false)
			expect(HeldAccumulator).to.equal(TargetInterval)

			local ShouldDrawUnblocked = false :: boolean
			ShouldDrawUnblocked, HeldAccumulator =
				RenderControllerHelper.StepFrameAccumulator(HeldAccumulator, 1 / 60, TargetInterval, false)
			expect(ShouldDrawUnblocked).to.equal(true)

			-- Uncapped interval (<= 0) draws every unblocked tick
			const UncappedOpen, UncappedRem = RenderControllerHelper.StepFrameAccumulator(0, 1 / 60, 0, false)
			const UncappedBlocked, _ = RenderControllerHelper.StepFrameAccumulator(0, 1 / 60, 0, true)
			expect(UncappedOpen).to.equal(true)
			expect(UncappedRem).to.equal(0)
			expect(UncappedBlocked).to.equal(false)
		end)
	end)

	describe("7. Dynamic Parallel Worker Load Balancing & Exact Z-Buffer Invariance", function()
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

			-- Pack all 60 triangles tightly inside the horizon band Y = 38..61 (24 rows)
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

			-- Contiguous, gap-free full-height partition
			expect(BandStarts[1]).to.equal(0)
			expect(BandEnds[1] + 1).to.equal(BandStarts[2])
			expect(BandEnds[2] + 1).to.equal(BandStarts[3])
			expect(BandEnds[3]).to.equal(Height - 1)

			-- All 3 workers receive a balanced share instead of 0 / 60 / 0
			const Count1 = WorkerOffsets[1] // Stride :: number
			const Count2 = WorkerOffsets[2] // Stride :: number
			const Count3 = WorkerOffsets[3] // Stride :: number
			expect(Count1 >= 15 and Count1 <= 30).to.equal(true)
			expect(Count2 >= 15 and Count2 <= 30).to.equal(true)
			expect(Count3 >= 15 and Count3 <= 30).to.equal(true)

			-- RowWorkDiff must be zeroed for next frame
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

			-- Build 3 overlapping triangles in [Y = 8..26]:
			-- 1) Near untextured quad/tri (InvZ = 0.5) occluding center
			-- 2) Farther textured wide tri (InvZ = 0.2) spanning >16px across occluded + visible regions
			-- 3) Closest foreground small tri (InvZ = 0.8) overwriting both
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

			-- Reference single-buffer render
			const RefPixels = buffer.create(TotalPixels * 4)
			const RefZ = buffer.create(TotalPixels * 4)
			BufferHelper.ClearBuffers(TotalPixels, RefPixels, RefZ)
			RenderMath.DrawTriangleBatch(StagedTris, 3 * Stride, TexMap, 4, 4, Width, Height, RefPixels, RefZ)

			-- Verify closer triangle (0.8) overwrote 0.5, and 0.2 did NOT overwrite 0.5
			expect(buffer.readu32(RefPixels, (13 * Width + 11) * 4)).to.equal(0xFFDD5511)
			expect(buffer.readu32(RefPixels, (11 * Width + 7) * 4)).to.equal(0xFF228833)

			-- Dynamic multi-worker render + compact slice composite
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
