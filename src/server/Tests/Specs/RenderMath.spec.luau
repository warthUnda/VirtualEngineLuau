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

	const MathModule = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("MathModule"))
	const BufferHelper = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("BufferHelper"))
	const VerticeFile = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("VerticeFile"))
	const TextureTable = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable"))
	const RenderMath = require(SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core"):WaitForChild("RenderMath"))

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

			-- Restore previous entries so runtime Workspace decals remain intact
			TextureTable.ResetEntries()
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
		end)

		it("should expose all 5 unit shape meshes from VerticeFile hashmap", function()
			expect(VerticeFile.GetShapeName(0)).to.equal("Cube")
			expect(VerticeFile.GetShapeName(1)).to.equal("Sphere")
			expect(VerticeFile.GetShapeName(2)).to.equal("Cylinder")
			expect(VerticeFile.GetShapeName(3)).to.equal("Triangle")
			expect(VerticeFile.GetShapeName(4)).to.equal("Plane")
			expect(VerticeFile.GetShapeData(0).IsAxisAligned).to.equal(true)
			expect(VerticeFile.GetShapeData(1).IsAxisAligned).to.equal(false)
			expect(VerticeFile.GetShapeData(4).IsAxisAligned).to.equal(true)
		end)
	end)
end
