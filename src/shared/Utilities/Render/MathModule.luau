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

-- Local functions --
local function BufferPixelWrite(PixelBuffer: buffer, screenOffset: number, r: number, g: number, b: number, a: number)
	BufferWriteU8(PixelBuffer, screenOffset + 0, r)
	BufferWriteU8(PixelBuffer, screenOffset + 1, g)
	BufferWriteU8(PixelBuffer, screenOffset + 2, b)
	BufferWriteU8(PixelBuffer, screenOffset + 3, a)
end

local function fastReciprocalSeed(d: number, bitBuffer: buffer): number
	-- Write 32-bit float
	buffer.writef32(bitBuffer, 0, d)

	-- Read bit representation as 32-bit integer
	local i = buffer.readi32(bitBuffer, 0)

	-- Magic constant trick for 1/x reciprocal approximation (0x7EF311C2)
	i = 0x7EF311C2 - i

	-- Write modified integer back and read as 32-bit float
	buffer.writei32(bitBuffer, 0, i)
	return buffer.readf32(bitBuffer, 0)
end

-- Perspective Z solver (Pure Multiplication)
local function solveCurrentZ(interpolatedInvZ: number, FRSBuffer: buffer): number
	-- 1. Initial 1-cycle bit seed (x0 ≈ 1 / interpolatedInvZ)
	local x0 = fastReciprocalSeed(interpolatedInvZ, FRSBuffer)

	-- 2. Newton-Raphson refinement iteration: x1 = x0 * (2.0 - D * x0)
	-- Operates entirely via multiplication and subtraction (0 divisions)
	local currentZ = x0 * (2.0 - interpolatedInvZ * x0)

	return currentZ
end

-- Main functions --
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
	ZBuffer: buffer,
	FRSBuffer: buffer
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

	const InvArea = 1 / area :: number

	for y = minY, maxY do
		for x = minX, maxX do
			const w0 = HelperFunction.EdgeFunction(x1, y1, x2, y2, x, y) :: number
			const w1 = HelperFunction.EdgeFunction(x2, y2, x0, y0, x, y) :: number
			const w2 = HelperFunction.EdgeFunction(x0, y0, x1, y1, x, y) :: number

			if w0 >= 0 and w1 >= 0 and w2 >= 0 then
				const l0 = w0 * InvArea :: number
				const l1 = w1 * InvArea :: number
				const l2 = w2 * InvArea :: number

				const interpolatedInvZ = l0 * invZ0 + l1 * invZ1 + l2 * invZ2 :: number
				const currentZ = solveCurrentZ(interpolatedInvZ, FRSBuffer) :: number

				local XYWidth = y * WIDTH + x :: number

				const bufferOffset = XYWidth * 4 :: number

				if currentZ < buffer.readf32(ZBuffer, bufferOffset) then
					buffer.writef32(ZBuffer, bufferOffset, currentZ)
					BufferPixelWrite(PixelBuffer, (XYWidth * 4), r, g, b, 255)
				end
			end
		end
	end
end

function HelperFunction.ClearBuffers(TOTAL_PIXELS: number, PixelBuffer: buffer, ZBuffer: buffer)
	for i = 1, TOTAL_PIXELS do
		buffer.writef32(ZBuffer, (i - 1) * 4, 1000.0)
		local offset = (i - 1) * 4 :: number
		BufferWriteU8(PixelBuffer, offset + 0, 15)
		BufferWriteU8(PixelBuffer, offset + 1, 15)
		BufferWriteU8(PixelBuffer, offset + 2, 20)
		BufferWriteU8(PixelBuffer, offset + 3, 255)
	end
end

return HelperFunction
