--!strict
--!native
--!optimize 2

-- Services --
const StarterGui = game:GetService("StarterGui")

-- Modules --
const RenderBootstrap = require(script.Parent.RenderBootstrap)

-- Configs --
const CORE_GUI_TYPES = { Enum.CoreGuiType.All }

-- ============================================================================
-- 1. CORE GUI CLEANUP & CLIENT RENDER BOOTSTRAP
-- ============================================================================

-- Disable Roblox core GUI elements to reduce client memory footprint
for _, GuiType: Enum.CoreGuiType in ipairs(CORE_GUI_TYPES) do
	pcall(function()
		StarterGui:SetCoreGuiEnabled(GuiType, false)
	end)
end

RenderBootstrap.CreateSetup()
