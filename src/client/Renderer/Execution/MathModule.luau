--!native
--!optimize 2

local HelperFunction = {}

-- Modules --
local BufferHelper = require(game.ReplicatedStorage.Shared.Utilities.BufferHelper)

-- Caching --
local Rad = math.rad
local Tan = math.tan
local Floor = math.floor

local Min = math.min
local Max = math.max

local Vector3New = Vector3.new

local BufferWriteU8 = buffer.writeu8

-- Pointer array functions

local function Interpolation(
	Area: number,
	invZ0: number,
	invZ1: number,
	invZ2: number,
	w0: number,
	w1: number,
	w2: number,
	y: number,
	x: number,
	WIDTH: number,
	ZBuffer: { number }
): number
	const l0 = w0 / Area :: number
	const l1 = w1 / Area :: number
	const l2 = w2 / Area :: number

	const interpolatedInvZ = l0 * invZ0 + l1 * invZ1 + l2 * invZ2 :: number
	const currentZ = 1 / interpolatedInvZ :: number

	const bufferIdx = (y * WIDTH + x) + 1 :: number

	const isTrueBit = (ZBuffer[bufferIdx] > currentZ and 1 or 2) :: number
	ZBuffer[bufferIdx] = Min(ZBuffer[bufferIdx], currentZ)

	return isTrueBit
end

local function FailFunction()
	return 2
end

local function BufferPixelWrite(PixelBuffer: buffer, screenOffset: number, r: number, g: number, b: number, a: number)
	BufferWriteU8(PixelBuffer, screenOffset + 0, r)
	BufferWriteU8(PixelBuffer, screenOffset + 1, g)
	BufferWriteU8(PixelBuffer, screenOffset + 2, b)
	BufferWriteU8(PixelBuffer, screenOffset + 3, a)
end

local BufferWriteTable = { BufferPixelWrite, FailFunction }

function HelperFunction.EdgeFunction(ax: number, ay: number, bx: number, by: number, px: number, py: number): number
	return (px - ax) * (by - ay) - (py - ay) * (bx - ax)
end

function HelperFunction.GetPartWorldVertices(Part: Part, TargetTable: {}) -- Is local number only memory offset, wont get updated
	const cf = Part.CFrame :: CFrame
	const size = Part.Size :: Vector3
	const hX: number, hY: number, hZ: number = size.X * 0.5, size.Y * 0.5, size.Z * 0.5

	TargetTable[1] = cf * Vector3New(-hX, -hY, -hZ)
	TargetTable[2] = cf * Vector3New(hX, -hY, -hZ)
	TargetTable[3] = cf * Vector3New(hX, hY, -hZ)
	TargetTable[4] = cf * Vector3New(-hX, hY, -hZ)
	TargetTable[5] = cf * Vector3New(-hX, -hY, hZ)
	TargetTable[6] = cf * Vector3New(hX, -hY, hZ)
	TargetTable[7] = cf * Vector3New(hX, hY, hZ)
	TargetTable[8] = cf * Vector3New(-hX, hY, hZ)
end

function HelperFunction.ProjectWorldPointToScreen(
	WorldPoint: Vector3,
	CamCFrame: CFrame,
	FovY: number,
	WIDTH: number,
	HEIGHT: number
)
	const camLocalPoint = CamCFrame:PointToObjectSpace(WorldPoint) :: Vector3
	const z = -camLocalPoint.Z :: number
	if z <= 0.1 then
		return nil
	end

	const fovRad = Rad(FovY) :: number
	const focalLength = (HEIGHT * 0.5) / Tan(fovRad * 0.5) :: number

	const screenX = Floor((camLocalPoint.X / z) * focalLength + (WIDTH * 0.5)) :: number
	const screenY = Floor((-camLocalPoint.Y / z) * focalLength + (HEIGHT * 0.5)) :: number

	return Vector3New(screenX, screenY, z)
end

function HelperFunction.DrawTriangle(
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	r: number,
	g: number,
	b: number,
	WIDTH: number,
	HEIGHT: number,
	PixelBuffer: buffer,
	ZBuffer: { number }
)
	const x0: number, y0: number, z0: number = v0.X, v0.Y, v0.Z
	const x1: number, y1: number, z1: number = v1.X, v1.Y, v1.Z
	const x2: number, y2: number, z2: number = v2.X, v2.Y, v2.Z

	const area = HelperFunction.EdgeFunction(x0, y0, x1, y1, x2, y2) :: number
	if area <= 0 then
		return
	end

	const invZ0: number, invZ1: number, invZ2: number = 1 / z0, 1 / z1, 1 / z2

	const minX = Max(0, Min(x0, x1, x2)) :: number
	const maxX = Min(WIDTH - 1, Max(x0, x1, x2)) :: number
	const minY = Max(0, Min(y0, y1, y2)) :: number
	const maxY = Min(HEIGHT - 1, Max(y0, y1, y2)) :: number

	for y = minY, maxY do
		for x = minX, maxX do
			const w0 = HelperFunction.EdgeFunction(x1, y1, x2, y2, x, y) :: number
			const w1 = HelperFunction.EdgeFunction(x2, y2, x0, y0, x, y) :: number
			const w2 = HelperFunction.EdgeFunction(x0, y0, x1, y1, x, y) :: number

			if w0 >= 0 and w1 >= 0 and w2 >= 0 then
				const CountBit = Interpolation(area, invZ0, invZ1, invZ2, w0, w1, w2, y, x, WIDTH, ZBuffer) :: number

				BufferWriteTable[CountBit](PixelBuffer, ((y * WIDTH + x) * 4), r, g, b, 255)
			end
		end
	end
end

function HelperFunction.ClearBuffers(TOTAL_PIXELS: number, PixelBuffer: buffer, ZBuffer: { number })
	for i = 1, TOTAL_PIXELS do
		ZBuffer[i] = 1000.0
		local offset = (i - 1) * 4 :: number
		BufferWriteU8(PixelBuffer, offset + 0, 15)
		BufferWriteU8(PixelBuffer, offset + 1, 15)
		BufferWriteU8(PixelBuffer, offset + 2, 20)
		BufferWriteU8(PixelBuffer, offset + 3, 255)
	end
end

return HelperFunction
