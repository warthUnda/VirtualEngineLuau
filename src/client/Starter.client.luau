--!strict
--!native
--!optimize 2

-- Modules --

-- exploit to disable roblox gui core services to save up to 200mbs of ram
local StarterGui = game:GetService("StarterGui")
local coreTypes = { Enum.CoreGuiType.All }
for _, guiType in ipairs(coreTypes) do
	pcall(function()
		StarterGui:SetCoreGuiEnabled(guiType, false)
	end)
end

const RenderBootstrap = require(script.Parent.RenderBootstrap)

RenderBootstrap.CreateSetup()
