--!strict
--!native
--!optimize 2

--[=[
	@class RenderQuadEmitHelper
	Zero-allocation direct triangle emitter for already-projected AllInside quads,
	writing directly into dual 32-byte untextured / 64-byte textured buffers and updating RowWorkDiff.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const MIN_TRIANGLE_AREA = SystemsConfigs.MinTriangleArea :: number
const UNTEXTURED_STRIDE = (SystemsConfigs.UntexturedBufferLayoutSize or 32) :: number
const TEXTURED_STRIDE = (SystemsConfigs.RenderBufferLayoutSize or 64) :: number

-- Tables --
local RenderQuadEmitHelper = {}

-- Functions --
-- ============================================================================
-- 1. DIRECT DUAL-STREAM PROJECTED QUAD EMISSION
-- ============================================================================

--[=[
	Emits one already-projected AllInside quad `(0, 1, 2, 3)` directly as 2 triangles into
	UntexTris (32B) or TexTris (64B) and updates RowWorkDiff inline.
	@return (number, number) -- Updated (UntexCount, TexCount).
]=]
function RenderQuadEmitHelper.EmitProjectedQuadDual(
	X0: number, Y0: number, IZ0: number,
	X1: number, Y1: number, IZ1: number,
	X2: number, Y2: number, IZ2: number,
	X3: number, Y3: number, IZ3: number,
	ScaleU: number, ScaleV: number,
	PackedColor: number, TextureId: number,
	Width: number, Height: number,
	UntexTris: buffer, UntexBounds: buffer, UntexCount: number, MaxUntex: number,
	TexTris: buffer, TexBounds: buffer, TexCount: number, MaxTex: number,
	RowWorkDiff: buffer
): (number, number)
	const MaxW = Width - 1 :: number
	const MaxH = Height - 1 :: number
	local NextUntex = UntexCount :: number
	local NextTex = TexCount :: number

	-- Triangle 1: (0, 1, 2) with UVs (0, ScaleV), (0, 0), (ScaleU, 0)
	const Area1 = (X2 - X0) * (Y1 - Y0) - (Y2 - Y0) * (X1 - X0) :: number
	if Area1 > MIN_TRIANGLE_AREA then
		const MinX = math.max(0, math.min(X0, X1, X2)) :: number
		const MaxX = math.min(MaxW, math.max(X0, X1, X2)) :: number
		const MinY = math.max(0, math.min(Y0, Y1, Y2)) :: number
		const MaxY = math.min(MaxH, math.max(Y0, Y1, Y2)) :: number
		if MinX <= MaxX and MinY <= MaxY then
			const InvA = 1 / Area1 :: number
			const SZ0, SZ1, SZ2 = IZ0 * InvA, IZ1 * InvA, IZ2 * InvA
			const HalfSpan = (MaxX - MinX + 1) * 0.5 :: number
			if TextureId == 0 then
				if NextUntex < MaxUntex then
					const Off = NextUntex * UNTEXTURED_STRIDE :: number
					buffer.writei16(UntexTris, Off, X0); buffer.writei16(UntexTris, Off + 2, Y0); buffer.writef32(UntexTris, Off + 4, SZ0)
					buffer.writei16(UntexTris, Off + 8, X1); buffer.writei16(UntexTris, Off + 10, Y1); buffer.writef32(UntexTris, Off + 12, SZ1)
					buffer.writei16(UntexTris, Off + 16, X2); buffer.writei16(UntexTris, Off + 18, Y2); buffer.writef32(UntexTris, Off + 20, SZ2)
					buffer.writeu32(UntexTris, Off + 24, PackedColor)
					const BOff = NextUntex * 4 :: number
					buffer.writeu16(UntexBounds, BOff, MinY); buffer.writeu16(UntexBounds, BOff + 2, MaxY)
					const Cost = math.floor(HalfSpan + 28) :: number
					const SOff, EOff = MinY * 4, (MaxY + 1) * 4
					buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
					buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
					NextUntex += 1
				end
			elseif NextTex < MaxTex then
				const Off = NextTex * TEXTURED_STRIDE :: number
				buffer.writei16(TexTris, Off, X0); buffer.writei16(TexTris, Off + 2, Y0); buffer.writef32(TexTris, Off + 4, SZ0); buffer.writef32(TexTris, Off + 8, 0); buffer.writef32(TexTris, Off + 12, SZ0 * ScaleV)
				buffer.writei16(TexTris, Off + 16, X1); buffer.writei16(TexTris, Off + 18, Y1); buffer.writef32(TexTris, Off + 20, SZ1); buffer.writef32(TexTris, Off + 24, 0); buffer.writef32(TexTris, Off + 28, 0)
				buffer.writei16(TexTris, Off + 32, X2); buffer.writei16(TexTris, Off + 34, Y2); buffer.writef32(TexTris, Off + 36, SZ2); buffer.writef32(TexTris, Off + 40, SZ2 * ScaleU); buffer.writef32(TexTris, Off + 44, 0)
				buffer.writeu32(TexTris, Off + 48, PackedColor); buffer.writeu32(TexTris, Off + 52, TextureId)
				const BOff = NextTex * 4 :: number
				buffer.writeu16(TexBounds, BOff, MinY); buffer.writeu16(TexBounds, BOff + 2, MaxY)
				const Cost = math.floor(HalfSpan * 2 + 20) :: number
				const SOff, EOff = MinY * 4, (MaxY + 1) * 4
				buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
				buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
				NextTex += 1
			end
		end
	end

	-- Triangle 2: (0, 2, 3) with UVs (0, ScaleV), (ScaleU, 0), (ScaleU, ScaleV)
	const Area2 = (X3 - X0) * (Y2 - Y0) - (Y3 - Y0) * (X2 - X0) :: number
	if Area2 > MIN_TRIANGLE_AREA then
		const MinX = math.max(0, math.min(X0, X2, X3)) :: number
		const MaxX = math.min(MaxW, math.max(X0, X2, X3)) :: number
		const MinY = math.max(0, math.min(Y0, Y2, Y3)) :: number
		const MaxY = math.min(MaxH, math.max(Y0, Y2, Y3)) :: number
		if MinX <= MaxX and MinY <= MaxY then
			const InvA = 1 / Area2 :: number
			const SZ0, SZ2, SZ3 = IZ0 * InvA, IZ2 * InvA, IZ3 * InvA
			const HalfSpan = (MaxX - MinX + 1) * 0.5 :: number
			if TextureId == 0 then
				if NextUntex < MaxUntex then
					const Off = NextUntex * UNTEXTURED_STRIDE :: number
					buffer.writei16(UntexTris, Off, X0); buffer.writei16(UntexTris, Off + 2, Y0); buffer.writef32(UntexTris, Off + 4, SZ0)
					buffer.writei16(UntexTris, Off + 8, X2); buffer.writei16(UntexTris, Off + 10, Y2); buffer.writef32(UntexTris, Off + 12, SZ2)
					buffer.writei16(UntexTris, Off + 16, X3); buffer.writei16(UntexTris, Off + 18, Y3); buffer.writef32(UntexTris, Off + 20, SZ3)
					buffer.writeu32(UntexTris, Off + 24, PackedColor)
					const BOff = NextUntex * 4 :: number
					buffer.writeu16(UntexBounds, BOff, MinY); buffer.writeu16(UntexBounds, BOff + 2, MaxY)
					const Cost = math.floor(HalfSpan + 28) :: number
					const SOff, EOff = MinY * 4, (MaxY + 1) * 4
					buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
					buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
					NextUntex += 1
				end
			elseif NextTex < MaxTex then
				const Off = NextTex * TEXTURED_STRIDE :: number
				buffer.writei16(TexTris, Off, X0); buffer.writei16(TexTris, Off + 2, Y0); buffer.writef32(TexTris, Off + 4, SZ0); buffer.writef32(TexTris, Off + 8, 0); buffer.writef32(TexTris, Off + 12, SZ0 * ScaleV)
				buffer.writei16(TexTris, Off + 16, X2); buffer.writei16(TexTris, Off + 18, Y2); buffer.writef32(TexTris, Off + 20, SZ2); buffer.writef32(TexTris, Off + 24, SZ2 * ScaleU); buffer.writef32(TexTris, Off + 28, 0)
				buffer.writei16(TexTris, Off + 32, X3); buffer.writei16(TexTris, Off + 34, Y3); buffer.writef32(TexTris, Off + 36, SZ3); buffer.writef32(TexTris, Off + 40, SZ3 * ScaleU); buffer.writef32(TexTris, Off + 44, SZ3 * ScaleV)
				buffer.writeu32(TexTris, Off + 48, PackedColor); buffer.writeu32(TexTris, Off + 52, TextureId)
				const BOff = NextTex * 4 :: number
				buffer.writeu16(TexBounds, BOff, MinY); buffer.writeu16(TexBounds, BOff + 2, MaxY)
				const Cost = math.floor(HalfSpan * 2 + 20) :: number
				const SOff, EOff = MinY * 4, (MaxY + 1) * 4
				buffer.writei32(RowWorkDiff, SOff, buffer.readi32(RowWorkDiff, SOff) + Cost)
				buffer.writei32(RowWorkDiff, EOff, buffer.readi32(RowWorkDiff, EOff) - Cost)
				NextTex += 1
			end
		end
	end

	return NextUntex, NextTex
end

return RenderQuadEmitHelper
