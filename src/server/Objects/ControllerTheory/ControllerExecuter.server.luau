--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const ControllerTheoryFolder =
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("ControllerTheory")

-- Libraries --
const ResourceController =
	require(ControllerTheoryFolder:WaitForChild("Controller"):WaitForChild("ResourceController"))

-- ============================================================================
-- 1. SERVER RESOURCE CONTROLLER BOOTSTRAP
-- ============================================================================

ResourceController.Initialize()
