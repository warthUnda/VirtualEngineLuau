--!strict
--!native
--!optimize 2

-- Tables --
local CameraConfig = {}

-- Configs --

-- Virtual Camera & Projection Defaults --

CameraConfig.ScriptableCameraParkPosition = Vector3.new(0, -50000, 0) :: Vector3
-- World position where the client's Workspace Camera is initially parked when switched to Scriptable.

CameraConfig.CameraFixedPosition = Vector3.new(0, 1000, -5000) :: Vector3
-- Fixed distant world position where CameraService locks the Workspace Camera every frame to avoid rendering default Roblox geometry.

CameraConfig.DefaultCameraCFrame = CFrame.new(5, 5, 5) :: CFrame
-- Initial virtual camera CFrame before the camera host updates it.

CameraConfig.DefaultCameraFOV = 70 :: number
-- Default vertical field of view in degrees for the virtual camera and projection math.

-- Camera Controller & Input Settings --

CameraConfig.DefaultCameraView = "FirstPerson" :: string
-- Initial CameraService view preset activated when the render controller starts.

CameraConfig.CameraMaxVerticalAngle = 60 :: number
-- Default maximum vertical look angle in degrees (up/down pitch clamp) in CameraService.

CameraConfig.CameraPlayerEyeOffset = 2.5 :: number
-- Vertical eye-height offset in studs above the simulated player physics body when no BasePart camera host is used.

CameraConfig.CameraMouseUnlockKey = Enum.KeyCode.LeftAlt :: Enum.KeyCode
-- Keyboard keybind (UserInputService) that toggles mouse center lock on/off for the active camera view.

return CameraConfig
