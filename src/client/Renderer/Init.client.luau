local Player = game:GetService("Players").LocalPlayer
local Camera = workspace:WaitForChild("Camera") :: Camera

local CameraService = require(script.Parent.Parent.CameraService)
local ParralelModule = require(script.Parent.ParralelModule)

ParralelModule.CreateSetup()

CameraService:SetCameraHost()
CameraService:SetCameraView("ThirdPerson")

Camera.CFrame = CFrame.new(50, 25555, 30)
Camera.CameraType = Enum.CameraType.Fixed
