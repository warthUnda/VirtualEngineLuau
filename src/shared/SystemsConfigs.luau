--!strict
--!native
--!optimize 2

-- Domain Config Modules --
const ConfigsFolder = script.Parent:WaitForChild("Configs")
const RenderConfig = require(ConfigsFolder:WaitForChild("RenderConfig"))
const ECSConfig = require(ConfigsFolder:WaitForChild("ECSConfig"))
const PhysicsConfig = require(ConfigsFolder:WaitForChild("PhysicsConfig"))
const BVHConfig = require(ConfigsFolder:WaitForChild("BVHConfig"))

local SystemsConfigs = {} :: { [string]: any }

-- Re-export domain configs as a unified table for backward-compatible lookups
for Key: string, Value: any in pairs(RenderConfig) do
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

SystemsConfigs.Render = RenderConfig
SystemsConfigs.ECS = ECSConfig
SystemsConfigs.Physics = PhysicsConfig
SystemsConfigs.BVH = BVHConfig

return SystemsConfigs
