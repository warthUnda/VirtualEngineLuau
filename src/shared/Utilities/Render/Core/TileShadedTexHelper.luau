--!strict
--!native
--!optimize 2

--[=[
	@class TileShadedTexHelper
	Per-worker L1 pre-shaded texture cache and hoisted Z-test / Z-write / UV-bounds textured span drawer.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))

-- Configs --
const DEFAULT_TEX_SIZE = (SystemsConfigs.TextureSize or 64) :: number
const MAX_SLOT_BYTES = DEFAULT_TEX_SIZE * DEFAULT_TEX_SIZE * 4 :: number
const CACHE_SLOT_COUNT = 16 :: number

-- Variables --
local NextEvictSlot = 1 :: number

-- Buffers
const InvStepsBuf = buffer.create(16 * 8) :: buffer
for StepCount = 1, 15 do
	buffer.writef64(InvStepsBuf, StepCount * 8, 1 / StepCount)
end

-- Tables --
const CachedSourceBufs = table.create(CACHE_SLOT_COUNT) :: { buffer? }
const CachedShadeKeys = table.create(CACHE_SLOT_COUNT, -1) :: { number }
const CachedByteLens = table.create(CACHE_SLOT_COUNT, 0) :: { number }
const CachedShadedBufs = table.create(CACHE_SLOT_COUNT) :: { buffer }

for SlotIdx = 1, CACHE_SLOT_COUNT do
	CachedShadedBufs[SlotIdx] = buffer.create(MAX_SLOT_BYTES)
end

local TileShadedTexHelper = {}

-- Functions --
-- ============================================================================
-- 1. PRE-SHADED L1 TEXTURE RING CACHE & HOISTED SPAN RASTERIZATION
-- ============================================================================

--[=[
	Returns a pre-shaded RGBA u32 buffer with `PackedColor` lighting and `0xFF000000` alpha baked in.
]=]
function TileShadedTexHelper.GetShadedTexture(
	ActiveTex: buffer,
	PackedColor: number,
	TexW: number,
	TexH: number
): buffer
	const TotalBytes = TexW * TexH * 4 :: number
	const ShadeKey = bit32.band(PackedColor, 0x00FFFFFF) :: number

	for SlotIdx = 1, CACHE_SLOT_COUNT do
		if
			CachedSourceBufs[SlotIdx] == ActiveTex
			and CachedShadeKeys[SlotIdx] == ShadeKey
			and CachedByteLens[SlotIdx] == TotalBytes
		then
			return CachedShadedBufs[SlotIdx]
		end
	end

	const TargetSlot = NextEvictSlot :: number
	NextEvictSlot = if TargetSlot >= CACHE_SLOT_COUNT then 1 else TargetSlot + 1

	local OutBuf = CachedShadedBufs[TargetSlot] :: buffer
	if buffer.len(OutBuf) < TotalBytes then
		OutBuf = buffer.create(TotalBytes)
		CachedShadedBufs[TargetSlot] = OutBuf
	end

	CachedSourceBufs[TargetSlot] = ActiveTex
	CachedShadeKeys[TargetSlot] = ShadeKey
	CachedByteLens[TargetSlot] = TotalBytes

	local ShadeR = bit32.band(PackedColor, 0xFF) :: number
	local ShadeG = bit32.band(bit32.rshift(PackedColor, 8), 0xFF) :: number
	local ShadeB = bit32.band(bit32.rshift(PackedColor, 16), 0xFF) :: number
	ShadeR = if ShadeR > 0 then ShadeR + 1 else 0
	ShadeG = if ShadeG > 0 then ShadeG + 1 else 0
	ShadeB = if ShadeB > 0 then ShadeB + 1 else 0

	const LastByte = TotalBytes - 4 :: number
	if ShadeR >= 256 and ShadeG >= 256 and ShadeB >= 256 then
		for Off = 0, LastByte, 4 do
			buffer.writeu32(OutBuf, Off, bit32.bor(buffer.readu32(ActiveTex, Off), 0xFF000000))
		end
	elseif ShadeR == ShadeG and ShadeG == ShadeB then
		for Off = 0, LastByte, 4 do
			const TexCol = buffer.readu32(ActiveTex, Off) :: number
			const OutRB = bit32.band(bit32.rshift(bit32.band(TexCol, 0x00FF00FF) * ShadeR, 8), 0x00FF00FF) :: number
			const OutG = bit32.band(bit32.rshift(bit32.band(TexCol, 0x0000FF00) * ShadeR, 8), 0x0000FF00) :: number
			buffer.writeu32(OutBuf, Off, bit32.bor(OutRB, OutG, 0xFF000000))
		end
	else
		for Off = 0, LastByte, 4 do
			const TexCol = buffer.readu32(ActiveTex, Off) :: number
			const OutR = bit32.rshift(bit32.band(TexCol, 0xFF) * ShadeR, 8) :: number
			const OutG = bit32.rshift(bit32.band(bit32.rshift(TexCol, 8), 0xFF) * ShadeG, 8) :: number
			const OutB = bit32.rshift(bit32.band(bit32.rshift(TexCol, 16), 0xFF) * ShadeB, 8) :: number
			buffer.writeu32(OutBuf, Off, bit32.bor(OutR, bit32.lshift(OutG, 8), bit32.lshift(OutB, 16), 0xFF000000))
		end
	end

	return OutBuf
end

--[=[
	Draws a perspective-correct scanline span from a pre-shaded texture buffer with hoisted
	`SkipZTest`, `SkipZWrite`, reciprocal LUT tail steps, and ULP-safe `InBounds` sub-spans.
]=]
function TileShadedTexHelper.DrawPreShadedSpan(
	StartOffset: number,
	EndOffset: number,
	StartInvZ: number,
	StartUOverZ: number,
	StartVOverZ: number,
	InvZStepX: number,
	UOverZStepX: number,
	VOverZStepX: number,
	ShadedTex: buffer,
	TexW: number,
	TexH: number,
	TexWMask: number,
	TexHMask: number,
	SkipZTest: boolean,
	PixelBuf: buffer,
	ZBuf: buffer,
	SkipZWrite: boolean?
)
	local BufferOffset = StartOffset :: number
	local CurInvZ = StartInvZ :: number
	local CurUOverZ = StartUOverZ :: number
	local CurVOverZ = StartVOverZ :: number

	const DepthStart = 1 / CurInvZ :: number
	local CurU = CurUOverZ * DepthStart :: number
	local CurV = CurVOverZ * DepthStart :: number
	const AbsZStep16 = math.abs(InvZStepX * 16) :: number
	const SafeMaxW = TexW - 1e-3 :: number
	const SafeMaxH = TexH - 1e-3 :: number

	while BufferOffset <= EndOffset do
		const Remaining = ((EndOffset - BufferOffset) // 4) + 1 :: number
		const MaxChunk = if AbsZStep16 > 0.15 * math.abs(CurInvZ) then 8 else 16 :: number
		const IsInterior = Remaining > MaxChunk :: boolean
		const Chunk = if IsInterior then MaxChunk else Remaining :: number

		local StepU = 0 :: number
		local StepV = 0 :: number
		local NextInvZ = CurInvZ :: number
		local NextUOverZ = CurUOverZ :: number
		local NextVOverZ = CurVOverZ :: number
		local NextU = CurU :: number
		local NextV = CurV :: number
		local LastU = CurU :: number
		local LastV = CurV :: number

		if IsInterior then
			NextInvZ = CurInvZ + Chunk * InvZStepX
			NextUOverZ = CurUOverZ + Chunk * UOverZStepX
			NextVOverZ = CurVOverZ + Chunk * VOverZStepX
			const DepthEnd = 1 / NextInvZ :: number
			NextU = NextUOverZ * DepthEnd
			NextV = NextVOverZ * DepthEnd
			const InvChunk = if Chunk == 16 then 0.0625 else 0.125 :: number
			StepU = (NextU - CurU) * InvChunk
			StepV = (NextV - CurV) * InvChunk
			LastU = NextU
			LastV = NextV
		elseif Chunk > 1 then
			const EndSteps = Chunk - 1 :: number
			const EndDepth = 1 / (CurInvZ + EndSteps * InvZStepX) :: number
			const EndU = (CurUOverZ + EndSteps * UOverZStepX) * EndDepth :: number
			const EndV = (CurVOverZ + EndSteps * VOverZStepX) * EndDepth :: number
			const InvSteps = buffer.readf64(InvStepsBuf, EndSteps * 8) :: number
			StepU = (EndU - CurU) * InvSteps
			StepV = (EndV - CurV) * InvSteps
			LastU = EndU
			LastV = EndV
		end

		const InBounds = (
			CurU >= 1e-3 and LastU >= 1e-3 and CurU <= SafeMaxW and LastU <= SafeMaxW
			and CurV >= 1e-3 and LastV >= 1e-3 and CurV <= SafeMaxH and LastV <= SafeMaxH
		) :: boolean
		const ChunkEndOffset = BufferOffset + (Chunk - 1) * 4 :: number

		if SkipZTest and SkipZWrite and InBounds then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				const TexOff = (math.floor(CurV) * TexW + math.floor(CurU)) * 4 :: number
				buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, TexOff))
				CurU += StepU
				CurV += StepV
			end
		elseif SkipZTest and SkipZWrite then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				const TexX = math.clamp(math.floor(CurU), 0, TexWMask) :: number
				const TexY = math.clamp(math.floor(CurV), 0, TexHMask) :: number
				buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, (TexY * TexW + TexX) * 4))
				CurU += StepU
				CurV += StepV
			end
		elseif SkipZTest and InBounds then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				buffer.writef32(ZBuf, PxOff, CurInvZ)
				const TexOff = (math.floor(CurV) * TexW + math.floor(CurU)) * 4 :: number
				buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, TexOff))
				CurInvZ += InvZStepX
				CurU += StepU
				CurV += StepV
			end
		elseif SkipZTest then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				buffer.writef32(ZBuf, PxOff, CurInvZ)
				const TexX = math.clamp(math.floor(CurU), 0, TexWMask) :: number
				const TexY = math.clamp(math.floor(CurV), 0, TexHMask) :: number
				buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, (TexY * TexW + TexX) * 4))
				CurInvZ += InvZStepX
				CurU += StepU
				CurV += StepV
			end
		elseif SkipZWrite and InBounds then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				if CurInvZ > buffer.readf32(ZBuf, PxOff) then
					const TexOff = (math.floor(CurV) * TexW + math.floor(CurU)) * 4 :: number
					buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, TexOff))
				end
				CurInvZ += InvZStepX
				CurU += StepU
				CurV += StepV
			end
		elseif InBounds then
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				if CurInvZ > buffer.readf32(ZBuf, PxOff) then
					buffer.writef32(ZBuf, PxOff, CurInvZ)
					const TexOff = (math.floor(CurV) * TexW + math.floor(CurU)) * 4 :: number
					buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, TexOff))
				end
				CurInvZ += InvZStepX
				CurU += StepU
				CurV += StepV
			end
		else
			for PxOff = BufferOffset, ChunkEndOffset, 4 do
				if CurInvZ > buffer.readf32(ZBuf, PxOff) then
					if not SkipZWrite then buffer.writef32(ZBuf, PxOff, CurInvZ) end
					const TexX = math.clamp(math.floor(CurU), 0, TexWMask) :: number
					const TexY = math.clamp(math.floor(CurV), 0, TexHMask) :: number
					buffer.writeu32(PixelBuf, PxOff, buffer.readu32(ShadedTex, (TexY * TexW + TexX) * 4))
				end
				CurInvZ += InvZStepX
				CurU += StepU
				CurV += StepV
			end
		end

		BufferOffset = ChunkEndOffset + 4
		if IsInterior then
			CurInvZ = NextInvZ
			CurUOverZ = NextUOverZ
			CurVOverZ = NextVOverZ
			CurU = NextU
			CurV = NextV
		end
	end
end

return TileShadedTexHelper
