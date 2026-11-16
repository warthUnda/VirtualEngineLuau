--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const PlayerFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Player")

-- Libraries --
const PlayerController = require(PlayerFolder:WaitForChild("Controller"):WaitForChild("PlayerController"))

-- Functions --
-- ============================================================================
-- 1. SERVER PLAYER ECS & DYNAMIC OBJECTS OOP BOOTSTRAP
-- ============================================================================

PlayerController.Initialize()
