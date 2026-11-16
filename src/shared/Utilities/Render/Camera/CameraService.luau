--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const TweenService = game:GetService("TweenService") :: TweenService
const UserInputService = game:GetService("UserInputService") :: UserInputService

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerMouse = LocalPlayer:GetMouse() :: Mouse

-- Libraries --
const CameraStore = require(script.Parent.CameraStore)
const CameraHelper = require(script.Parent.CameraHelper)
const CameraPresets = require(script.Parent.CameraPresets)
const CameraRigHelper = require(script.Parent.CameraRigHelper)
const CameraStepRunner = require(script.Parent.CameraStepRunner)

-- Configs --
const TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out) :: TweenInfo
const CamTable = CameraStore.GetCameraTable()
const ViewPresets = CameraPresets.ViewPresets
const PropertyDefaults = CameraPresets.PropertyDefaults

-- Tables --
local State: CameraPresets.CameraRuntimeState = CameraPresets.CreateRuntimeState(LocalPlayer.Character)

local CameraService = {
	CameraView = "Default" :: string,
	CharacterVisibility = "All" :: string,
	Smoothness = 0.5 :: number,
	Zoom = 10 :: number,
	RotSmoothness = 1 :: number,
	AlignChar = false :: boolean,
	Offset = CFrame.new() :: CFrame,
	MinZoom = 5 :: number,
	MaxZoom = 15 :: number,
	LockMouse = false :: boolean,
	BodyFollow = true :: boolean,
	Wobble = 0 :: number,
	TiltFactor = CFrame.fromEulerAnglesYXZ(0, 0, 0) :: CFrame,
	Angle = 60 :: number,
	Host = CameraHelper.ResolveCharacterRoot(State.CurrentCharacter) :: BasePart?,
	xLock = false :: boolean,
	yLock = false :: boolean,
	atX = 0 :: number,
	atY = 0 :: number,
	Shaking = false :: boolean,
	ShakingIntensity = 0 :: number,
}

-- Functions --
-- ============================================================================
-- 1. PUBLIC CAMERA SERVICE FACADE - VIEWS, PROPERTIES & EFFECTS
-- ============================================================================

--[=[
	Sets the camera to a built-in or custom view, disconnecting previous listeners.
	@param ViewType string -- Registered camera view identifier.
]=]
function CameraService:SetCameraView(ViewType: string)
	assert(ViewPresets[ViewType] ~= nil, "[CameraService] Camera view not found for ID: " .. tostring(ViewType))

	const SelfTable = CameraService :: { [string]: any }
	CameraService.CameraView = ViewType
	for PropertyKey: string, PropertyVal: any in pairs(ViewPresets[ViewType]) do
		SelfTable[PropertyKey] = PropertyVal
	end
	CameraStepRunner.DisconnectAll(State.ConnectionList)

	if ViewType == "Default" then
		CameraService.LockMouse = false
		const DefaultHum = if State.CurrentCharacter and State.CurrentCharacter.Parent
			then State.CurrentCharacter:FindFirstChildWhichIsA("Humanoid")
			else nil
		CamTable.CameraSubject = DefaultHum
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		CamTable.CameraType = Enum.CameraType.Custom
		workspace.Retargeting = Enum.AnimatorRetargetingMode.Default
		if DefaultHum then
			DefaultHum.AutoRotate = true
		end
	else
		workspace.Retargeting = Enum.AnimatorRetargetingMode.Disabled
		if not State.CustomHost and State.CurrentCharacter and State.CurrentCharacter.Parent then
			CameraHelper.HideBodyParts(
				State.CurrentCharacter,
				CameraService.AlignChar,
				if CameraService.CharacterVisibility ~= "None" then CameraService.CharacterVisibility else nil
			)
		end
		UserInputService.MouseBehavior = if CameraService.LockMouse then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
		CamTable.CameraType = Enum.CameraType.Scriptable
		CamTable.CameraSubject = nil
		CameraStepRunner.BindViewInputs(State, CameraService, PlayerMouse, ViewType)
	end

	CameraRigHelper.SyncCinematicBars(LocalPlayer, ViewType)
end

--[=[
	Registers a new camera view preset with fallback defaults for omitted keys.
	@param Id string -- Unique identifier for the new view.
	@param SettingsArray { [string]: any } -- Table of camera property overrides.
]=]
function CameraService:CreateNewCameraView(Id: string, SettingsArray: { [string]: any })
	assert(typeof(SettingsArray) == "table", "[CameraService] 2nd parameter should be a table for :CreateNewCameraView()")
	ViewPresets[Id] = SettingsArray
	for PropertyKey: string, DefaultVal: any in pairs(PropertyDefaults) do
		if ViewPresets[Id][PropertyKey] == nil then
			warn('[CameraService] The "' .. PropertyKey .. '" property was set to the default value: ' .. tostring(DefaultVal))
			ViewPresets[Id][PropertyKey] = DefaultVal
		end
	end
end

--[=[
	Locks horizontal and/or vertical camera rotation at optional target angles in degrees.
	@param LockXAxis boolean -- Lock horizontal rotation.
	@param LockYAxis boolean -- Lock vertical rotation.
	@param LockAtX number? -- Angle in degrees to lock horizontal rotation at.
	@param LockAtY number? -- Angle in degrees to lock vertical rotation at.
]=]
function CameraService:LockCameraPanning(LockXAxis: boolean, LockYAxis: boolean, LockAtX: number?, LockAtY: number?)
	self.atX = if LockAtX then math.rad(LockAtX) else 0
	self.atY = if LockAtY then math.rad(LockAtY) else 0
	self.xLock = LockXAxis
	self.yLock = LockYAxis
end

--[=[
	Redirects camera focus to an explicit BasePart or resets to the character root when nil.
	@param NewHost BasePart? -- Target focus part, or nil to reset.
]=]
function CameraService:SetCameraHost(NewHost: BasePart?)
	assert(
		not NewHost or (typeof(NewHost) == "Instance" and NewHost:IsA("BasePart")),
		"[CameraService] :SetCameraHost() only accepts a BasePart parameter, or none at all."
	)
	State.CustomHost = NewHost
	self.Host = NewHost or CameraHelper.ResolveCharacterRoot(State.CurrentCharacter)
end

--[=[
	Updates a live camera property and optionally persists it into the active view's preset.
	@param Property string -- Property name to mutate.
	@param NewVal any -- Updated value.
	@param ChangeDefaultProperty boolean? -- True to also update the active view preset.
]=]
function CameraService:Change(Property: string, NewVal: any, ChangeDefaultProperty: boolean?)
	assert(PropertyDefaults[Property] ~= nil, '[CameraService] "' .. tostring(Property) .. '" is not a valid property to change.')
	const SelfTable = CameraService :: { [string]: any }
	SelfTable[Property] = NewVal
	if ChangeDefaultProperty then
		ViewPresets[CameraService.CameraView][Property] = NewVal
	end
end

--[=[
	Sets UserInputService.MouseDeltaSensitivity to a positive multiplier.
	@param Val number -- Sensitivity multiplier (> 0).
]=]
function CameraService:ChangeSensitivity(Val: number)
	assert(type(Val) == "number" and Val > 0, "[CameraService] Sensitivity should be greater than 0.")
	UserInputService.MouseDeltaSensitivity = Val
end

--[=[
	Tweens or immediately sets the camera vertical field of view in degrees.
	@param Val number -- Target FOV (> 0).
	@param Instant boolean? -- True to apply immediately without yielding.
]=]
function CameraService:ChangeFOV(Val: number, Instant: boolean?)
	assert(type(Val) == "number" and Val > 0, "[CameraService] FieldOfView should be greater than 0.")
	if Instant then
		CamTable.CameraFOV = Val
		return
	end

	const StartFOV = CamTable.CameraFOV :: number
	const StartTime = os.clock() :: number
	const Duration = TWEEN_INFO.Time :: number
	while os.clock() - StartTime < Duration do
		const Alpha = math.min(1, (os.clock() - StartTime) / Duration) :: number
		const Eased = TweenService:GetValue(Alpha, TWEEN_INFO.EasingStyle, TWEEN_INFO.EasingDirection) :: number
		CamTable.CameraFOV = StartFOV + (Val - StartFOV) * Eased
		task.wait()
	end
	CamTable.CameraFOV = Val
end

--[=[
	Shakes the camera at the given intensity for Duration seconds (yielding).
	@param Intensity number -- Positive shake strength.
	@param Duration number -- Positive shake duration in seconds.
]=]
function CameraService:Shake(Intensity: number, Duration: number)
	assert(Duration > 0 and Intensity > 0, "[CameraService] Inputs for :Shake() must be positive")
	self.ShakingIntensity = Intensity
	self.Shaking = true
	task.wait(Duration)
	self.Shaking = false
end

function CameraService:Tilt(Degree: number)
	self.TiltFactor = CFrame.fromEulerAnglesYXZ(0, 0, math.rad(Degree))
end

function CameraService:TiltAllAxes(X: number, Y: number, Z: number)
	self.TiltFactor = CFrame.fromEulerAnglesYXZ(if Y then math.rad(Y) else 0, if X then math.rad(X) else 0, if Z then math.rad(Z) else 0)
end

function CameraService:SetWobbling(Value: number)
	self.Wobble = Value
end

function CameraService:SetVerticalRange(Angle: number)
	self.Angle = math.clamp(math.abs(Angle), 0, 89)
end

if not State.HasSeededCharacter then
	LocalPlayer.CharacterAdded:Once(function(Char: Model)
		State.HasSeededCharacter = true
		State.CurrentCharacter = Char
		if not State.CustomHost then
			CameraService.Host = CameraHelper.ResolveCharacterRoot(Char)
			if CameraService.CameraView ~= "Default" then
				CameraHelper.HideBodyParts(
					Char,
					CameraService.AlignChar,
					if CameraService.CharacterVisibility ~= "None" then CameraService.CharacterVisibility else nil
				)
			end
		end
	end)
end

return CameraService
