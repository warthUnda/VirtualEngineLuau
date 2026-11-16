--!strict
--!native
--!optimize 2

-- Services --
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Tables --
local CameraInputMath = {}

-- Functions --
-- ============================================================================
-- 1. INPUT ZOOM & POINTER / GAMEPAD / TOUCH LOOK COMPUTATION
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
function CameraInputMath.ComputeZoomFromInput(
	Input: InputObject,
	GameProcessedEvent: boolean,
	CurrentZoom: number,
	MinZoom: number,
	MaxZoom: number
): number
	if GameProcessedEvent then
		return CurrentZoom
	end

	const ZoomStep = (MaxZoom - MinZoom) / 4 :: number
	if Input.UserInputType == Enum.UserInputType.MouseWheel then
		return math.clamp(CurrentZoom - Input.Position.Z * ZoomStep, MinZoom, MaxZoom)
	end

	if Input.UserInputState ~= Enum.UserInputState.Begin then
		return CurrentZoom
	end

	if Input.KeyCode == Enum.KeyCode.I or Input.KeyCode == Enum.KeyCode.O then
		const Multiplier = if Input.KeyCode == Enum.KeyCode.I then 1 else -1 :: number
		return math.clamp(CurrentZoom - Multiplier * ZoomStep, MinZoom, MaxZoom)
	end

	if Input.KeyCode == Enum.KeyCode.ButtonR3 then
		const SteppedZoom = CurrentZoom - ZoomStep :: number
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
function CameraInputMath.ComputeLookRotation(
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
	const IsMobile = (Input.UserInputType == Enum.UserInputType.Touch) :: boolean
	const IsConsole = (Input.UserInputType == Enum.UserInputType.Gamepad1 and Input.KeyCode == Enum.KeyCode.Thumbstick2) :: boolean
	const CanProcessInput = (not GameProcessedEvent or (not IsMobile and not IsConsole)) :: boolean
	const HasActivePan = (RightHold or IsMobile or IsConsole) :: boolean

	if not CanProcessInput or not HasActivePan or Input.UserInputState ~= Enum.UserInputState.Change then
		return CurrentDelta, CurrentDifference, CameraRotation
	end

	const SensitivityRoot = math.sqrt(UserInputService.MouseDeltaSensitivity) :: number
	const NextDelta = if IsConsole then Input.Position / 15 * SensitivityRoot else Input.Delta :: Vector3

	if IsConsole then
		const Deadzone = 0.2 / 15 * SensitivityRoot :: number
		const ConsoleDiff = Vector2.new(
			if NextDelta.X < Deadzone and NextDelta.X > -Deadzone then 0 else NextDelta.X,
			if -NextDelta.Y < Deadzone and -NextDelta.Y > -Deadzone then 0 else -NextDelta.Y
		)
		return NextDelta, ConsoleDiff, CameraRotation
	end

	const Divisor = if IsMobile then 27 else 50 :: number
	const MagX = math.sqrt(math.abs(NextDelta.X)) / Divisor :: number
	const MagY = math.sqrt(math.abs(NextDelta.Y)) / Divisor :: number
	const NextDifference = Vector2.new(
		if NextDelta.X > 0 then MagX else -MagX,
		if NextDelta.Y > 0 then MagY else -MagY
	)

	const RawRotation = CameraRotation - NextDifference :: Vector2
	const PitchLimit = math.rad(MaxAngle) :: number
	const ClampedRotation = Vector2.new(
		if XLock then AtX else RawRotation.X,
		if YLock then AtY else math.clamp(RawRotation.Y, -PitchLimit, PitchLimit)
	)
	return NextDelta, NextDifference, ClampedRotation
end

return CameraInputMath
