local PartStore = {}

local PartSizeArray = {}

local LookVectorArray = {}
local UpVectorArray = {}
local RightVectorArray = {}

local PartPositionArray = {}
local PartInstanceArray = {}

local ColorArrayR = {}
local ColorArrayG = {}
local ColorArrayB = {}

function PartStore.GetColorArrayR()
	return ColorArrayR
end

function PartStore.GetColorArrayG()
	return ColorArrayG
end

function PartStore.GetColorArrayB()
	return ColorArrayB
end

function PartStore.GetSizeArray()
	return PartSizeArray
end

function PartStore.GetPositionArray()
	return PartPositionArray
end

function PartStore.GetInstanceArray()
	return PartInstanceArray
end

function PartStore.GetLookVectorArray()
	return LookVectorArray
end

function PartStore.GetUpVectorArray()
	return UpVectorArray
end

function PartStore.GetRightVectorArray()
	return RightVectorArray
end

return PartStore
