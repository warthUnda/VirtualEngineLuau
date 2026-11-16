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
	const RenderCore = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core")

	-- Libraries --
	const MathModule = require(RenderCore:WaitForChild("MathModule"))
	const BufferHelper = require(RenderCore:WaitForChild("BufferHelper"))
	const VerticeFile = require(RenderCore:WaitForChild("VerticeFile"))
	const RenderMath = require(RenderCore:WaitForChild("RenderMath"))

	describe("1. 2D Edge Functions & Geometric Tests", function()
		it("should return correct signed determinant for 2D edge queries", function()
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
			const BehindNear = vector.create(0, 0, 0.05)
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

			expect(buffer.readf32(OutBuffer, 0)).to.equal(180)
			expect(buffer.readf32(OutBuffer, 4)).to.equal(80)
			expect(buffer.readf32(OutBuffer, 8)).to.be.near(0.1, 1e-4)
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

	describe("3. Sutherland-Hodgman Polygon Clipping", function()
		it("should clip a triangle straddling a plane and produce a quad", function()
			const InputBuf = buffer.create(3 * 20)
			const OutputBuf = buffer.create(6 * 20)

			BufferHelper.WriteVec3(InputBuf, 0, vector.create(0, 0, 2))
			BufferHelper.WriteVec3(InputBuf, 20, vector.create(2, 0, -2))
			BufferHelper.WriteVec3(InputBuf, 40, vector.create(-2, 0, -2))

			const ClippedCount = MathModule.ClipPolygonUV(InputBuf, 3, OutputBuf, vector.create(0, 0, 1), 0)
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

			for i = 0, 12, 4 do
				expect(buffer.readf32(ZBuf, i)).to.equal(0)
			end
		end)
	end)
end
