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
	const RenderCore = RenderRoot:WaitForChild("Core")

	-- Libraries --
	const MathModule = require(RenderCore:WaitForChild("MathModule"))
	const BufferHelper = require(RenderCore:WaitForChild("BufferHelper"))
	const RenderMath = require(RenderCore:WaitForChild("RenderMath"))
	const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))

	describe("1. Perspective-Correct Texture Mapping & UV Clipping", function()
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

			BufferHelper.WriteVec3(InputBuf, 0, vector.create(0, 0, 2))
			buffer.writef32(InputBuf, 12, 0)
			buffer.writef32(InputBuf, 16, 0)

			BufferHelper.WriteVec3(InputBuf, 20, vector.create(2, 0, -2))
			buffer.writef32(InputBuf, 32, 1)
			buffer.writef32(InputBuf, 36, 0)

			BufferHelper.WriteVec3(InputBuf, 40, vector.create(-2, 0, -2))
			buffer.writef32(InputBuf, 52, 0)
			buffer.writef32(InputBuf, 56, 1)

			const ClippedCount = MathModule.ClipPolygonUV(InputBuf, 3, OutputBuf, vector.create(0, 0, 1), 0)
			expect(ClippedCount).to.equal(3)
			expect(buffer.readf32(OutputBuf, 16)).to.be.near(0.5, 1e-4)
			expect(buffer.readf32(OutputBuf, 40 + 12)).to.be.near(0.5, 1e-4)
		end)

		it("should rasterize textured triangles with solid texture buffers", function()
			const SolidTex = buffer.create(2 * 2 * 4)
			for i = 0, 12, 4 do
				buffer.writeu32(SolidTex, i, 0xFF0000FF)
			end

			const PixBuf = buffer.create(16 * 16 * 4)
			const ZBuf = buffer.create(16 * 16 * 4)
			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)

			const InvArea = 1 / 64 :: number
			MathModule.RasterizeTriangleSpan(
				2, 2, InvArea, 0, 0,
				2, 10, InvArea, 0, InvArea,
				10, 2, InvArea, InvArea, 0,
				0xFFFFFFFF,
				SolidTex,
				2,
				2,
				16,
				16,
				16 * 4,
				PixBuf,
				ZBuf
			)

			const Sampled = buffer.readu32(PixBuf, (3 * 16 + 3) * 4)
			expect(bit32.band(Sampled, 0xFF)).to.equal(255)
			expect(bit32.band(bit32.rshift(Sampled, 8), 0xFF)).to.equal(0)
			expect(bit32.band(bit32.rshift(Sampled, 16), 0xFF)).to.equal(0)
		end)

		it("should translate texture IDs, deduplicate URLs, and composite worker bands", function()
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

			const SolidGreen = buffer.create(2 * 2 * 4)
			const SolidBlue = buffer.create(2 * 2 * 4)
			for i = 0, 12, 4 do
				buffer.writeu32(SolidGreen, i, 0xFF00FF00)
				buffer.writeu32(SolidBlue, i, 0xFFFF0000)
			end
			const BatchTextures = { [1] = SolidGreen, [2] = SolidBlue }

			const CmdBuf = buffer.create(56)
			const InvArea = 1 / 64 :: number
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
			expect(bit32.band(bit32.rshift(Sampled, 16), 0xFF)).to.equal(255)

			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)
			WriteTriCmd(0, 0xFF112233)
			RenderMath.DrawTriangleBatch(CmdBuf, 56, BatchTextures, 2, 2, 16, 16, PixBuf, ZBuf)
			expect(buffer.readu32(PixBuf, (3 * 16 + 3) * 4)).to.equal(0xFF112233)

			const WorkerBandPix = buffer.create(16 * 8 * 4)
			const WorkerBandZ = buffer.create(16 * 8 * 4)
			BufferHelper.ClearBuffers(16 * 8, WorkerBandPix, WorkerBandZ)
			RenderMath.DrawTriangleBatch(CmdBuf, 56, BatchTextures, 2, 2, 16, 16, WorkerBandPix, WorkerBandZ, 4, 11)

			const FinalPix = buffer.create(16 * 16 * 4)
			BufferHelper.CompositeWorkerBand(FinalPix, WorkerBandPix, 16, 4, 11, 4, 11)
			expect(buffer.readu32(FinalPix, (5 * 16 + 3) * 4)).to.equal(0xFF112233)
			expect(buffer.readu32(FinalPix, (3 * 16 + 3) * 4)).to.equal(0)
		end)
	end)
end
