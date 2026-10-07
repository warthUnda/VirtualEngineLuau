--!native
--!optimize 2

local Workspace = game:WaitForChild("Workspace") :: Workspace

local PartStore = require(script.Parent.PartStores) :: ModuleScript

local FreeSpots = {} :: { number }

local GlobalId = 0 :: number
local FreeSpotsId = 0 :: number

local function AddPart(Child: BasePart)
	local PartArray = PartStore.ReturnArray() :: { BasePart }

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

Workspace.DescendantRemoving:Connect(function(Child: BasePart)
	local PartArray = PartStore.ReturnArray() :: { BasePart }

	if Child:IsA("BasePart") then
		local ChildId = Child:GetAttribute("GlobalId") :: number

		if typeof(ChildId) == "number" then
			print("Removed", Child.Name, ChildId)

			FreeSpotsId += 1

			PartArray[ChildId] = nil
			FreeSpots[FreeSpotsId] = ChildId
		end
	end
end)

for _, Child: BasePart in pairs(Workspace:GetDescendants()) do
	AddPart(Child)
end
