--!strict
--!native
--!optimize 2

--[=[
	===========================================================================
	CameraHelper
	===========================================================================
	Pure helper utilities for CameraService: orthonormal basis construction,
	character root/visibility helpers, world occlusion raycasting, camera shake,
	vertical damping, and zoom/look input computation.
	===========================================================================
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const UserInputService = game:GetService("UserInputService")

-- Modules --
const BVH = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("BVH"))

const CameraHelper = {}

-- ============================================================================
-- 1. CAMERA BASIS & CHARACTER HELPERS
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
	for _, Child in ipairs(RootInstance:GetDescendants()) do
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

	const ShowAll = VisibilityType == "All"
	for _, Child in ipairs(CharacterModel:GetChildren()) do
		if Child:IsA("BasePart") and Child.Name ~= "HumanoidRootPart" then
			CameraHelper.SetDescendantsTransparency(Child, ShowAll)
			if VisibilityType then
				Child.LocalTransparencyModifier = if ShowAll
					then 0
					elseif VisibilityType == "Body" and Child.Name == "Head" then 1
					else 0
			else
				Child.LocalTransparencyModifier = 1
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
function CameraHelper.CalculateShakingOffset(
	Intensity: number,
	CharacterVisibility: string,
	Smoothness: number
): Vector3
	const Sign = if math.random(1, 2) == 1 then -1 else 1 :: number
	const CurrentSeed = math.random(1, os.time()) * Sign
	const X = math.sin(CurrentSeed) * (Intensity * 1.5 ^ 2) / 3
	const Y = math.clamp(math.cos(CurrentSeed) * (Intensity * 1.5 ^ 1.5), 0, 10) / 3
	const Z = if CharacterVisibility == "All" then (math.cos(CurrentSeed) / 2) * Intensity / 5 else 0

	return Vector3.new(X, Y, Z) * math.max(Smoothness ^ 2 * 0.5, 1)
end

--[=[
	Ray-casts from camera focus origin toward desired camera position to pull the camera in front of geometry.
	@param Origin Vector3 -- World-space focus origin.
	@param Direction Vector3 -- Desired offset vector from Origin to camera.
	@param CharacterModel Model? -- Active character model excluded from raycasts.
	@param ActiveHost BasePart? -- Active camera host BasePart excluded from raycasts.
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
	const Hum = if CharacterModel and CharacterModel.Parent
		then CharacterModel:FindFirstChildWhichIsA("Humanoid")
		else nil
	local IsAirborne: boolean
	if Hum then
		const HumState = Hum:GetState()
		IsAirborne = (HumState == Enum.HumanoidStateType.Jumping)
			or (HumState == Enum.HumanoidStateType.Freefall)
	else
		IsAirborne = not IsPlayerGrounded
	end

	if IsAirborne then
		return DesiredTime * 3.33, 0
	end

	const NextLapsed = Lapsed + 1 :: number
	if NextLapsed < 1 / DeltaTime then
		return DesiredTime * 3.33, NextLapsed
	end
	return math.max(DesiredTime, DesiredTime * (3.33 - (NextLapsed - (1 / DeltaTime)) * 0.03)), NextLapsed
end

-- ============================================================================
-- 3. INPUT ZOOM & LOOK HELPERS
-- ============================================================================

--[=[
	Updates target zoom distance from mouse wheel, I/O keys, or gamepad R3 input.
	@param Input InputObject -- Triggering input event.
	@param GameProcessedEvent boolean -- True when UI consumed the event.
	@param CurrentZoom number -- Current zoom distance.
	@param MinZoom number -- Minimum allowed zoom distance.
	@param MaxZoom number -- Maximum allowed zoom distance.
	@return number -- Updated clamped zoom distance.
]=]
function CameraHelper.ComputeZoomFromInput(
	Input: InputObject,
	GameProcessedEvent: boolean,
	CurrentZoom: number,
	MinZoom: number,
	MaxZoom: number
): number
	if GameProcessedEvent then
		return CurrentZoom
	end

	if Input.UserInputType == Enum.UserInputType.MouseWheel then
		const Multiplier = Input.Position.Z :: number
		return math.clamp(CurrentZoom - (Multiplier * (MaxZoom - MinZoom) / 4), MinZoom, MaxZoom)
	elseif
		Input.UserInputState == Enum.UserInputState.Begin
		and (Input.KeyCode == Enum.KeyCode.I or Input.KeyCode == Enum.KeyCode.O)
	then
		const Multiplier = if Input.KeyCode == Enum.KeyCode.I then 1 else -1 :: number
		return math.clamp(CurrentZoom - (Multiplier * (MaxZoom - MinZoom) / 4), MinZoom, MaxZoom)
	elseif Input.KeyCode == Enum.KeyCode.ButtonR3 and Input.UserInputState == Enum.UserInputState.Begin then
		const SteppedZoom = CurrentZoom - ((MaxZoom - MinZoom) / 4)
		return if SteppedZoom < MinZoom then MaxZoom else SteppedZoom
	end

	return CurrentZoom
end

--[=[
	Processes pointer/touch/gamepad look changes and returns updated delta, difference vector, and clamped camera rotation.
	@param Input InputObject -- Triggering input event.
	@param GameProcessedEvent boolean -- True when UI consumed the event.
	@param RightHold boolean -- Whether mouse-lock or right mouse drag is active.
	@param CameraRotation Vector2 -- Current camera pitch/yaw rotation.
	@param XLock boolean -- True if horizontal rotation is locked.
	@param AtX number -- Locked horizontal angle in radians.
	@param YLock boolean -- True if vertical rotation is locked.
	@param AtY number -- Locked vertical angle in radians.
	@param MaxAngle number -- Maximum vertical pitch magnitude in degrees.
	@param CurrentDelta Vector3 -- Previous input delta vector.
	@param CurrentDifference Vector2 -- Previous screen/stick difference vector.
	@return (Vector3, Vector2, Vector2) -- Updated delta, difference vector, and camera rotation.
]=]
function CameraHelper.ComputeLookRotation(
	Input: InputObject,
	GameProcessedEvent: boolean,
	RightHold: boolean,
	CameraRotation: Vector2,
	XLock: boolean,
	AtX: number,
	YLock: boolean,
	AtY: number,
	MaxAngle: number,
	CurrentDelta: Vector3,
	CurrentDifference: Vector2
): (Vector3, Vector2, Vector2)
	const Mobile = Input.UserInputType == Enum.UserInputType.Touch
	const Console = Input.UserInputType == Enum.UserInputType.Gamepad1
		and Input.KeyCode == Enum.KeyCode.Thumbstick2

	if
		not (
			(not GameProcessedEvent or (not Mobile and not Console))
			and (RightHold or Mobile or Console)
			and Input.UserInputState == Enum.UserInputState.Change
		)
	then
		return CurrentDelta, CurrentDifference, CameraRotation
	end

	const NextDelta = if Console
		then Input.Position / 15 * math.sqrt(UserInputService.MouseDeltaSensitivity)
		else Input.Delta

	local NextDifference: Vector2
	if Console then
		const Deadzone = 0.2 / 15 * math.sqrt(UserInputService.MouseDeltaSensitivity) :: number
		NextDifference = Vector2.new(
			if NextDelta.X < Deadzone and NextDelta.X > -Deadzone then 0 else NextDelta.X,
			if -NextDelta.Y < Deadzone and -NextDelta.Y > -Deadzone then 0 else -NextDelta.Y
		)
	else
		const Divisor = if Mobile then 27 else 50 :: number
		const MagX = math.sqrt(math.abs(NextDelta.X)) / Divisor :: number
		const MagY = math.sqrt(math.abs(NextDelta.Y)) / Divisor :: number
		NextDifference = Vector2.new(
			if NextDelta.X > 0 then MagX else -MagX,
			if NextDelta.Y > 0 then MagY else -MagY
		)
	end

	if Console then
		return NextDelta, NextDifference, CameraRotation
	end

	const RawRotation = CameraRotation - NextDifference
	const ClampedRotation = Vector2.new(
		if XLock then AtX else RawRotation.X,
		if YLock then AtY else math.clamp(RawRotation.Y, math.rad(-MaxAngle), math.rad(MaxAngle))
	)
	return NextDelta, NextDifference, ClampedRotation
end

return CameraHelper
