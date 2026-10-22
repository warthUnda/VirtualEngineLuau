--!native
--!optimize 2
local RunService = game:GetService("RunService")

local Workspace = game:WaitForChild("Workspace") :: Workspace
local StaticFolder = Workspace:WaitForChild("Static") :: Folder

local PartStore = require(script.Parent.PartStores) :: ModuleScript

local FreeSpots = {} :: { number }
local ActiveParts = {} :: { BasePart }

local GlobalId = 0 :: number
local FreeSpotsId = 0 :: number

local function AddPart(Child: BasePart)
	local PartSizeArray = PartStore.ReturnSizeArray() :: { Vector3 }
	local PartLookVectorArray = PartStore.ReturnLookVectorArray() :: { Vector3 }
	local PartUpVectorArray = PartStore.ReturnUpVectorArray() :: { Vector3 }
	local PartRightVectorArray = PartStore.ReturnRightVectorArray() :: { Vector3 }

	local PartPositionArray = PartStore.ReturnPositionArray() :: { Vector3 }

	local ColorArrayR = PartStore.ReturnColorArrayR() :: {}
	local ColorArrayG = PartStore.ReturnColorArrayG() :: {}
	local ColorArrayB = PartStore.ReturnColorArrayB() :: {}

	if Child:IsA("BasePart") then
		if Child:IsDescendantOf(StaticFolder) then
			GlobalId += 1
			for i, Spot: number in pairs(FreeSpots) do
				FreeSpots[i] = nil

				PartPositionArray[Spot] = Child.Position
				PartLookVectorArray[Spot] = Child.CFrame.LookVector
				PartUpVectorArray[Spot] = Child.CFrame.UpVector
				PartRightVectorArray[Spot] = Child.CFrame.RightVector
				PartSizeArray[Spot] = Child.Size

				ColorArrayR[Spot] = Child.Color.R
				ColorArrayG[Spot] = Child.Color.G
				ColorArrayB[Spot] = Child.Color.B

				Child:SetAttribute("GlobalId", Spot)

				return
			end

			PartPositionArray[GlobalId] = Child.Position

			PartLookVectorArray[GlobalId] = Child.CFrame.LookVector
			PartUpVectorArray[GlobalId] = Child.CFrame.UpVector
			PartRightVectorArray[GlobalId] = Child.CFrame.RightVector

			PartSizeArray[GlobalId] = Child.Size

			ColorArrayR[GlobalId] = Child.Color.R
			ColorArrayG[GlobalId] = Child.Color.G
			ColorArrayB[GlobalId] = Child.Color.B
		else
			ActiveParts[GlobalId] = Child

			ColorArrayR[GlobalId] = Child.Color.R
			ColorArrayG[GlobalId] = Child.Color.G
			ColorArrayB[GlobalId] = Child.Color.B

			PartSizeArray[GlobalId] = Child.Size
		end

		Child:SetAttribute("GlobalId", GlobalId)
	end
end

Workspace.DescendantAdded:Connect(AddPart)

Workspace.DescendantRemoving:Connect(function(Child: BasePart)
	local PartSizeArray = PartStore.ReturnSizeArray() :: { Vector3 }
	local PartPositionArray = PartStore.ReturnPositionArray() :: { Vector3 }

	local PartLookVectorArray = PartStore.ReturnLookVectorArray() :: { Vector3 }
	local PartUpVectorArray = PartStore.ReturnUpVectorArray() :: { Vector3 }
	local PartRightVectorArray = PartStore.ReturnRightVectorArray() :: { Vector3 }

	local ColorArrayR = PartStore.ReturnColorArrayR() :: {}
	local ColorArrayG = PartStore.ReturnColorArrayG() :: {}
	local ColorArrayB = PartStore.ReturnColorArrayB() :: {}

	if Child:IsA("BasePart") then
		local ChildId = Child:GetAttribute("GlobalId") :: number

		if Child:IsDescendantOf(StaticFolder) then
			if typeof(ChildId) == "number" then
				FreeSpotsId += 1

				PartSizeArray[ChildId] = nil

				PartPositionArray[ChildId] = nil

				PartLookVectorArray[ChildId] = nil
				PartUpVectorArray[ChildId] = nil
				PartRightVectorArray[ChildId] = nil

				ColorArrayR[ChildId] = nil
				ColorArrayG[ChildId] = nil
				ColorArrayB[ChildId] = nil

				FreeSpots[FreeSpotsId] = ChildId
			end
		else
			if typeof(ChildId) == "number" then
				table.remove(ActiveParts, ChildId)

				FreeSpots[FreeSpotsId] = ChildId
			end
		end
	end
end)

RunService.Stepped:Connect(function()
	local PartPositionArray = PartStore.ReturnPositionArray() :: { Vector3 }
	local PartLookVectorArray = PartStore.ReturnLookVectorArray() :: { Vector3 }
	local PartUpVectorArray = PartStore.ReturnUpVectorArray() :: { Vector3 }
	local PartRightVectorArray = PartStore.ReturnRightVectorArray() :: { Vector3 }

	for _, Child: BasePart in pairs(ActiveParts) do
		local ChildId = Child:GetAttribute("GlobalId") :: number

		PartPositionArray[ChildId] = Child.Position
		PartLookVectorArray[ChildId] = Child.CFrame.LookVector
		PartUpVectorArray[ChildId] = Child.CFrame.UpVector
		PartRightVectorArray[ChildId] = Child.CFrame.RightVector
	end
end)

for _, Child: BasePart in pairs(Workspace:GetDescendants()) do
	AddPart(Child)
end
