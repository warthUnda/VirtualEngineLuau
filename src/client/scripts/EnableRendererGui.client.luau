--!strict
--!native
--!optimize 2

--[=[
	@class EnableRendererGui.client
	Disables legacy static StarterGui placeholders on the client, ensuring the self-created
	ScreenGui and ImageLabel managed by RenderService serve as the sole active render viewport.
]=]

-- Services --
const Players = game:GetService("Players")

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
const LegacyStarterGui = PlayerGui:FindFirstChild("ScreenGui")

-- Functions --
-- ============================================================================
-- 1. DISABLE LEGACY STARTERGUI PLACEHOLDER (RENDER SERVICE CREATES ITS OWN GUI)
-- ============================================================================

if LegacyStarterGui and LegacyStarterGui:IsA("ScreenGui") then
	LegacyStarterGui.Enabled = false
end
