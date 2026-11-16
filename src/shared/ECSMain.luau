--!strict
--!native
--!optimize 2

-- Static References --
const ECSFolder = script.Parent:WaitForChild("ECS")

-- Libraries --
const ECSTypes = require(ECSFolder:WaitForChild("ECSTypes"))
const ECSBitfield = require(ECSFolder:WaitForChild("ECSBitfield"))
const ECSComponents = require(ECSFolder:WaitForChild("ECSComponents"))
const ECSStorageFactory = require(ECSFolder:WaitForChild("ECSStorageFactory"))
const DynamicObjectsMain = require(script.Parent:WaitForChild("DynamicObjectsMain"))

-- Configs --
export type ECSTable = ECSTypes.ECSTable
export type DynamicListCounts = ECSTypes.DynamicListCounts
export type Vector3Component = ECSTypes.Vector3Component
export type VisualComponent = ECSTypes.VisualComponent
export type DirectionsComponent = ECSTypes.DirectionsComponent
export type PropertiesComponent = ECSTypes.PropertiesComponent
export type ECSDataComponent = ECSTypes.ECSDataComponent
export type DynamicObjectsComponent = ECSTypes.DynamicObjectsComponent
export type ECSStorage = ECSTypes.ECSStorage

-- Tables --
local ECSMain = {
	CreateVector3Layout = ECSBitfield.CreateVector3Layout,
	CreateVisualLayout = ECSBitfield.CreateVisualLayout,
	CreateDirectionsLayout = ECSBitfield.CreateDirectionsLayout,
	PackProperties = ECSBitfield.PackProperties,
	CreatePropertiesLayout = ECSBitfield.CreatePropertiesLayout,
	CanEntityCollide = ECSBitfield.CanEntityCollide,
	IsEntityVisible = ECSBitfield.IsEntityVisible,
	IsEntityAnchored = ECSBitfield.IsEntityAnchored,
	HasEntityDynamicId = ECSBitfield.HasEntityDynamicId,
	GetEntityShapeId = ECSBitfield.GetEntityShapeId,
	SetEntityShapeId = ECSBitfield.SetEntityShapeId,
	GetEntityDynamicId = ECSBitfield.GetEntityDynamicId,
	SetEntityDynamicId = ECSBitfield.SetEntityDynamicId,
	GetEntityTextureId = ECSBitfield.GetEntityTextureId,
	SetEntityTextureId = ECSBitfield.SetEntityTextureId,

	RegisterEntity = ECSComponents.RegisterEntity,
	SetEntityCount = ECSComponents.SetEntityCount,
	DeleteEntity = ECSComponents.DeleteEntity,
	CreateVector3Component = ECSComponents.CreateVector3Component,
	CreateVisualComponent = ECSComponents.CreateVisualComponent,
	CreateDirectionsComponent = ECSComponents.CreateDirectionsComponent,
	CreatePropertiesComponent = ECSComponents.CreatePropertiesComponent,
	CreateDynamicObjectsComponent = DynamicObjectsMain.CreateComponent,
	CreateStorage = ECSStorageFactory.CreateStorage,
}

return ECSMain
