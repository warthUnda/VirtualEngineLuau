--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const StarterGui = game:GetService("StarterGui")

-- Modules --
const RenderBootstrap = require(script.Parent.RenderBootstrap)

-- Configs --
const CORE_GUI_TYPES = { Enum.CoreGuiType.All }
const DEFAULT_PLAYER_SCRIPTS = { "PlayerScriptsLoader", "RbxCharacterSounds", "PlayerModule" }
const DEFAULT_CHARACTER_SCRIPTS = { "Animate", "Health", "Sound" }

-- ============================================================================
-- 1. CORE GUI, DEFAULT SCRIPT CLEANUP & CLIENT RENDER BOOTSTRAP
-- ============================================================================

-- Disable Roblox core GUI elements to reduce client memory footprint
for _, GuiType: Enum.CoreGuiType in ipairs(CORE_GUI_TYPES) do
	pcall(function()
		StarterGui:SetCoreGuiEnabled(GuiType, false)
	end)
end

-- Remove any built-in Roblox player/character scripts if present
const LocalPlayer = Players.LocalPlayer :: Player?
if LocalPlayer then
	const PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
	if PlayerScripts then
		for _, ScriptName: string in ipairs(DEFAULT_PLAYER_SCRIPTS) do
			const Target = PlayerScripts:FindFirstChild(ScriptName)
			if Target then
				Target:Destroy()
			end
		end
	end

	const Character = LocalPlayer.Character
	if Character then
		for _, ScriptName: string in ipairs(DEFAULT_CHARACTER_SCRIPTS) do
			const Target = Character:FindFirstChild(ScriptName)
			if Target then
				Target:Destroy()
			end
		end
	end
end

RenderBootstrap.CreateSetup()
