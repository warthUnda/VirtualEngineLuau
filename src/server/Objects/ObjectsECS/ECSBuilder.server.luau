--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Static References --
const Workspace = workspace :: Workspace
const StaticFolder = Workspace:WaitForChild("Static")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSBuilderHelper = require(script.Parent.ECSBuilderHelper)

-- Configs --
const WORKSPACE_CLEANUP_DELAY = SystemsConfigs.WorkspaceCleanupDelay :: number

-- ============================================================================
-- 1. WORKSPACE SEED & LISTENER
-- ============================================================================

-- Discover all Decals in the workspace first so TextureTable is populated before assigning part TextureIds.
ECSBuilderHelper.ScanWorkspaceDecals(Workspace)

-- Seed the ECS with everything already present in the workspace.
for _, Descendant: Instance in ipairs(Workspace:GetDescendants()) do
	if Descendant:IsA("BasePart") then
		ECSBuilderHelper.PopulatePart(Descendant)
	end
end

-- Keep the ECS and TextureTable populated as decals and parts are added at runtime.
Workspace.DescendantAdded:Connect(function(Descendant: Instance)
	if Descendant:IsA("Decal") then
		ECSBuilderHelper.RegisterDecal(Descendant)
	elseif Descendant:IsA("BasePart") then
		ECSBuilderHelper.PopulatePart(Descendant)
	end
end)

task.wait(WORKSPACE_CLEANUP_DELAY) -- shall be used for later
for _, Descendant: Instance in ipairs(StaticFolder:GetDescendants()) do
	Descendant:Destroy()
end
