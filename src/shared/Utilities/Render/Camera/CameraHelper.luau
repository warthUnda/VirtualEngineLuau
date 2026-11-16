--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Libraries --
const BVH = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("BVH"))
const CameraInputMath = require(script.Parent.CameraInputMath)

-- Tables --
local CameraHelper = {
	ComputeZoomFromInput = CameraInputMath.ComputeZoomFromInput,
	ComputeLookRotation = CameraInputMath.ComputeLookRotation,
}

-- Functions --
-- ============================================================================
-- 1. CAMERA BASIS & CHARACTER VISIBILITY HELPERS
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
	Resolves the primary tracking BasePart for a character model (HumanoidRootPart, PrimaryPart, or first BasePart).
	@param CharacterModel Model? -- Active character model, if present.
	@return BasePart? -- Resolved root part or nil when unavailable.
]=]
function CameraHelper.ResolveCharacterRoot(CharacterModel: Model?): BasePart?
	if not CharacterModel or not CharacterModel.Parent then
		return nil
	end
	const RootCandidate = CharacterModel:FindFirstChild("HumanoidRootPart")
		or CharacterModel.PrimaryPart
		or CharacterModel:FindFirstChildWhichIsA("BasePart")
	if RootCandidate and RootCandidate:IsA("BasePart") then
		return RootCandidate
	end
	return nil
end

--[=[
	Applies local transparency visibility across all descendant BaseParts and Decals of an instance.
	@param RootInstance Instance -- Parent part or accessory whose descendants are updated.
	@param IsVisible boolean -- True makes descendants visible (0), false hides them (1).
]=]
function CameraHelper.SetDescendantsTransparency(RootInstance: Instance, IsVisible: boolean)
	const Modifier = if IsVisible then 0 else 1 :: number
	for _, Child: Instance in ipairs(RootInstance:GetDescendants()) do
		if Child:IsA("BasePart") or Child:IsA("Decal") then
			Child.LocalTransparencyModifier = Modifier
		end
	end
end

--[=[
	Configures character AutoRotate and part/accessory visibility for the active camera mode.
	@param CharacterModel Model? -- Active character model.
	@param AlignChar boolean -- Whether character rotation aligns with camera.
	@param VisibilityType string? -- Visibility mode ("All", "Body", or nil to hide all).
]=]
function CameraHelper.HideBodyParts(CharacterModel: Model?, AlignChar: boolean, VisibilityType: string?)
	if not CharacterModel or not CharacterModel.Parent then
		return
	end

	const Hum = CharacterModel:FindFirstChildWhichIsA("Humanoid")
	if Hum then
		Hum.AutoRotate = not AlignChar
	end

	const ShowAll = (VisibilityType == "All") :: boolean
	for _, Child: Instance in ipairs(CharacterModel:GetChildren()) do
		if Child:IsA("BasePart") and Child.Name ~= "HumanoidRootPart" then
			CameraHelper.SetDescendantsTransparency(Child, ShowAll)
			if not VisibilityType then
				Child.LocalTransparencyModifier = 1
			elseif VisibilityType == "Body" and Child.Name == "Head" then
				Child.LocalTransparencyModifier = 1
			else
				Child.LocalTransparencyModifier = 0
			end
		elseif Child:IsA("Accessory") and Child:FindFirstChildWhichIsA("BasePart") then
			CameraHelper.SetDescendantsTransparency(Child, ShowAll)
		end
	end
end

-- ============================================================================
-- 2. SHAKE, RAYCAST OCCLUSION & VERTICAL DAMPING
-- ============================================================================

--[=[
	Computes a procedural per-frame camera shake offset vector.
	@param Intensity number -- Configured shake intensity.
	@param CharacterVisibility string -- Current visibility mode ("All" enables subtle Z roll/offset).
	@param Smoothness number -- Current camera smoothness factor.
	@return Vector3 -- Computed frame shake offset.
]=]
function CameraHelper.CalculateShakingOffset(Intensity: number, CharacterVisibility: string, Smoothness: number): Vector3
	const Sign = if math.random(1, 2) == 1 then -1 else 1 :: number
	const CurrentSeed = math.random(1, os.time()) * Sign :: number
	const X = math.sin(CurrentSeed) * (Intensity * 1.5 ^ 2) / 3 :: number
	const Y = math.clamp(math.cos(CurrentSeed) * (Intensity * 1.5 ^ 1.5), 0, 10) / 3 :: number
	const Z = if CharacterVisibility == "All" then (math.cos(CurrentSeed) / 2) * Intensity / 5 else 0 :: number
	return Vector3.new(X, Y, Z) * math.max(Smoothness ^ 2 * 0.5, 1)
end

--[=[
	Ray-casts from camera focus origin toward desired camera position to pull the camera in front of ECS geometry.
	@param Origin Vector3 -- World-space focus origin.
	@param Direction Vector3 -- Desired offset vector from Origin to camera.
	@param _CharacterModel Model? -- Unused legacy character slot.
	@param _ActiveHost BasePart? -- Unused legacy host slot.
	@param ProvidedStorage any? -- Optional isolated ECS storage override for unit tests.
	@return Vector3 -- Clamped world-space camera position.
]=]
function CameraHelper.RaycastWorld(
	Origin: Vector3,
	Direction: Vector3,
	_CharacterModel: Model?,
	_ActiveHost: BasePart?,
	ProvidedStorage: any?
): Vector3
	const DirMag = Direction.Magnitude :: number
	if DirMag <= 1e-5 then
		return Origin
	end

	const HitEntityId, _HitDyn, HitDistance = BVH.Raycast(ProvidedStorage, Origin, Direction, DirMag, nil)
	if HitEntityId and HitDistance then
		return Origin + Direction * ((HitDistance * 0.9) / DirMag)
	end
	return Origin + Direction
end

--[=[
	Computes vertical damping factor during jump/freefall and updates the landing frame counter.
	@param DesiredTime number -- Base horizontal smoothing time constant.
	@param DeltaTime number -- Frame delta time in seconds.
	@param Lapsed number -- Frames elapsed since becoming grounded.
	@param CharacterModel Model? -- Active character model, if any.
	@param IsPlayerGrounded boolean -- Fallback grounded flag from PhysicsController when Humanoid is absent.
	@return (number, number) -- Damped vertical smoothing time constant and updated Lapsed counter.
]=]
function CameraHelper.ComputeVerticalDamping(
	DesiredTime: number,
	DeltaTime: number,
	Lapsed: number,
	CharacterModel: Model?,
	IsPlayerGrounded: boolean
): (number, number)
	const Hum = if CharacterModel and CharacterModel.Parent then CharacterModel:FindFirstChildWhichIsA("Humanoid") else nil
	local IsAirborne = (not IsPlayerGrounded) :: boolean
	if Hum then
		const HumState = Hum:GetState()
		IsAirborne = (HumState == Enum.HumanoidStateType.Jumping) or (HumState == Enum.HumanoidStateType.Freefall)
	end

	if IsAirborne then
		return DesiredTime * 3.33, 0
	end

	const NextLapsed = Lapsed + 1 :: number
	const FramesPerSecond = 1 / DeltaTime :: number
	if NextLapsed < FramesPerSecond then
		return DesiredTime * 3.33, NextLapsed
	end
	return math.max(DesiredTime, DesiredTime * (3.33 - (NextLapsed - FramesPerSecond) * 0.03)), NextLapsed
end

return CameraHelper
