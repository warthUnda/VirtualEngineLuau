--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const PlayerFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Player")

-- Modules --
const PlayerController = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerController"))

-- ============================================================================
-- 1. SERVER PLAYER ECS & DYNAMIC OBJECTS OOP BOOTSTRAP
-- ============================================================================

PlayerController.Initialize()
