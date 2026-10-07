local MathModule = {}

local function fastReciprocalSeed(d: number, bitBuffer: buffer): number
	-- Write 32-bit float
	buffer.writef32(bitBuffer, 0, d)

	-- Read bit representation as 32-bit integer
	local i = buffer.readi32(bitBuffer, 0) :: number

	-- Magic constant trick for 1/x reciprocal approximation (0x7EF311C2)
	i = 0x7EF311C2 - i

	-- Write modified integer back and read as 32-bit float
	buffer.writei32(bitBuffer, 0, i)
	return buffer.readf32(bitBuffer, 0)
end

-- Perspective Z solver (Pure Multiplication)
function MathModule.solveCurrentZ(interpolatedInvZ: number, FRSBuffer: buffer): number
	-- 1. Initial 1-cycle bit seed (x0 ≈ 1 / interpolatedInvZ)
	local x0 = fastReciprocalSeed(interpolatedInvZ, FRSBuffer) :: number

	-- 2. Newton-Raphson refinement iteration: x1 = x0 * (2.0 - D * x0)
	-- Operates entirely via multiplication and subtraction (0 divisions)
	local currentZ = x0 * (2.0 - interpolatedInvZ * x0) :: number

	return currentZ
end

function MathModule.EdgeFunction(ax: number, ay: number, bx: number, by: number, px: number, py: number): number
	return (px - ax) * (by - ay) - (py - ay) * (bx - ax)
end

return MathModule
