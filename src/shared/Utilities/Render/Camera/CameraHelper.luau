--!strict
--!native
--!optimize 2

--[=[
	@class CameraHelper
	Mathematical utility functions for camera orthonormal basis matrix construction,
	mouse pitch/yaw input clamping, and BVH-accelerated world occlusion raycasting.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const BVH = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("BVH"))

-- Configs --
const LOOK_DIVISOR = 50 :: number

-- Tables --
local CameraHelper = {}

-- Functions --
-- ============================================================================
-- 1. SINGLE-PLAYER CAMERA MATH & BVH OCCLUSION
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

--[=[
	Computes clamped yaw/pitch rotation from a single-player mouse delta.
	@param CurrentRotation Vector2 -- Current yaw (X) and pitch (Y) in radians.
	@param InputDelta Vector3 -- Pointer movement delta.
	@param MaxPitchRad number -- Maximum pitch magnitude in radians.
	@return Vector2 -- Updated clamped (yaw, pitch) rotation in radians.
]=]
function CameraHelper.ComputeLookRotation(CurrentRotation: Vector2, InputDelta: Vector3, MaxPitchRad: number): Vector2
	const MagX = math.sqrt(math.abs(InputDelta.X)) / LOOK_DIVISOR :: number
	const MagY = math.sqrt(math.abs(InputDelta.Y)) / LOOK_DIVISOR :: number
	const DeltaX = if InputDelta.X > 0 then MagX else -MagX :: number
	const DeltaY = if InputDelta.Y > 0 then MagY else -MagY :: number
	return Vector2.new(
		CurrentRotation.X - DeltaX,
		math.clamp(CurrentRotation.Y - DeltaY, -MaxPitchRad, MaxPitchRad)
	)
end

--[=[
	Ray-casts from camera focus origin toward desired camera position to pull the camera in front of ECS geometry.
	@param Origin Vector3 -- World-space focus origin.
	@param Direction Vector3 -- Desired offset vector from Origin to camera.
	@param ProvidedStorage any? -- Optional isolated ECS storage override for unit tests.
	@return Vector3 -- Clamped world-space camera position.
]=]
function CameraHelper.RaycastWorld(Origin: Vector3, Direction: Vector3, ProvidedStorage: any?): Vector3
	const DirMag = Direction.Magnitude :: number
	if DirMag <= 1e-5 then
		return Origin
	end

	const HitEntityId, _HitDyn, HitDistance = BVH.Raycast(ProvidedStorage, Origin, Direction, DirMag)
	if HitEntityId and HitDistance then
		return Origin + Direction * ((HitDistance * 0.9) / DirMag)
	end
	return Origin + Direction
end

return CameraHelper
