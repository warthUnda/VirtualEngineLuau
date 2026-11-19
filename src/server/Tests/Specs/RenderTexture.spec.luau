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
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const MathModule = require(RenderCore:WaitForChild("MathModule"))
	const BufferHelper = require(RenderCore:WaitForChild("BufferHelper"))
	const RenderMath = require(RenderCore:WaitForChild("RenderMath"))
	const TextureTable = require(RenderRoot:WaitForChild("Texture"):WaitForChild("TextureTable"))

	-- Configs --
	const UNTEXTURED_STRIDE = SystemsConfigs.UntexturedBufferLayoutSize :: number
	const TEXTURED_STRIDE = SystemsConfigs.RenderBufferLayoutSize :: number

	describe("1. Perspective-Correct Texture Mapping & UV Clipping", function()
		it("should project UV coordinates alongside screen positions", function()
			const OutBuffer = buffer.create(24)
			const Vertex = vector.create(2, 4, 10)

			MathModule.ProjectVertexUV(OutBuffer, 0, Vertex, 0.75, 0.25, 100, 160, 120)

			expect(buffer.readf32(OutBuffer, 0)).to.equal(180)
			expect(buffer.readf32(OutBuffer, 4)).to.equal(80)
			expect(buffer.readf32(OutBuffer, 8)).to.be.near(0.1, 1e-4)
			expect(buffer.readf32(OutBuffer, 12)).to.be.near(0.75, 1e-4)
			expect(buffer.readf32(OutBuffer, 16)).to.be.near(0.25, 1e-4)
		end)

		it("should interpolate UVs when clipping a polygon against a plane", function()
			const InputBuf = buffer.create(3 * 24)
			const OutputBuf = buffer.create(6 * 24)

			BufferHelper.WriteVec3(InputBuf, 0, vector.create(0, 0, 2))
			buffer.writef32(InputBuf, 12, 0)
			buffer.writef32(InputBuf, 16, 0)

			BufferHelper.WriteVec3(InputBuf, 24, vector.create(2, 0, -2))
			buffer.writef32(InputBuf, 36, 1)
			buffer.writef32(InputBuf, 40, 0)

			BufferHelper.WriteVec3(InputBuf, 48, vector.create(-2, 0, -2))
			buffer.writef32(InputBuf, 60, 0)
			buffer.writef32(InputBuf, 64, 1)

			const ClippedCount = MathModule.ClipPolygonUV(InputBuf, 3, OutputBuf, vector.create(0, 0, 1), 0)
			expect(ClippedCount).to.equal(3)
			expect(buffer.readf32(OutputBuf, 16)).to.be.near(0.5, 1e-4)
			expect(buffer.readf32(OutputBuf, 48 + 12)).to.be.near(0.5, 1e-4)
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

			const CmdBuf = buffer.create(TEXTURED_STRIDE)
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
			RenderMath.DrawTriangleBatch(CmdBuf, TEXTURED_STRIDE, BatchTextures, 2, 2, 16, 16, PixBuf, ZBuf)
			const Sampled = buffer.readu32(PixBuf, (3 * 16 + 3) * 4)
			expect(bit32.band(bit32.rshift(Sampled, 16), 0xFF)).to.equal(255)

			BufferHelper.ClearBuffers(16 * 16, PixBuf, ZBuf)
			WriteTriCmd(0, 0xFF112233)
			RenderMath.DrawTriangleBatch(CmdBuf, TEXTURED_STRIDE, BatchTextures, 2, 2, 16, 16, PixBuf, ZBuf)
			expect(buffer.readu32(PixBuf, (3 * 16 + 3) * 4)).to.equal(0xFF112233)

			const WorkerBandPix = buffer.create(16 * 8 * 4)
			const WorkerBandZ = buffer.create(16 * 8 * 4)
			BufferHelper.ClearBuffers(16 * 8, WorkerBandPix, WorkerBandZ)
			RenderMath.DrawTriangleBatch(CmdBuf, TEXTURED_STRIDE, BatchTextures, 2, 2, 16, 16, WorkerBandPix, WorkerBandZ, 4, 11)

			const FinalPix = buffer.create(16 * 16 * 4)
			BufferHelper.CompositeWorkerBand(FinalPix, WorkerBandPix, 16, 4, 11, 4, 11)
			expect(buffer.readu32(FinalPix, (5 * 16 + 3) * 4)).to.equal(0xFF112233)
			expect(buffer.readu32(FinalPix, (3 * 16 + 3) * 4)).to.equal(0)
		end)

		it("should rasterize untextured and textured dual streams via 32x32 TileRasterizerMath with Hi-Z occlusion", function()
			const TileRasterizerMath = require(RenderCore:WaitForChild("TileRasterizerMath"))
			const Width = 64 :: number
			const Height = 64 :: number
			const BandPix = buffer.create(Width * Height * 4)

			-- 2 untextured triangles (32B aligned): front covers entire 0..63 tile at InvZ=0.8, back behind at InvZ=0.2
			const UntexBuf = buffer.create(UNTEXTURED_STRIDE * 2)
			const FullAreaInv = 1 / (63 * 63) :: number
			-- Front green triangle covering full 64x64
			buffer.writei16(UntexBuf, 0, 0)
			buffer.writei16(UntexBuf, 2, 0)
			buffer.writef32(UntexBuf, 4, 0.8 * FullAreaInv)
			buffer.writei16(UntexBuf, 8, 0)
			buffer.writei16(UntexBuf, 10, 63)
			buffer.writef32(UntexBuf, 12, 0.8 * FullAreaInv)
			buffer.writei16(UntexBuf, 16, 63)
			buffer.writei16(UntexBuf, 18, 63)
			buffer.writef32(UntexBuf, 20, 0.8 * FullAreaInv)
			buffer.writeu32(UntexBuf, 24, 0xFF00FF00)

			-- Back red triangle behind front triangle (should be Hi-Z / Z-rejected)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE, 0)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE + 2, 0)
			buffer.writef32(UntexBuf, UNTEXTURED_STRIDE + 4, 0.2 * FullAreaInv)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE + 8, 0)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE + 10, 63)
			buffer.writef32(UntexBuf, UNTEXTURED_STRIDE + 12, 0.2 * FullAreaInv)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE + 16, 63)
			buffer.writei16(UntexBuf, UNTEXTURED_STRIDE + 18, 63)
			buffer.writef32(UntexBuf, UNTEXTURED_STRIDE + 20, 0.2 * FullAreaInv)
			buffer.writeu32(UntexBuf, UNTEXTURED_STRIDE + 24, 0xFF0000FF)

			-- 1 shaded textured triangle (64B aligned) in front of upper-right half at InvZ=0.9
			const SolidTex = buffer.create(4 * 4 * 4)
			for i = 0, 60, 4 do
				buffer.writeu32(SolidTex, i, 0xFF80C040)
			end
			const TexBuf = buffer.create(TEXTURED_STRIDE)
			buffer.writei16(TexBuf, 0, 0)
			buffer.writei16(TexBuf, 2, 0)
			buffer.writef32(TexBuf, 4, 0.9 * FullAreaInv)
			buffer.writef32(TexBuf, 8, 0)
			buffer.writef32(TexBuf, 12, 0)
			buffer.writei16(TexBuf, 16, 63)
			buffer.writei16(TexBuf, 18, 63)
			buffer.writef32(TexBuf, 20, 0.9 * FullAreaInv)
			buffer.writef32(TexBuf, 24, 0.9 * FullAreaInv)
			buffer.writef32(TexBuf, 28, 0.9 * FullAreaInv)
			buffer.writei16(TexBuf, 32, 63)
			buffer.writei16(TexBuf, 34, 0)
			buffer.writef32(TexBuf, 36, 0.9 * FullAreaInv)
			buffer.writef32(TexBuf, 40, 0.9 * FullAreaInv)
			buffer.writef32(TexBuf, 44, 0)
			buffer.writeu32(TexBuf, 48, 0xFF808080) -- ~50% grayscale shade
			buffer.writeu32(TexBuf, 52, 1)

			TileRasterizerMath.RasterizeBandDual(
				UntexBuf, UNTEXTURED_STRIDE * 2,
				TexBuf, TEXTURED_STRIDE,
				{ [1] = SolidTex }, 4, 4,
				Width, Height,
				BandPix, 0, Height - 1
			)

			-- Lower-left (x=10, y=50): front green wins over occluded back red
			expect(buffer.readu32(BandPix, (50 * Width + 10) * 4)).to.equal(0xFF00FF00)
			-- Upper-right (x=50, y=10): shaded textured (0x40, 0xC0, 0x80) * 129/256 -> (0x20, 0x60, 0x40)
			const ShadedPx = buffer.readu32(BandPix, (10 * Width + 50) * 4)
			expect(bit32.band(ShadedPx, 0xFF)).to.be.near(0x20, 1)
			expect(bit32.band(bit32.rshift(ShadedPx, 8), 0xFF)).to.be.near(0x60, 1)
			expect(bit32.band(bit32.rshift(ShadedPx, 16), 0xFF)).to.be.near(0x40, 1)
		end)
	end)
end
