--!native
--!optimize 2

local RunService = game:GetService("RunService")

local Workspace = workspace :: Workspace
local StaticFolder = Workspace:WaitForChild("Static") :: Folder

local PartStore = require(script.Parent.PartStore) :: ModuleScript

local ActiveParts = {} :: { BasePart } -- dynamic (non-static) parts updated each frame
local NextId = 0 :: number

local function WritePart(Id: number, Part: BasePart)
	local PositionArray = PartStore.GetPositionArray()
	local InstanceArray = PartStore.GetInstanceArray()
	local LookArray = PartStore.GetLookVectorArray()
	local UpArray = PartStore.GetUpVectorArray()
	local RightArray = PartStore.GetRightVectorArray()
	local SizeArray = PartStore.GetSizeArray()
	local ColorArrayR = PartStore.GetColorArrayR()
	local ColorArrayG = PartStore.GetColorArrayG()
	local ColorArrayB = PartStore.GetColorArrayB()

	PositionArray[Id] = Part.Position
	InstanceArray[Id] = Part
	LookArray[Id] = Part.CFrame.LookVector
	UpArray[Id] = Part.CFrame.UpVector
	RightArray[Id] = Part.CFrame.RightVector
	SizeArray[Id] = Part.Size
	ColorArrayR[Id] = Part.Color.R
	ColorArrayG[Id] = Part.Color.G
	ColorArrayB[Id] = Part.Color.B
end

local function ClearPart(Id: number)
	local PositionArray = PartStore.GetPositionArray()
	local InstanceArray = PartStore.GetInstanceArray()
	local LookArray = PartStore.GetLookVectorArray()
	local UpArray = PartStore.GetUpVectorArray()
	local RightArray = PartStore.GetRightVectorArray()
	local SizeArray = PartStore.GetSizeArray()
	local ColorArrayR = PartStore.GetColorArrayR()
	local ColorArrayG = PartStore.GetColorArrayG()
	local ColorArrayB = PartStore.GetColorArrayB()

	PositionArray[Id] = nil
	InstanceArray[Id] = nil
	LookArray[Id] = nil
	UpArray[Id] = nil
	RightArray[Id] = nil
	SizeArray[Id] = nil
	ColorArrayR[Id] = nil
	ColorArrayG[Id] = nil
	ColorArrayB[Id] = nil
end

local function AddPart(Child: BasePart)
	if not Child:IsA("BasePart") then
		return
	end

	NextId += 1
	local Id = NextId

	WritePart(Id, Child)
	Child:SetAttribute("GlobalId", Id)

	if not Child:IsDescendantOf(StaticFolder) then
		table.insert(ActiveParts, Child)
	end
end

Workspace.DescendantAdded:Connect(AddPart)

Workspace.DescendantRemoving:Connect(function(Child: BasePart)
	if not Child:IsA("BasePart") then
		return
	end

	local Id = Child:GetAttribute("GlobalId")
	if typeof(Id) ~= "number" then
		return
	end

	-- Swap-remove keeps the arrays dense so `#PartPositionArray` stays valid.
	if Id ~= NextId then
		local LastInstance = PartStore.GetInstanceArray()[NextId]
		if LastInstance then
			WritePart(Id, LastInstance)
			LastInstance:SetAttribute("GlobalId", Id)
		end
	end
	ClearPart(NextId)
	NextId -= 1

	local ActiveIndex = table.find(ActiveParts, Child)
	if ActiveIndex then
		table.remove(ActiveParts, ActiveIndex)
	end
end)

RunService.Stepped:Connect(function()
	local PositionArray = PartStore.GetPositionArray()
	local LookArray = PartStore.GetLookVectorArray()
	local UpArray = PartStore.GetUpVectorArray()
	local RightArray = PartStore.GetRightVectorArray()

	for _, Child: BasePart in ipairs(ActiveParts) do
		local Id = Child:GetAttribute("GlobalId")
		if typeof(Id) == "number" then
			PositionArray[Id] = Child.Position
			LookArray[Id] = Child.CFrame.LookVector
			UpArray[Id] = Child.CFrame.UpVector
			RightArray[Id] = Child.CFrame.RightVector
		end
	end
end)

for _, Child: BasePart in ipairs(Workspace:GetDescendants()) do
	AddPart(Child)
end
