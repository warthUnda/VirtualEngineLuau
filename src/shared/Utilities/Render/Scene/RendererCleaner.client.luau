--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const LocalPlayer = Players.LocalPlayer :: Player
const SelfActor = script:GetActor() :: Actor?
const ECSFolder = (SelfActor and SelfActor:WaitForChild("ObjectStorage"))
	or LocalPlayer:WaitForChild("PlayerScripts")
		:WaitForChild("Client")
		:WaitForChild("Objects")
		:WaitForChild("ObjectStorage") :: Folder

-- Modules --
const ECSData = require(ECSFolder:WaitForChild("ECSData")) :: ModuleScript
const PositionData = require(ECSFolder:WaitForChild("PositionData")) :: ModuleScript
const SizeData = require(ECSFolder:WaitForChild("SizeData")) :: ModuleScript
const ViewCulling = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Core")
		:WaitForChild("ViewCulling")
) :: ModuleScript

-- Buffers
const Positions = PositionData.GetData() :: buffer
const Sizes = SizeData.GetData() :: buffer
const Counts = ECSData.ECSDataTable

-- ============================================================================
-- 1. CLEANER LOOP - FRUSTUM & OCCLUSION CULLING
-- ============================================================================

while true do
	const Head = ViewCulling.GetObserverHead(LocalPlayer) :: BasePart?
	const EntityCount = Counts.EntityECSCount :: number

	if Head and EntityCount > 0 then
		ViewCulling.UpdateDynamicView(Head)

		for i = EntityCount, 1, -1 do
			if ViewCulling.IsEntityCulled(i, Positions, Sizes) then
				ECSData.DeleteEntity(i)
			end
		end
	end

	task.wait()
end
