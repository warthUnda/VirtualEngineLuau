local PartStore = {}

local PartSizeArray = {}

local LookVectorArray = {}
local UpVectorArray = {}
local RightVectorArray = {}

local PartPositionArray = {}

local ColorArrayR = {}
local ColorArrayG = {}
local ColorArrayB = {}

function PartStore.ReturnColorArrayR()
	return ColorArrayR
end

function PartStore.ReturnColorArrayG()
	return ColorArrayG
end

function PartStore.ReturnColorArrayB()
	return ColorArrayB
end

function PartStore.ReturnSizeArray()
	return PartSizeArray
end

function PartStore.ReturnPositionArray()
	return PartPositionArray
end

function PartStore.ReturnLookVectorArray()
	return LookVectorArray
end

function PartStore.ReturnUpVectorArray()
	return UpVectorArray
end

function PartStore.ReturnRightVectorArray()
	return RightVectorArray
end

return PartStore
