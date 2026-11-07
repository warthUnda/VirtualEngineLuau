local MathModule = {}

local function FastReciprocalSeed(D: number, BitBuffer: buffer): number
	-- Write 32-bit float
	buffer.writef32(BitBuffer, 0, D)

	-- Read bit representation as 32-bit integer
	local i = buffer.readi32(BitBuffer, 0) :: number

	-- Magic constant trick for 1/x reciprocal approximation (0x7EF311C2)
	i = 0x7EF311C2 - i

	-- Write modified integer back and read as 32-bit float
	buffer.writei32(BitBuffer, 0, i)
	return buffer.readf32(BitBuffer, 0)
end

-- Perspective Z solver (Pure Multiplication)
function MathModule.SolveCurrentZ(InterpolatedInvZ: number, FRSBuffer: buffer): number
	-- 1. Initial 1-cycle bit seed (x0 ≈ 1 / InterpolatedInvZ)
	local x0 = FastReciprocalSeed(InterpolatedInvZ, FRSBuffer) :: number

	-- 2. Newton-Raphson refinement iteration: x1 = x0 * (2.0 - D * x0)
	-- Operates entirely via multiplication and subtraction (0 divisions)
	local CurrentZ = x0 * (2.0 - InterpolatedInvZ * x0) :: number

	return CurrentZ
end

function MathModule.EdgeFunction(Ax: number, Ay: number, Bx: number, By: number, Px: number, Py: number): number
	return (Px - Ax) * (By - Ay) - (Py - Ay) * (Bx - Ax)
end

return MathModule
