--!strict
--!native
--!optimize 2

-- Configs --
export type CameraRuntimeState = {
	CurrentCamPosition: Vector3,
	CameraRotation: Vector2,
	CurrentCharacter: Model?,
	HasSeededCharacter: boolean,
	CustomHost: BasePart?,
	ShakeOffset: Vector3,
	UpdateShake: number,
	Delta: Vector3,
	DifferenceVector: Vector2,
	WaistCache: CFrame?,
	NeckCache: CFrame?,
	Lapsed: number,
	ArrowKeyAngle: number,
	PastCamRot: CFrame,
	ConnectionList: { RBXScriptConnection },
}

-- Tables --
local ViewPresets: { [string]: { [string]: any } } = {
	["Default"] = {},
	["FirstPerson"] = {
		Wobble = 0.45,
		CharacterVisibility = "None",
		Smoothness = 1,
		RotSmoothness = 0,
		Zoom = 0,
		AlignChar = true,
		Offset = CFrame.new(0, 0, 0),
		LockMouse = true,
		MinZoom = 0,
		MaxZoom = 0,
		BodyFollow = true,
	},
	["FirstPersonVariant"] = {
		Wobble = 2,
		CharacterVisibility = "Body",
		Smoothness = 0.35,
		RotSmoothness = 0,
		Zoom = 0,
		AlignChar = true,
		Offset = CFrame.new(0, 0.2, 0.75),
		LockMouse = true,
		MinZoom = 0,
		MaxZoom = 0,
		BodyFollow = true,
	},
	["ThirdPerson"] = {
		Wobble = 0.4,
		CharacterVisibility = "All",
		Smoothness = 0.7,
		Zoom = 10,
		AlignChar = false,
		Offset = CFrame.new(0, 0, 0),
		LockMouse = false,
		MinZoom = 5,
		MaxZoom = 15,
		BodyFollow = true,
	},
	["ShiftLock"] = {
		Wobble = 0,
		CharacterVisibility = "All",
		Smoothness = 0.7,
		Zoom = 7.5,
		Offset = CFrame.new(1.75, 0.5, 1),
		LockMouse = true,
		AlignChar = true,
		MinZoom = 2,
		MaxZoom = 15,
		BodyFollow = true,
	},
	["Cinematic"] = {
		Smoothness = 5,
		CharacterVisibility = "All",
		MinZoom = 10,
		MaxZoom = 10,
		Zoom = 10,
		AlignChar = false,
		Offset = CFrame.new(),
		LockMouse = false,
		BodyFollow = false,
		Wobble = 0,
	},
}

local PropertyDefaults: { [string]: any } = {
	CharacterVisibility = "All",
	Smoothness = 0.5,
	Zoom = 10,
	RotSmoothness = 1,
	AlignChar = false,
	Offset = CFrame.new(),
	MinZoom = 5,
	MaxZoom = 15,
	LockMouse = false,
	BodyFollow = true,
	Wobble = 0,
}

local CameraPresets = {
	ViewPresets = ViewPresets,
	PropertyDefaults = PropertyDefaults,
}

-- Functions --
function CameraPresets.CreateRuntimeState(InitialCharacter: Model?): CameraRuntimeState
	return {
		CurrentCamPosition = Vector3.zero,
		CameraRotation = Vector2.zero,
		CurrentCharacter = InitialCharacter,
		HasSeededCharacter = (InitialCharacter ~= nil),
		CustomHost = nil,
		ShakeOffset = Vector3.zero,
		UpdateShake = 0,
		Delta = Vector3.zero,
		DifferenceVector = Vector2.zero,
		WaistCache = nil,
		NeckCache = nil,
		Lapsed = 1000,
		ArrowKeyAngle = 0,
		PastCamRot = CFrame.Angles(0, 0, 0),
		ConnectionList = {},
	}
end

return CameraPresets
