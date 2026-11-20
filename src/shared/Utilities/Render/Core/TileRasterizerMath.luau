--!strict
--!native
--!optimize 2

--[=[
	@class TileRasterizerMath
	2D 32x32 L1-tile binner and conservative Hi-Z dual-stream rasterizer with lazy tile/Z-buffer
	initialization, empty-tile-only clear coalescing, and AABB FullCover short-circuiting.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const BufferHelper = require(script.Parent:WaitForChild("BufferHelper"))
const TileBinnerHelper = require(script.Parent:WaitForChild("TileBinnerHelper"))
const TileSpanHelper = require(script.Parent:WaitForChild("TileSpanHelper"))
const TileTexturedSpanHelper = require(script.Parent:WaitForChild("TileTexturedSpanHelper"))

-- Configs --
const TILE_SIZE = (SystemsConfigs.RasterTileSize or 32) :: number
const UNTEXTURED_STRIDE = (SystemsConfigs.UntexturedBufferLayoutSize or 32) :: number
const TEXTURED_STRIDE = (SystemsConfigs.RenderBufferLayoutSize or 64) :: number
const MAX_WIDTH = SystemsConfigs.RenderWidth :: number
const MAX_HEIGHT = SystemsConfigs.RenderHeight :: number
const MAX_TILES = math.ceil(MAX_WIDTH / TILE_SIZE) * math.ceil(MAX_HEIGHT / TILE_SIZE) :: number
const MAX_BIN_ENTRIES = 262144 :: number
const TEXTURED_FLAG_BIT = 0x80000000 :: number
const OFFSET_VALUE_MASK = 0x7FFFFFFF :: number

const CLEAR_R = SystemsConfigs.ClearColorR :: number
const CLEAR_G = SystemsConfigs.ClearColorG :: number
const CLEAR_B = SystemsConfigs.ClearColorB :: number
const PACKED_CLEAR_COLOR = bit32.bor(CLEAR_R, bit32.lshift(CLEAR_G, 8), bit32.lshift(CLEAR_B, 16), 0xFF000000) :: number

-- Buffers
const TilePixelBuf = buffer.create(TILE_SIZE * TILE_SIZE * 4) :: buffer
const TileZBuf = buffer.create(TILE_SIZE * TILE_SIZE * 4) :: buffer
const TileClearTemplate = buffer.create(TILE_SIZE * TILE_SIZE * 4) :: buffer
const TileHead = buffer.create(MAX_TILES * 4) :: buffer
const TileTail = buffer.create(MAX_TILES * 4) :: buffer
const BinTriRef = buffer.create(MAX_BIN_ENTRIES * 4) :: buffer
const BinNext = buffer.create(MAX_BIN_ENTRIES * 4) :: buffer

for ClearIdx = 0, TILE_SIZE * TILE_SIZE * 4 - 4, 4 do
	buffer.writeu32(TileClearTemplate, ClearIdx, PACKED_CLEAR_COLOR)
end

-- Tables --
local TileRasterizerMath = {
	TileSize = TILE_SIZE,
	UntexturedStride = UNTEXTURED_STRIDE,
	TexturedStride = TEXTURED_STRIDE,
}

-- Functions --
-- ============================================================================
-- 1. CONSERVATIVE HI-Z DUAL-STREAM 32x32 TILE BAND RASTERIZATION
-- ============================================================================

--[=[
	Rasterizes dual 32-byte untextured and 64-byte textured triangle streams for a worker's band
	directly into BandPixelBuf (`(BandEndY - BandStartY + 1) * ActiveWidth * 4`).
]=]
function TileRasterizerMath.RasterizeBandDual(
	UntexBuf: buffer, UntexBytes: number, TexBuf: buffer, TexBytes: number,
	TextureBuffers: { [number]: buffer }, TextureWidth: number, TextureHeight: number,
	ActiveWidth: number, ActiveHeight: number, BandPixelBuf: buffer, BandStartY: number, BandEndY: number
)
	if BandStartY > BandEndY or ActiveWidth <= 0 or ActiveHeight <= 0 then
		return
	end

	const BandHeight = BandEndY - BandStartY + 1 :: number
	const BandRowStride = ActiveWidth * 4 :: number
	const BandByteLength = BandHeight * BandRowStride :: number

	if UntexBytes <= 0 and TexBytes <= 0 then
		const ClearBandTemplate = BufferHelper.EnsureClearTemplate(BandByteLength)
		buffer.copy(BandPixelBuf, 0, ClearBandTemplate, 0, BandByteLength)
		return
	end

	const TilesX = math.ceil(ActiveWidth / TILE_SIZE) :: number
	const BandTilesY = math.ceil(BandHeight / TILE_SIZE) :: number
	const TotalBandTiles = TilesX * BandTilesY :: number

	buffer.fill(TileHead, 0, 0xFF, TotalBandTiles * 4)
	buffer.fill(TileTail, 0, 0xFF, TotalBandTiles * 4)

	local BinCursor = 0 :: number
	if UntexBytes > 0 then
		BinCursor = TileBinnerHelper.BinTriangleStream(
			UntexBuf, UntexBytes, UNTEXTURED_STRIDE, 0,
			TilesX, BandTilesY, BandStartY, BandEndY, ActiveWidth,
			TileHead, TileTail, BinTriRef, BinNext, MAX_BIN_ENTRIES, BinCursor
		)
	end
	if TexBytes > 0 then
		BinCursor = TileBinnerHelper.BinTriangleStream(
			TexBuf, TexBytes, TEXTURED_STRIDE, TEXTURED_FLAG_BIT,
			TilesX, BandTilesY, BandStartY, BandEndY, ActiveWidth,
			TileHead, TileTail, BinTriRef, BinNext, MAX_BIN_ENTRIES, BinCursor
		)
	end
	if BinCursor <= 0 then
		const ClearBandTemplate = BufferHelper.EnsureClearTemplate(BandByteLength)
		buffer.copy(BandPixelBuf, 0, ClearBandTemplate, 0, BandByteLength)
		return
	end

	const TexWMask = TextureWidth - 1 :: number
	const TexHMask = TextureHeight - 1 :: number
	const RasterUntex = TileSpanHelper.RasterizeUntexturedTile
	const RasterTex = TileTexturedSpanHelper.RasterizeTexturedTile
	const ClearStripTemplate = BufferHelper.EnsureClearTemplate(TILE_SIZE * BandRowStride)

	for Ty = 0, BandTilesY - 1 do
		const TileY0 = BandStartY + Ty * TILE_SIZE :: number
		const TileH = math.min(TILE_SIZE, BandEndY - TileY0 + 1) :: number
		const DyMax = TileH - 1 :: number
		const TileY1 = TileY0 + DyMax :: number
		const RowTileBase = Ty * TilesX :: number
		const BandStripOff = (TileY0 - BandStartY) * BandRowStride :: number

		-- Fast check: if entire tile row has zero binned triangles, clear whole strip in 1 copy
		local RowAnyEntry = false :: boolean
		for Tx = 0, TilesX - 1 do
			if buffer.readi32(TileHead, (RowTileBase + Tx) * 4) >= 0 then
				RowAnyEntry = true
				break
			end
		end
		if not RowAnyEntry then
			buffer.copy(BandPixelBuf, BandStripOff, ClearStripTemplate, 0, TileH * BandRowStride)
			continue
		end

		for Tx = 0, TilesX - 1 do
			const TileX0 = Tx * TILE_SIZE :: number
			const TileW = math.min(TILE_SIZE, ActiveWidth - TileX0) :: number
			const TileRowBytes = TileW * 4 :: number
			const FirstEntry = buffer.readi32(TileHead, (RowTileBase + Tx) * 4) :: number
			if FirstEntry < 0 then
				local DstOff = BandStripOff + TileX0 * 4 :: number
				for _ = 0, TileH - 1 do
					buffer.copy(BandPixelBuf, DstOff, TileClearTemplate, 0, TileRowBytes)
					DstOff += BandRowStride
				end
				continue
			end

			const DxMax = TileW - 1 :: number
			const TileX1 = TileX0 + DxMax :: number
			const TileBytes = TileRowBytes * TileH :: number
			local HasDrawnInTile = false :: boolean
			local TileMinZ = 0 :: number
			local TileMaxZ = 0 :: number
			local EntryIdx = FirstEntry :: number

			while EntryIdx >= 0 do
				const PackedRef = buffer.readu32(BinTriRef, EntryIdx * 4) :: number
				const IsTex = bit32.btest(PackedRef, TEXTURED_FLAG_BIT)
				const TriOff = bit32.band(PackedRef, OFFSET_VALUE_MASK) :: number
				EntryIdx = buffer.readi32(BinNext, EntryIdx * 4)

				const SrcBuf = if IsTex then TexBuf else UntexBuf :: buffer
				const V0X = buffer.readi16(SrcBuf, TriOff) :: number
				const V0Y = buffer.readi16(SrcBuf, TriOff + 2) :: number
				const SInvZ0 = buffer.readf32(SrcBuf, TriOff + 4) :: number
				const V1Off = if IsTex then TriOff + 16 else TriOff + 8 :: number
				const V2Off = if IsTex then TriOff + 32 else TriOff + 16 :: number
				const V1X = buffer.readi16(SrcBuf, V1Off) :: number
				const V1Y = buffer.readi16(SrcBuf, V1Off + 2) :: number
				const SInvZ1 = buffer.readf32(SrcBuf, V1Off + 4) :: number
				const V2X = buffer.readi16(SrcBuf, V2Off) :: number
				const V2Y = buffer.readi16(SrcBuf, V2Off + 2) :: number
				const SInvZ2 = buffer.readf32(SrcBuf, V2Off + 4) :: number

				const E0StepX, E1StepX, E2StepX = V2Y - V1Y, V0Y - V2Y, V1Y - V0Y
				const E0StepY, E1StepY, E2StepY = V1X - V2X, V2X - V0X, V0X - V1X
				const E0 = (TileX0 - V1X) * E0StepX + (TileY0 - V1Y) * E0StepY :: number
				const E1 = (TileX0 - V2X) * E1StepX + (TileY0 - V2Y) * E1StepY :: number
				const E2 = (TileX0 - V0X) * E2StepX + (TileY0 - V0Y) * E2StepY :: number

				const MaxE0 = E0 + (if E0StepX > 0 then DxMax * E0StepX else 0) + (if E0StepY > 0 then DyMax * E0StepY else 0) :: number
				const MaxE1 = E1 + (if E1StepX > 0 then DxMax * E1StepX else 0) + (if E1StepY > 0 then DyMax * E1StepY else 0) :: number
				const MaxE2 = E2 + (if E2StepX > 0 then DxMax * E2StepX else 0) + (if E2StepY > 0 then DyMax * E2StepY else 0) :: number
				if MaxE0 < 0 or MaxE1 < 0 or MaxE2 < 0 then
					continue
				end

				const InvZOrigin = E0 * SInvZ0 + E1 * SInvZ1 + E2 * SInvZ2 :: number
				const InvZStepX = E0StepX * SInvZ0 + E1StepX * SInvZ1 + E2StepX * SInvZ2 :: number
				const InvZStepY = E0StepY * SInvZ0 + E1StepY * SInvZ1 + E2StepY * SInvZ2 :: number
				const TriTileMaxZ = InvZOrigin
					+ (if InvZStepX > 0 then DxMax * InvZStepX else 0)
					+ (if InvZStepY > 0 then DyMax * InvZStepY else 0) :: number
				if TriTileMaxZ <= TileMinZ then
					continue
				end

				const TriMinX = math.min(V0X, V1X, V2X) :: number
				const TriMaxX = math.max(V0X, V1X, V2X) :: number
				const TriMinY = math.min(V0Y, V1Y, V2Y) :: number
				const TriMaxY = math.max(V0Y, V1Y, V2Y) :: number
				local FullCover = false :: boolean
				if TriMinX <= TileX0 and TriMaxX >= TileX1 and TriMinY <= TileY0 and TriMaxY >= TileY1 then
					const MinE0 = E0 + (if E0StepX < 0 then DxMax * E0StepX else 0) + (if E0StepY < 0 then DyMax * E0StepY else 0) :: number
					const MinE1 = E1 + (if E1StepX < 0 then DxMax * E1StepX else 0) + (if E1StepY < 0 then DyMax * E1StepY else 0) :: number
					const MinE2 = E2 + (if E2StepX < 0 then DxMax * E2StepX else 0) + (if E2StepY < 0 then DyMax * E2StepY else 0) :: number
					FullCover = (MinE0 >= 0 and MinE1 >= 0 and MinE2 >= 0)
				end

				const HasMoreEntries = (EntryIdx >= 0) :: boolean
				const TriTileMinZ = if HasDrawnInTile or FullCover
					then (InvZOrigin + (if InvZStepX < 0 then DxMax * InvZStepX else 0) + (if InvZStepY < 0 then DyMax * InvZStepY else 0))
					else 0 :: number
				const SkipZTest: boolean = if not HasDrawnInTile then true else (TriTileMinZ > TileMaxZ)
				if not HasDrawnInTile then
					if not FullCover then
						buffer.copy(TilePixelBuf, 0, TileClearTemplate, 0, TileBytes)
					end
					if HasMoreEntries and not FullCover then
						buffer.fill(TileZBuf, 0, 0, TileBytes)
					end
					HasDrawnInTile = true
				end
				const SkipZWrite = not HasMoreEntries :: boolean
				const LocalMinY = math.max(0, TriMinY - TileY0) :: number
				const LocalMaxY = math.min(DyMax, TriMaxY - TileY0) :: number
				const LocalMinX = math.max(0, TriMinX - TileX0) :: number
				const LocalMaxX = math.min(DxMax, TriMaxX - TileX0) :: number

				if not IsTex then
					RasterUntex(
						TileW, TileH, FullCover, SkipZTest,
						E0, E1, E2, E0StepX, E1StepX, E2StepX, E0StepY, E1StepY, E2StepY,
						SInvZ0, SInvZ1, SInvZ2, InvZStepX,
						buffer.readu32(UntexBuf, TriOff + 24), TilePixelBuf, TileZBuf, SkipZWrite,
						InvZOrigin, InvZStepY, LocalMinY, LocalMaxY, LocalMinX, LocalMaxX
					)
				else
					const ActiveTex = TextureBuffers[buffer.readu32(TexBuf, TriOff + 52)]
					const PackedColor = buffer.readu32(TexBuf, TriOff + 48) :: number
					if ActiveTex then
						RasterTex(
							TileW, TileH, FullCover, SkipZTest,
							E0, E1, E2, E0StepX, E1StepX, E2StepX, E0StepY, E1StepY, E2StepY,
							SInvZ0, SInvZ1, SInvZ2, InvZStepX,
							buffer.readf32(TexBuf, TriOff + 8) * TextureWidth,
							buffer.readf32(TexBuf, TriOff + 12) * TextureHeight,
							buffer.readf32(TexBuf, TriOff + 24) * TextureWidth,
							buffer.readf32(TexBuf, TriOff + 28) * TextureHeight,
							buffer.readf32(TexBuf, TriOff + 40) * TextureWidth,
							buffer.readf32(TexBuf, TriOff + 44) * TextureHeight,
							PackedColor, ActiveTex, TextureWidth, TexWMask, TexHMask, TilePixelBuf, TileZBuf, SkipZWrite,
							InvZOrigin, InvZStepY, LocalMinY, LocalMaxY, LocalMinX, LocalMaxX
						)
					else
						RasterUntex(
							TileW, TileH, FullCover, SkipZTest,
							E0, E1, E2, E0StepX, E1StepX, E2StepX, E0StepY, E1StepY, E2StepY,
							SInvZ0, SInvZ1, SInvZ2, InvZStepX,
							PackedColor, TilePixelBuf, TileZBuf, SkipZWrite,
							InvZOrigin, InvZStepY, LocalMinY, LocalMaxY, LocalMinX, LocalMaxX
						)
					end
				end

				if TriTileMaxZ > TileMaxZ then TileMaxZ = TriTileMaxZ end
				if FullCover and TriTileMinZ > TileMinZ then TileMinZ = TriTileMinZ end
			end

			local DstOff = BandStripOff + TileX0 * 4 :: number
			if HasDrawnInTile then
				local SrcOff = 0 :: number
				for _ = 0, TileH - 1 do
					buffer.copy(BandPixelBuf, DstOff, TilePixelBuf, SrcOff, TileRowBytes)
					SrcOff += TileRowBytes
					DstOff += BandRowStride
				end
			else
				for _ = 0, TileH - 1 do
					buffer.copy(BandPixelBuf, DstOff, TileClearTemplate, 0, TileRowBytes)
					DstOff += BandRowStride
				end
			end
		end
	end
end

return TileRasterizerMath
