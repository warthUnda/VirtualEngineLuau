--!strict
--!native
--!optimize 2

--[=[
	@class TileBinnerHelper
	Zero-allocation 2D tile binner inserting 32B untextured and 64B textured triangles
	into tail-linked 32x32 tile lists in exact front-to-back submission order with
	multi-tile corner edge-reject culling.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const TILE_SIZE = (SystemsConfigs.RasterTileSize or 32) :: number
const TILE_MAX_DELTA = TILE_SIZE - 1 :: number

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
	const V1Delta = if FlagBit == 0 then 8 else 16 :: number
	const V2Delta = if FlagBit == 0 then 16 else 32 :: number
	local NextBin = BinCursor :: number
	local ReadOff = 0 :: number

	while ReadOff < ByteCount do
		const V0X = buffer.readi16(StreamBuf, ReadOff) :: number
		const V0Y = buffer.readi16(StreamBuf, ReadOff + 2) :: number
		const V1Off = ReadOff + V1Delta :: number
		const V2Off = ReadOff + V2Delta :: number
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

			if TxMax > TxMin and TyMax > TyMin then
				const E0StepX, E1StepX, E2StepX = V2Y - V1Y, V0Y - V2Y, V1Y - V0Y
				const E0StepY, E1StepY, E2StepY = V1X - V2X, V2X - V0X, V0X - V1X
				const StartTileX = TxMin * TILE_SIZE :: number
				const StartTileY = BandStartY + TyMin * TILE_SIZE :: number
				const C0 = (if E0StepX > 0 then TILE_MAX_DELTA * E0StepX else 0) + (if E0StepY > 0 then TILE_MAX_DELTA * E0StepY else 0) :: number
				const C1 = (if E1StepX > 0 then TILE_MAX_DELTA * E1StepX else 0) + (if E1StepY > 0 then TILE_MAX_DELTA * E1StepY else 0) :: number
				const C2 = (if E2StepX > 0 then TILE_MAX_DELTA * E2StepX else 0) + (if E2StepY > 0 then TILE_MAX_DELTA * E2StepY else 0) :: number
				const TileStepX0, TileStepX1, TileStepX2 = E0StepX * TILE_SIZE, E1StepX * TILE_SIZE, E2StepX * TILE_SIZE
				const TileStepY0, TileStepY1, TileStepY2 = E0StepY * TILE_SIZE, E1StepY * TILE_SIZE, E2StepY * TILE_SIZE
				local RowE0 = (StartTileX - V1X) * E0StepX + (StartTileY - V1Y) * E0StepY + C0 :: number
				local RowE1 = (StartTileX - V2X) * E1StepX + (StartTileY - V2Y) * E1StepY + C1 :: number
				local RowE2 = (StartTileX - V0X) * E2StepX + (StartTileY - V0Y) * E2StepY + C2 :: number

				for Ty = TyMin, TyMax do
					const RowTileBase = Ty * TilesX :: number
					local CurE0, CurE1, CurE2 = RowE0, RowE1, RowE2
					for Tx = TxMin, TxMax do
						if CurE0 >= 0 and CurE1 >= 0 and CurE2 >= 0 then
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
						CurE0 += TileStepX0; CurE1 += TileStepX1; CurE2 += TileStepX2
					end
					RowE0 += TileStepY0; RowE1 += TileStepY1; RowE2 += TileStepY2
				end
			else
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
		end

		ReadOff += Stride
	end

	return NextBin
end

return TileBinnerHelper
