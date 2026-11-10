--!native
--!optimize 2

local MathModule = {}

function MathModule.EdgeFunction(Ax: number, Ay: number, Bx: number, By: number, Px: number, Py: number): number
	return (Px - Ax) * (By - Ay) - (Py - Ay) * (Bx - Ax)
end

return MathModule
