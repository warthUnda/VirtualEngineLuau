--!strict
--!native
--!optimize 2

--[=[
	@class TileBinnerHelper
	Zero-allocation 2D tile binner inserting 32B untextured and 64B textured triangles
	into tail-linked 32x32 tile lists in exact front-to-back submission order.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const TILE_SIZE = (SystemsConfigs.RasterTileSize or 32) :: number

-- Tables --
local TileBinnerHelper = {}

-- Functions --
-- ============================================================================
-- 1. TAIL-INSERTED 2D TILE BINNING (FRONT-TO-BACK ORDER PRESERVED)
-- ============================================================================

--[=[
	Bins a stream of triangles (untextured 32B or textured 64B) into tail-linked 32x32 tile lists.
	@return number -- Updated next bin entry cursor.
]=]
function TileBinnerHelper.BinTriangleStream(
	StreamBuf: buffer,
	ByteCount: number,
	Stride: number,
	FlagBit: number,
	TilesX: number,
	BandTilesY: number,
	BandStartY: number,
	BandEndY: number,
	ActiveWidth: number,
	TileHead: buffer,
	TileTail: buffer,
	BinTriRef: buffer,
	BinNext: buffer,
	MaxBinEntries: number,
	BinCursor: number
): number
	const MaxXLimit = ActiveWidth - 1 :: number
	local NextBin = BinCursor :: number
	local ReadOff = 0 :: number

	while ReadOff < ByteCount do
		const V0X = buffer.readi16(StreamBuf, ReadOff) :: number
		const V0Y = buffer.readi16(StreamBuf, ReadOff + 2) :: number
		const V1Off = if FlagBit == 0 then ReadOff + 8 else ReadOff + 16 :: number
		const V2Off = if FlagBit == 0 then ReadOff + 16 else ReadOff + 32 :: number
		const V1X = buffer.readi16(StreamBuf, V1Off) :: number
		const V1Y = buffer.readi16(StreamBuf, V1Off + 2) :: number
		const V2X = buffer.readi16(StreamBuf, V2Off) :: number
		const V2Y = buffer.readi16(StreamBuf, V2Off + 2) :: number

		const MinX = math.max(0, math.min(V0X, V1X, V2X)) :: number
		const MaxX = math.min(MaxXLimit, math.max(V0X, V1X, V2X)) :: number
		const MinY = math.max(BandStartY, math.min(V0Y, V1Y, V2Y)) :: number
		const MaxY = math.min(BandEndY, math.max(V0Y, V1Y, V2Y)) :: number

		if MinX <= MaxX and MinY <= MaxY then
			const TxMin = MinX // TILE_SIZE :: number
			const TxMax = MaxX // TILE_SIZE :: number
			const TyMin = (MinY - BandStartY) // TILE_SIZE :: number
			const TyMax = math.min(BandTilesY - 1, (MaxY - BandStartY) // TILE_SIZE) :: number
			const PackedRef = bit32.bor(FlagBit, ReadOff) :: number

			for Ty = TyMin, TyMax do
				const RowTileBase = Ty * TilesX :: number
				for Tx = TxMin, TxMax do
					if NextBin >= MaxBinEntries then
						return NextBin
					end
					const TileOff = (RowTileBase + Tx) * 4 :: number
					const EntryOff = NextBin * 4 :: number
					buffer.writeu32(BinTriRef, EntryOff, PackedRef)
					buffer.writei32(BinNext, EntryOff, -1)

					const PrevTail = buffer.readi32(TileTail, TileOff) :: number
					if PrevTail < 0 then
						buffer.writei32(TileHead, TileOff, NextBin)
					else
						buffer.writei32(BinNext, PrevTail * 4, NextBin)
					end
					buffer.writei32(TileTail, TileOff, NextBin)
					NextBin += 1
				end
			end
		end

		ReadOff += Stride
	end

	return NextBin
end

return TileBinnerHelper
