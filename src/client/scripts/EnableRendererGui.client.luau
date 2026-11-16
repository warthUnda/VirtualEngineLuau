--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
const RendererScreenGui = PlayerGui:WaitForChild("ScreenGui") :: ScreenGui

-- ============================================================================
-- 1. ENABLE RENDERER SCREENGUI
-- ============================================================================

RendererScreenGui.Enabled = true
