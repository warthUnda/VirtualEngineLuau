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
	const RenderCore = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Core")

	-- Libraries --
	const TileShadedTexHelper = require(RenderCore:WaitForChild("TileShadedTexHelper"))
	const TileTexturedSpanHelper = require(RenderCore:WaitForChild("TileTexturedSpanHelper"))

	describe("1. Pre-Shaded L1 Texture Cache & Hoisted Textured Span Fast Paths", function()
		it("should pre-bake fullbright, grayscale, and RGB-tinted textures and reuse cached buffers", function()
			const SrcTex = buffer.create(2 * 2 * 4)
			buffer.writeu32(SrcTex, 0, 0x004080C0)
			buffer.writeu32(SrcTex, 4, 0x00FFFFFF)
			buffer.writeu32(SrcTex, 8, 0x00000000)
			buffer.writeu32(SrcTex, 12, 0x002060A0)

			const FullbrightA = TileShadedTexHelper.GetShadedTexture(SrcTex, 0xFFFFFFFF, 2, 2)
			const FullbrightB = TileShadedTexHelper.GetShadedTexture(SrcTex, 0xFFFFFFFF, 2, 2)
			expect(FullbrightA).to.equal(FullbrightB)
			expect(buffer.readu32(FullbrightA, 0)).to.equal(0xFF4080C0)
			expect(buffer.readu32(FullbrightA, 4)).to.equal(0xFFFFFFFF)
			expect(buffer.readu32(FullbrightA, 8)).to.equal(0xFF000000)

			const GrayTex = TileShadedTexHelper.GetShadedTexture(SrcTex, 0xFF808080, 2, 2)
			const GrayPx = buffer.readu32(GrayTex, 0)
			expect(bit32.rshift(GrayPx, 24)).to.equal(0xFF)
			expect(bit32.band(GrayPx, 0xFF)).to.be.near(0x60, 1)
			expect(bit32.band(bit32.rshift(GrayPx, 8), 0xFF)).to.be.near(0x40, 1)
			expect(bit32.band(bit32.rshift(GrayPx, 16), 0xFF)).to.be.near(0x20, 1)

			const TintedTex = TileShadedTexHelper.GetShadedTexture(SrcTex, 0xFF4080FF, 2, 2)
			const TintPx = buffer.readu32(TintedTex, 4)
			expect(bit32.rshift(TintPx, 24)).to.equal(0xFF)
			expect(bit32.band(TintPx, 0xFF)).to.equal(255)
			expect(bit32.band(bit32.rshift(TintPx, 8), 0xFF)).to.be.near(0x80, 1)
			expect(bit32.band(bit32.rshift(TintPx, 16), 0xFF)).to.be.near(0x40, 1)
		end)

		it("should rasterize both in-bounds and clamped UV spans accurately under SkipZTest true and false", function()
			const CheckerTex = buffer.create(4 * 4 * 4)
			for y = 0, 3 do
				for x = 0, 3 do
					const Col = if (x + y) % 2 == 0 then 0xFF2288EE else 0xFFEE4422 :: number
					buffer.writeu32(CheckerTex, (y * 4 + x) * 4, Col)
				end
			end

			const PixA = buffer.create(16 * 16 * 4)
			const ZA = buffer.create(16 * 16 * 4)
			const PixB = buffer.create(16 * 16 * 4)
			const ZB = buffer.create(16 * 16 * 4)

			const InvArea = 1 / 256 :: number
			-- FullCover triangle with UVs extending from 0 to 8 (testing both in-bounds and clamped chunks)
			TileTexturedSpanHelper.RasterizeTexturedTile(
				16, 16, true, true,
				256, 0, 0, -16, 16, 0, -16, 0, 16,
				0.5 * InvArea, 0.5 * InvArea, 0.5 * InvArea, 0,
				0, 0, 8 * 0.5 * InvArea, 0, 0, 8 * 0.5 * InvArea,
				0xFFC0C0C0, CheckerTex, 4, 3, 3,
				PixA, ZA
			)
			TileTexturedSpanHelper.RasterizeTexturedTile(
				16, 16, true, false,
				256, 0, 0, -16, 16, 0, -16, 0, 16,
				0.5 * InvArea, 0.5 * InvArea, 0.5 * InvArea, 0,
				0, 0, 8 * 0.5 * InvArea, 0, 0, 8 * 0.5 * InvArea,
				0xFFC0C0C0, CheckerTex, 4, 3, 3,
				PixB, ZB
			)

			for Off = 0, 16 * 16 * 4 - 4, 4 do
				expect(buffer.readu32(PixA, Off)).to.equal(buffer.readu32(PixB, Off))
				expect(buffer.readf32(ZA, Off)).to.be.near(0.5, 1e-4)
			end

			-- Regression: ULP boundary near TexW (3.999999999999999) across 32px span must never overflow buffer
			const EdgePix = buffer.create(32 * 4)
			const EdgeZ = buffer.create(32 * 4)
			TileShadedTexHelper.DrawPreShadedSpan(
				0, 31 * 4,
				0.5, 0, 0,
				0, (3.999999999999999 * 0.5) / 16, (3.999999999999999 * 0.5) / 16,
				CheckerTex, 4, 4, 3, 3, true, EdgePix, EdgeZ
			)
			expect(buffer.readu32(EdgePix, 31 * 4) ~= 0).to.equal(true)
		end)

		it("should bypass Z-buffer writes on hoisted single-triangle SkipZWrite spans while preserving exact pixels", function()
			const TileSpanHelper = require(RenderCore:WaitForChild("TileSpanHelper"))
			const SolidTex = buffer.create(2 * 2 * 4)
			for Off = 0, 12, 4 do
				buffer.writeu32(SolidTex, Off, 0xFF3377BB)
			end
			const TexPix = buffer.create(16 * 4)
			const TexZ = buffer.create(16 * 4)
			TileShadedTexHelper.DrawPreShadedSpan(
				0, 15 * 4, 0.5, 0, 0, 0, 0.05, 0.05,
				SolidTex, 2, 2, 1, 1, true, TexPix, TexZ, true
			)
			expect(buffer.readu32(TexPix, 0)).to.equal(0xFF3377BB)
			expect(buffer.readu32(TexPix, 15 * 4)).to.equal(0xFF3377BB)
			expect(buffer.readf32(TexZ, 0)).to.equal(0)
			expect(buffer.readf32(TexZ, 15 * 4)).to.equal(0)

			const UntexPix = buffer.create(8 * 8 * 4)
			const UntexZ = buffer.create(8 * 8 * 4)
			TileSpanHelper.RasterizeUntexturedTile(
				8, 8, true, true,
				1, 1, 1, 0, 0, 0, 0, 0, 0,
				0.5, 0, 0, 0, 0xFFAA5511, UntexPix, UntexZ, true
			)
			expect(buffer.readu32(UntexPix, 0)).to.equal(0xFFAA5511)
			expect(buffer.readu32(UntexPix, 63 * 4)).to.equal(0xFFAA5511)
			expect(buffer.readf32(UntexZ, 0)).to.equal(0)
		end)
	end)
end
