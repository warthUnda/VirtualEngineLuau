--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const ControllerTheoryFolder =
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("ControllerTheory")

-- Libraries --
const ControllerTheory = require(ControllerTheoryFolder)

-- ============================================================================
-- 1. SERVER CONTROLLER THEORY BOOTSTRAP
-- ============================================================================

ControllerTheory.Initialize()
