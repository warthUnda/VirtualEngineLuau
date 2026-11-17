--!strict
--!native
--!optimize 2

-- Static References --
const ConfigsFolder = script.Parent:WaitForChild("Configs")

-- Libraries --
const RenderConfig = require(ConfigsFolder:WaitForChild("RenderConfig"))
const CameraConfig = require(ConfigsFolder:WaitForChild("CameraConfig"))
const ECSConfig = require(ConfigsFolder:WaitForChild("ECSConfig"))
const PhysicsConfig = require(ConfigsFolder:WaitForChild("PhysicsConfig"))
const BVHConfig = require(ConfigsFolder:WaitForChild("BVHConfig"))
const PlayerConfig = require(ConfigsFolder:WaitForChild("PlayerConfig"))

-- Configs --
export type SystemsConfigsType = {
	Render: typeof(RenderConfig),
	Camera: typeof(CameraConfig),
	ECS: typeof(ECSConfig),
	Physics: typeof(PhysicsConfig),
	BVH: typeof(BVHConfig),
	Player: typeof(PlayerConfig),
	[string]: any,
}

-- Tables --
local SystemsConfigs = {} :: SystemsConfigsType

-- Re-export domain configs as a unified table for backward-compatible lookups
for Key: string, Value: any in pairs(RenderConfig) do
	SystemsConfigs[Key] = Value
end
for Key: string, Value: any in pairs(CameraConfig) do
	SystemsConfigs[Key] = Value
end
for Key: string, Value: any in pairs(ECSConfig) do
	SystemsConfigs[Key] = Value
end
for Key: string, Value: any in pairs(PhysicsConfig) do
	SystemsConfigs[Key] = Value
end
for Key: string, Value: any in pairs(BVHConfig) do
	SystemsConfigs[Key] = Value
end
for Key: string, Value: any in pairs(PlayerConfig) do
	SystemsConfigs[Key] = Value
end

SystemsConfigs.Render = RenderConfig
SystemsConfigs.Camera = CameraConfig
SystemsConfigs.ECS = ECSConfig
SystemsConfigs.Physics = PhysicsConfig
SystemsConfigs.BVH = BVHConfig
SystemsConfigs.Player = PlayerConfig

return SystemsConfigs
