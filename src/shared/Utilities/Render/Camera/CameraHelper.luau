--!strict
--!native
--!optimize 2

local CameraHelper = {}

-- ============================================================================
-- 1. CAMERA BASIS MATRIX HELPER
-- ============================================================================

--[=[
	Constructs an orthonormal rotation CFrame from camera basis direction vectors.
	@param LookVector Vector3 -- Camera forward direction.
	@param UpVector Vector3 -- Camera upward direction.
	@param RightVector Vector3 -- Camera rightward direction.
	@return CFrame -- Rotation CFrame centered at Vector3.zero.
]=]
function CameraHelper.VectorsToRotation(LookVector: Vector3, UpVector: Vector3, RightVector: Vector3): CFrame
	const BackAxis = -LookVector.Unit :: Vector3
	const UpAxis = UpVector.Unit :: Vector3
	const RightAxis = RightVector.Unit :: Vector3
	return CFrame.fromMatrix(Vector3.zero, RightAxis, UpAxis, BackAxis)
end

return CameraHelper
