--!strict
--!native
--!optimize 2

-- Configs --
export type ECSTable = {
	OrientationECSCount: number,
	PositionECSCount: number,
	VisualECSCount: number,
	SizeECSCount: number,
	DirectionsECSCount: number,
	PropertiesECSCount: number?,
	EntityECSCount: number,
}

export type DynamicListCounts = {
	ActiveCount: number,
	NextId: number,
}

export type Vector3Component = {
	CreateLayout: (MemoryOffset: number, X: number, Y: number, Z: number) -> number,
	GetData: () -> buffer,
}

export type VisualComponent = {
	CreateLayout: (MemoryOffset: number, R: number, G: number, B: number, A: number?) -> number,
	GetData: () -> buffer,
}

export type DirectionsComponent = {
	CreateLayout: (
		MemoryOffset: number,
		LookX: number,
		LookY: number,
		LookZ: number,
		UpX: number,
		UpY: number,
		UpZ: number,
		RightX: number,
		RightY: number,
		RightZ: number
	) -> number,
	GetData: () -> buffer,
}

export type PropertiesComponent = {
	CreateLayout: (
		MemoryOffset: number,
		CanCollide: boolean?,
		IsVisible: boolean?,
		Anchored: boolean?,
		DynamicId: number?,
		TextureId: number?,
		ShapeId: number?
	) -> number,
	GetData: () -> buffer,
}

export type ECSDataComponent = {
	ECSDataTable: ECSTable,
	GetCounts: () -> ECSTable,
	GetStaticData: () -> buffer,
	GetDirtyFlags: () -> buffer,
	GetVersionBuffer: () -> buffer,
	MarkDirty: (EntityId: number) -> (),
	ClearDirty: (EntityId: number) -> (),
	SetSwapPopCallback: (Callback: ((DeletedEntityId: number, MovedFromEntityId: number) -> ())?) -> (),
	RegisterEntity: (IsStatic: boolean?) -> number,
	SetEntityCount: (EntityCount: number) -> (),
	DeleteEntity: (EntityId: number) -> (),
}

export type DynamicObjectsComponent = {
	ObjectsTable: { [number]: any },
	Counts: DynamicListCounts,
	AddObject: (ObjectInstance: any, EntityId: number?) -> number,
	SetObjectAtId: (DynamicId: number, ObjectInstance: any, EntityId: number?) -> boolean,
	GetObject: (DynamicId: number) -> any,
	GetObjectFromRegister: (Register: number) -> any,
	GetObjectByEntityId: (EntityId: number) -> any,
	BindEntity: (DynamicId: number, EntityId: number) -> (),
	GetBoundEntityId: (DynamicId: number) -> number,
	RemoveObject: (DynamicId: number) -> (),
	GetData: () -> { [number]: any },
}

export type ECSStorage = {
	PositionData: Vector3Component,
	OrientationData: Vector3Component,
	VisualData: VisualComponent,
	SizeData: Vector3Component,
	DirectionsData: DirectionsComponent,
	PropertiesData: PropertiesComponent,
	ECSData: ECSDataComponent,
	DynamicObjectsList: DynamicObjectsComponent,
}

-- Tables --
local ECSTypes = {}

return ECSTypes
