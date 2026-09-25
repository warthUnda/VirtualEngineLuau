local Workspace = game:WaitForChild("Workspace")

local PartStore = require(game.StarterPlayer.StarterPlayerScripts.Client.Renderer.Stores.PartStores)

local FreeSpots = {}

local GlobalId = 0
local FreeSpotsId = 0

local function AddPart(Child)
	local PartArray = PartStore.ReturnArray()

	if Child:IsA("BasePart") then
		for i, Spot: number in pairs(FreeSpots) do
			FreeSpots[i] = nil

			PartArray[Spot] = Child

			Child:SetAttribute("GlobalId", Spot)

			print("Added", Child.Name, Spot)

			return
		end

		GlobalId += 1

		PartArray[GlobalId] = Child

		Child:SetAttribute("GlobalId", GlobalId)

		print("Added", Child.Name, GlobalId)
	end
end

Workspace.DescendantAdded:Connect(AddPart)

Workspace.DescendantRemoving:Connect(function(Child)
	local PartArray = PartStore.ReturnArray()

	if Child:IsA("BasePart") then
		local ChildId = Child:GetAttribute("GlobalId")

		if typeof(ChildId) == "number" then
			print("Removed", Child.Name, ChildId)

			FreeSpotsId += 1

			PartArray[ChildId] = nil
			FreeSpots[FreeSpotsId] = ChildId
		end
	end
end)

for _, Child in pairs(Workspace:GetDescendants()) do
	AddPart(Child)
end
