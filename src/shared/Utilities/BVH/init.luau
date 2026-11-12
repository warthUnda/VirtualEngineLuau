--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))
const BVHHelper = require(script.BVHHelper)
const BVHMath = require(script.BVHMath)

-- Configs --
const COMPONENT_STRIDE = SystemsConfigs.ECSComponentStride :: number
const DIRECTION_STRIDE = SystemsConfigs.ECSDirectionStride :: number
const PROPERTIES_STRIDE = SystemsConfigs.ECSPropertiesStride :: number
const MAX_ENTITIES = SystemsConfigs.ECSMaxEntities :: number
const STACK_CAPACITY = SystemsConfigs.BVHStackCapacity :: number

const NODE_STRIDE = 32 :: number
const ITEM_BOUNDS_STRIDE = 36 :: number
const CACHED_STATE_STRIDE = 28 :: number
const MAX_BVH_NODES = MAX_ENTITIES * 2 :: number
const MAX_NODE_BYTES = MAX_BVH_NODES * NODE_STRIDE :: number

const FLAG_CAN_COLLIDE = bit32.lshift(1, 1) :: number
const FLAG_ANCHORED = bit32.lshift(1, 3) :: number
const FLAG_HAS_DYNAMIC_ID = bit32.lshift(1, 4) :: number
const DYNAMIC_ID_SHIFT = 20 :: number

-- Buffers
const NodeBuffer = buffer.create(MAX_NODE_BYTES) :: buffer
const ItemBoundsBuffer = buffer.create(MAX_ENTITIES * ITEM_BOUNDS_STRIDE) :: buffer
const CachedStateBuffer = buffer.create(MAX_ENTITIES * CACHED_STATE_STRIDE) :: buffer
const ItemIndicesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const DynamicEntitiesBuffer = buffer.create(MAX_ENTITIES * 4) :: buffer
const EntityIsDynamicBuffer = buffer.create(MAX_ENTITIES + 1) :: buffer
const TestedGenBuffer = buffer.create((MAX_ENTITIES + 1) * 4) :: buffer
const TraversalStackBuffer = buffer.create(STACK_CAPACITY * 4) :: buffer

-- Tables --
local ActiveStorage: ECSMain.ECSStorage? = nil

local AllocatedNodeBytes = 0 :: number
local DynamicEntityCount = 0 :: number
local LastBuiltEntityCount = -1 :: number
local LastDynamicNextId = -1 :: number
local LastDynamicActiveCount = -1 :: number
local MutationScanCursor = 1 :: number
local RayGeneration = 0 :: number

local BVH = {}

-- ============================================================================
-- 1. FLAT-BUFFER TREE BUILDER
-- ============================================================================

--[=[
	Rebuilds the static and dynamic BVH hierarchy over the given ECS storage.
	@param ProvidedStorage ECSMain.ECSStorage? -- Target ECS storage; if nil, resolves default.
]=]
function BVH.Rebuild(ProvidedStorage: ECSMain.ECSStorage?)
	const Storage = BVHHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return
	end

	const RawCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const EntityCount = math.clamp(RawCount, 0, MAX_ENTITIES) :: number
	ActiveStorage = Storage
	LastBuiltEntityCount = EntityCount
	AllocatedNodeBytes = 0
	DynamicEntityCount = 0
	MutationScanCursor = 1

	const DynList = Storage.DynamicObjectsList
	if DynList then
		LastDynamicActiveCount = DynList.Counts.ActiveCount
		LastDynamicNextId = DynList.Counts.NextId
	else
		LastDynamicActiveCount = 0
		LastDynamicNextId = 0
	end

	if EntityCount <= 0 then
		return
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const StaticBuffer = Storage.ECSData.GetStaticData() :: buffer?

	local StaticItemCount = 0 :: number

	for EntityId = 1, EntityCount do
		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
		const StateOffset = (EntityId - 1) * CACHED_STATE_STRIDE :: number

		const PropRegister = buffer.readu32(PropertiesBuffer, PropOffset) :: number
		const RawSizeX = buffer.readf32(SizeBuffer, CompOffset) :: number
		const RawSizeY = buffer.readf32(SizeBuffer, CompOffset + 4) :: number
		const RawSizeZ = buffer.readf32(SizeBuffer, CompOffset + 8) :: number

		buffer.writef32(CachedStateBuffer, StateOffset, RawSizeX)
		buffer.writef32(CachedStateBuffer, StateOffset + 4, RawSizeY)
		buffer.writef32(CachedStateBuffer, StateOffset + 8, RawSizeZ)
		buffer.writef32(CachedStateBuffer, StateOffset + 12, buffer.readf32(DirectionsBuffer, DirOffset))
		buffer.writef32(CachedStateBuffer, StateOffset + 16, buffer.readf32(DirectionsBuffer, DirOffset + 16))
		buffer.writef32(CachedStateBuffer, StateOffset + 20, buffer.readf32(DirectionsBuffer, DirOffset + 32))
		buffer.writeu32(CachedStateBuffer, StateOffset + 24, PropRegister)

		if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 1)
			continue
		end

		const HasDynamicObject = bit32.btest(PropRegister, FLAG_HAS_DYNAMIC_ID) :: boolean
		const IsDynamic = (
			HasDynamicObject
			or (StaticBuffer ~= nil and buffer.readu8(StaticBuffer, EntityId - 1) == 0)
			or (PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_ANCHORED))
		) :: boolean

		if IsDynamic then
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 1)
			buffer.writeu32(DynamicEntitiesBuffer, DynamicEntityCount * 4, EntityId)
			DynamicEntityCount += 1
		else
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 0)
		end

		const PositionX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PositionY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PositionZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

		const HalfSizeX = math.abs(RawSizeX) * 0.5 :: number
		const HalfSizeY = math.abs(RawSizeY) * 0.5 :: number
		const HalfSizeZ = math.abs(RawSizeZ) * 0.5 :: number

		local LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
		local LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
		local LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number

		local UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
		local UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
		local UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number

		local RightX = buffer.readf32(DirectionsBuffer, DirOffset + 24) :: number
		local RightY = buffer.readf32(DirectionsBuffer, DirOffset + 28) :: number
		local RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 32) :: number

		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ = 0, 0, -1
			UpX, UpY, UpZ = 0, 1, 0
			RightX, RightY, RightZ = 1, 0, 0
		end

		const WorldExtentX =
			math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ :: number
		const WorldExtentY =
			math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ :: number
		const WorldExtentZ =
			math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ :: number

		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number
		buffer.writef32(ItemBoundsBuffer, BoundsOffset, PositionX - WorldExtentX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 4, PositionY - WorldExtentY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 8, PositionZ - WorldExtentZ)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 12, PositionX + WorldExtentX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 16, PositionY + WorldExtentY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 20, PositionZ + WorldExtentZ)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 24, PositionX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 28, PositionY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 32, PositionZ)

		if not IsDynamic then
			StaticItemCount += 1
			buffer.writeu32(ItemIndicesBuffer, (StaticItemCount - 1) * 4, EntityId)
		end
	end

	if StaticItemCount > 0 then
		const _, NextAllocatedNodeBytes = BVHHelper.BuildSubtree(
			NodeBuffer,
			ItemBoundsBuffer,
			ItemIndicesBuffer,
			0,
			1,
			StaticItemCount,
			0
		)
		AllocatedNodeBytes = NextAllocatedNodeBytes
	end
end

-- ============================================================================
-- 2. UNIFIED 1-CALL RAYCAST (STATIC BVH + LIVE DYNAMIC OOP OBJECTS)
-- ============================================================================

--[=[
	Casts a ray through the BVH hierarchy returning the closest hit entity and OOP object.
	Accepts both (Origin, Direction, MaxDistance, IgnoreFilter, Storage) and (Storage, Origin, Direction, ...) calling styles.
	@param Arg1 any -- Ray origin (Vector3) or ECSStorage.
	@param Arg2 any -- Ray direction (Vector3) or Ray origin (Vector3).
	@param Arg3 any? -- MaxDistance (number), ECSStorage, or IgnoreFilter.
	@param Arg4 any? -- IgnoreFilter, MaxDistance (number), or ECSStorage.
	@param Arg5 any? -- ECSStorage or IgnoreFilter.
	@return number? -- Hit ECS entity ID (or nil).
	@return any? -- Hit dynamic OOP object (or nil).
	@return number -- Hit distance along ray.
	@return Vector3? -- Hit world position.
	@return Vector3? -- Hit surface outward normal.
]=]
function BVH.Raycast(
	Arg1: any,
	Arg2: any,
	Arg3: any?,
	Arg4: any?,
	Arg5: any?
): (number?, any?, number, Vector3?, Vector3?)
	local Origin: Vector3? = nil
	local DirectionVector: Vector3? = nil
	local MaxDistanceArg: number? = nil
	local IgnoreFilter: any = nil
	local ProvidedStorage: ECSMain.ECSStorage? = nil

	if typeof(Arg1) == "Vector3" then
		Origin = Arg1
		DirectionVector = if typeof(Arg2) == "Vector3" then Arg2 else nil
		if type(Arg3) == "number" then
			MaxDistanceArg = Arg3
			if BVHHelper.IsECSStorage(Arg4) then
				ProvidedStorage = Arg4
				IgnoreFilter = Arg5
			else
				IgnoreFilter = Arg4
				ProvidedStorage = if BVHHelper.IsECSStorage(Arg5) then Arg5 else nil
			end
		elseif BVHHelper.IsECSStorage(Arg3) then
			ProvidedStorage = Arg3
			if type(Arg4) == "number" then
				MaxDistanceArg = Arg4
				IgnoreFilter = Arg5
			else
				IgnoreFilter = Arg4
			end
		else
			IgnoreFilter = Arg3
			ProvidedStorage = if BVHHelper.IsECSStorage(Arg4)
				then Arg4
				elseif BVHHelper.IsECSStorage(Arg5) then Arg5
				else nil
		end
	elseif BVHHelper.IsECSStorage(Arg1) then
		ProvidedStorage = Arg1
		Origin = if typeof(Arg2) == "Vector3" then Arg2 else nil
		DirectionVector = if typeof(Arg3) == "Vector3" then Arg3 else nil
		if type(Arg4) == "number" then
			MaxDistanceArg = Arg4
			IgnoreFilter = Arg5
		else
			IgnoreFilter = Arg4
		end
	end

	if not Origin or not DirectionVector then
		return nil, nil, 0, nil, nil
	end

	const OriginX: number, OriginY: number, OriginZ: number = Origin.X, Origin.Y, Origin.Z
	if
		OriginX ~= OriginX
		or OriginY ~= OriginY
		or OriginZ ~= OriginZ
		or math.abs(OriginX) == math.huge
		or math.abs(OriginY) == math.huge
		or math.abs(OriginZ) == math.huge
	then
		return nil, nil, 0, nil, nil
	end

	const DirectionLength = DirectionVector.Magnitude :: number
	if not (DirectionLength > 1e-8 and DirectionLength < math.huge) then
		return nil, nil, 0, nil, nil
	end

	if MaxDistanceArg ~= nil and not (MaxDistanceArg > 0) then
		return nil, nil, 0, nil, nil
	end

	const InverseDirectionLength = 1 / DirectionLength :: number
	const DirectionX = DirectionVector.X * InverseDirectionLength :: number
	const DirectionY = DirectionVector.Y * InverseDirectionLength :: number
	const DirectionZ = DirectionVector.Z * InverseDirectionLength :: number
	const MaxDistance = if MaxDistanceArg then math.min(MaxDistanceArg, 1e15) else DirectionLength :: number

	const Storage = BVHHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil, nil, MaxDistance, nil, nil
	end

	const RawEntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const EntityCount = math.clamp(RawEntityCount, 0, MAX_ENTITIES) :: number
	local ShouldRebuild: boolean
	ShouldRebuild, MutationScanCursor = BVHHelper.NeedsRebuild(
		Storage,
		ActiveStorage,
		EntityCount,
		LastBuiltEntityCount,
		LastDynamicActiveCount,
		LastDynamicNextId,
		MutationScanCursor,
		CachedStateBuffer,
		EntityIsDynamicBuffer,
		ItemBoundsBuffer
	)
	if ShouldRebuild then
		BVH.Rebuild(Storage)
	end

	const InverseDirectionX = if math.abs(DirectionX) > 1e-8
		then 1 / DirectionX
		else (if DirectionX >= 0 then 1e30 else -1e30) :: number
	const InverseDirectionY = if math.abs(DirectionY) > 1e-8
		then 1 / DirectionY
		else (if DirectionY >= 0 then 1e30 else -1e30) :: number
	const InverseDirectionZ = if math.abs(DirectionZ) > 1e-8
		then 1 / DirectionZ
		else (if DirectionZ >= 0 then 1e30 else -1e30) :: number

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const DynamicObjectsList = Storage.DynamicObjectsList

	RayGeneration += 1
	const CurrentRayGen = RayGeneration :: number
	const IgnoredId = if type(IgnoreFilter) == "number" then IgnoreFilter else 0 :: number
	const HasComplexIgnore = (IgnoreFilter ~= nil and type(IgnoreFilter) ~= "number") :: boolean

	local ClosestDistance = MaxDistance :: number
	local HitEntityId = 0 :: number
	local HitDynamicObject: any = nil
	local BestNormalX: number, BestNormalY: number, BestNormalZ: number = 0, 1, 0

	-- 1. Traverse Flat-Buffer Static BVH (Near-First Child Ordering)
	if AllocatedNodeBytes > 0 then
		const RootHit, _ = BVHMath.TestNodeAABB(
			NodeBuffer,
			0,
			OriginX,
			OriginY,
			OriginZ,
			InverseDirectionX,
			InverseDirectionY,
			InverseDirectionZ,
			ClosestDistance
		)
		if RootHit then
			local StackTop = 1 :: number
			buffer.writeu32(TraversalStackBuffer, 0, 0)

			while StackTop > 0 do
				StackTop -= 1
				const NodeOffset = buffer.readu32(TraversalStackBuffer, StackTop * 4) :: number
				const RightOffset = buffer.readu32(NodeBuffer, NodeOffset + 28) :: number

				if RightOffset == 0 then
					const EntityId = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
					if EntityId == IgnoredId or EntityId < 1 or EntityId > EntityCount then
						continue
					end

					if HasComplexIgnore then
						const EntityObj = if DynamicObjectsList
							then DynamicObjectsList.GetObjectByEntityId(EntityId)
							else nil
						if BVHHelper.IsIgnored(EntityId, EntityObj, IgnoredId, IgnoreFilter) then
							continue
						end
					end

					buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)

					const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
						EntityId,
						OriginX,
						OriginY,
						OriginZ,
						DirectionX,
						DirectionY,
						DirectionZ,
						ClosestDistance,
						PositionBuffer,
						SizeBuffer,
						DirectionsBuffer,
						PropertiesBuffer
					)
					if Hit then
						ClosestDistance = HitDistance
						HitEntityId = EntityId
						HitDynamicObject = nil
						BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
					end
				else
					const LeftOffset = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
					const HitLeft, DistanceLeft = BVHMath.TestNodeAABB(
						NodeBuffer,
						LeftOffset,
						OriginX,
						OriginY,
						OriginZ,
						InverseDirectionX,
						InverseDirectionY,
						InverseDirectionZ,
						ClosestDistance
					)
					const HitRight, DistanceRight = BVHMath.TestNodeAABB(
						NodeBuffer,
						RightOffset,
						OriginX,
						OriginY,
						OriginZ,
						InverseDirectionX,
						InverseDirectionY,
						InverseDirectionZ,
						ClosestDistance
					)

					if HitLeft and HitRight then
						if StackTop + 2 <= STACK_CAPACITY then
							if DistanceLeft < DistanceRight then
								buffer.writeu32(TraversalStackBuffer, StackTop * 4, RightOffset)
								buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, LeftOffset)
							else
								buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
								buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, RightOffset)
							end
							StackTop += 2
						end
					elseif HitLeft and StackTop < STACK_CAPACITY then
						buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
						StackTop += 1
					elseif HitRight and StackTop < STACK_CAPACITY then
						buffer.writeu32(TraversalStackBuffer, StackTop * 4, RightOffset)
						StackTop += 1
					end
				end
			end
		end
	end

	-- 2. Live Pass for Dynamic Entities
	for i = 0, DynamicEntityCount - 1 do
		const EntityId = buffer.readu32(DynamicEntitiesBuffer, i * 4) :: number
		if EntityId == IgnoredId or EntityId < 1 or EntityId > EntityCount then
			continue
		end
		if buffer.readu32(TestedGenBuffer, EntityId * 4) == CurrentRayGen then
			continue
		end

		if HasComplexIgnore then
			const EntityObj = if DynamicObjectsList then DynamicObjectsList.GetObjectByEntityId(EntityId) else nil
			if BVHHelper.IsIgnored(EntityId, EntityObj, IgnoredId, IgnoreFilter) then
				continue
			end
		end

		buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)

		const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
			EntityId,
			OriginX,
			OriginY,
			OriginZ,
			DirectionX,
			DirectionY,
			DirectionZ,
			ClosestDistance,
			PositionBuffer,
			SizeBuffer,
			DirectionsBuffer,
			PropertiesBuffer
		)
		if Hit then
			ClosestDistance = HitDistance
			HitEntityId = EntityId
			HitDynamicObject = nil
			BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
		end
	end

	-- 3. Live Pass for Registered Dynamic OOP Objects (Bound or Standalone)
	if DynamicObjectsList and DynamicObjectsList.Counts.ActiveCount > 0 then
		const ObjectsTable = DynamicObjectsList.ObjectsTable
		const MaxDynId = DynamicObjectsList.Counts.NextId :: number

		for DynId = 1, MaxDynId do
			const DynObject = ObjectsTable[DynId]
			if DynObject == nil then
				continue
			end

			const BoundEntityId = DynamicObjectsList.GetBoundEntityId(DynId) :: number
			if BoundEntityId > 0 and BoundEntityId <= EntityCount then
				if BoundEntityId == IgnoredId or buffer.readu32(TestedGenBuffer, BoundEntityId * 4) == CurrentRayGen then
					continue
				end
				if HasComplexIgnore and BVHHelper.IsIgnored(BoundEntityId, DynObject, IgnoredId, IgnoreFilter) then
					continue
				end

				buffer.writeu32(TestedGenBuffer, BoundEntityId * 4, CurrentRayGen)

				const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestEntityOBB(
					BoundEntityId,
					OriginX,
					OriginY,
					OriginZ,
					DirectionX,
					DirectionY,
					DirectionZ,
					ClosestDistance,
					PositionBuffer,
					SizeBuffer,
					DirectionsBuffer,
					PropertiesBuffer
				)
				if Hit then
					ClosestDistance = HitDistance
					HitEntityId = BoundEntityId
					HitDynamicObject = DynObject
					BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
				end
			elseif type(DynObject) == "table" or typeof(DynObject) == "Instance" then
				const ObjEntityId = if type(DynObject) == "table" and type((DynObject :: any).EntityId) == "number"
					then (DynObject :: any).EntityId :: number
					else 0
				if BVHHelper.IsIgnored(ObjEntityId, DynObject, IgnoredId, IgnoreFilter) then
					continue
				end
				if type(DynObject) == "table" and (DynObject :: any).CanCollide == false then
					continue
				end

				const ObjCFrame: CFrame? = (DynObject :: any).CFrame
				const ObjPos: Vector3? = if typeof(ObjCFrame) == "CFrame"
					then ObjCFrame.Position
					else (DynObject :: any).Position
				const ObjSize: Vector3? = (DynObject :: any).Size

				if typeof(ObjPos) == "Vector3" and typeof(ObjSize) == "Vector3" then
					const HalfSizeX = math.abs(ObjSize.X) * 0.5 :: number
					const HalfSizeY = math.abs(ObjSize.Y) * 0.5 :: number
					const HalfSizeZ = math.abs(ObjSize.Z) * 0.5 :: number

					local RightX: number, RightY: number, RightZ: number = 1, 0, 0
					local UpX: number, UpY: number, UpZ: number = 0, 1, 0
					local LookX: number, LookY: number, LookZ: number = 0, 0, -1

					if typeof(ObjCFrame) == "CFrame" then
						const Right = ObjCFrame.RightVector
						const Up = ObjCFrame.UpVector
						const Look = ObjCFrame.LookVector
						RightX, RightY, RightZ = Right.X, Right.Y, Right.Z
						UpX, UpY, UpZ = Up.X, Up.Y, Up.Z
						LookX, LookY, LookZ = Look.X, Look.Y, Look.Z
					end

					const Hit, HitDistance, NormalX, NormalY, NormalZ = BVHMath.TestBoxOBB(
						OriginX,
						OriginY,
						OriginZ,
						DirectionX,
						DirectionY,
						DirectionZ,
						ObjPos.X,
						ObjPos.Y,
						ObjPos.Z,
						HalfSizeX,
						HalfSizeY,
						HalfSizeZ,
						RightX,
						RightY,
						RightZ,
						UpX,
						UpY,
						UpZ,
						LookX,
						LookY,
						LookZ,
						ClosestDistance
					)
					if Hit then
						ClosestDistance = HitDistance
						HitEntityId = ObjEntityId
						HitDynamicObject = DynObject
						BestNormalX, BestNormalY, BestNormalZ = NormalX, NormalY, NormalZ
					end
				end
			end
		end
	end

	if HitEntityId == 0 and HitDynamicObject == nil then
		return nil, nil, MaxDistance, nil, nil
	end

	if HitDynamicObject == nil and HitEntityId > 0 and DynamicObjectsList then
		const PropRegister = buffer.readu32(PropertiesBuffer, (HitEntityId - 1) * PROPERTIES_STRIDE) :: number
		if bit32.btest(PropRegister, FLAG_HAS_DYNAMIC_ID) then
			const DynId = bit32.rshift(PropRegister, DYNAMIC_ID_SHIFT) :: number
			HitDynamicObject = DynamicObjectsList.ObjectsTable[DynId]
		end
	end

	const HitPosition = Vector3.new(
		OriginX + DirectionX * ClosestDistance,
		OriginY + DirectionY * ClosestDistance,
		OriginZ + DirectionZ * ClosestDistance
	) :: Vector3
	const HitNormal = Vector3.new(BestNormalX, BestNormalY, BestNormalZ) :: Vector3

	return if HitEntityId > 0 then HitEntityId else nil, HitDynamicObject, ClosestDistance, HitPosition, HitNormal
end

-- ============================================================================
-- 3. FAST AABB SPATIAL QUERY
-- ============================================================================

--[=[
	Queries the spatial tree for all entities whose bounding boxes overlap the given AABB.
	@param QueryMin Vector3 -- Minimum query bounds corner.
	@param QueryMax Vector3 -- Maximum query bounds corner.
	@param ResultsTable { number }? -- Optional reusable table to fill with hit entity IDs.
	@param ProvidedStorage ECSMain.ECSStorage? -- Target ECS storage.
	@return number -- Total count of overlapping entities found.
]=]
function BVH.QueryAABB(
	QueryMin: Vector3,
	QueryMax: Vector3,
	ResultsTable: { number }?,
	ProvidedStorage: ECSMain.ECSStorage?
): number
	if typeof(QueryMin) ~= "Vector3" or typeof(QueryMax) ~= "Vector3" then
		return 0
	end

	const Storage = BVHHelper.ResolveStorage(ProvidedStorage)
	if not Storage then
		return 0
	end

	const RawEntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const EntityCount = math.clamp(RawEntityCount, 0, MAX_ENTITIES) :: number
	local ShouldRebuild: boolean
	ShouldRebuild, MutationScanCursor = BVHHelper.NeedsRebuild(
		Storage,
		ActiveStorage,
		EntityCount,
		LastBuiltEntityCount,
		LastDynamicActiveCount,
		LastDynamicNextId,
		MutationScanCursor,
		CachedStateBuffer,
		EntityIsDynamicBuffer,
		ItemBoundsBuffer
	)
	if ShouldRebuild then
		BVH.Rebuild(Storage)
	end

	const QueryMinX = math.min(QueryMin.X, QueryMax.X) :: number
	const QueryMinY = math.min(QueryMin.Y, QueryMax.Y) :: number
	const QueryMinZ = math.min(QueryMin.Z, QueryMax.Z) :: number
	const QueryMaxX = math.max(QueryMin.X, QueryMax.X) :: number
	const QueryMaxY = math.max(QueryMin.Y, QueryMax.Y) :: number
	const QueryMaxZ = math.max(QueryMin.Z, QueryMax.Z) :: number

	local ResultCount = 0 :: number

	if AllocatedNodeBytes > 0 then
		local StackTop = 1 :: number
		buffer.writeu32(TraversalStackBuffer, 0, 0)

		while StackTop > 0 do
			StackTop -= 1
			const NodeOffset = buffer.readu32(TraversalStackBuffer, StackTop * 4) :: number

			if
				buffer.readf32(NodeBuffer, NodeOffset) > QueryMaxX
				or buffer.readf32(NodeBuffer, NodeOffset + 16) < QueryMinX
				or buffer.readf32(NodeBuffer, NodeOffset + 4) > QueryMaxY
				or buffer.readf32(NodeBuffer, NodeOffset + 20) < QueryMinY
				or buffer.readf32(NodeBuffer, NodeOffset + 8) > QueryMaxZ
				or buffer.readf32(NodeBuffer, NodeOffset + 24) < QueryMinZ
			then
				continue
			end

			const RightOffset = buffer.readu32(NodeBuffer, NodeOffset + 28) :: number
			if RightOffset == 0 then
				const EntityId = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
				if EntityId >= 1 and EntityId <= EntityCount then
					ResultCount += 1
					if ResultsTable then
						ResultsTable[ResultCount] = EntityId
					end
				end
			else
				const LeftOffset = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
				if StackTop + 2 <= STACK_CAPACITY then
					buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
					buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, RightOffset)
					StackTop += 2
				end
			end
		end
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	for i = 0, DynamicEntityCount - 1 do
		const EntityId = buffer.readu32(DynamicEntitiesBuffer, i * 4) :: number
		if EntityId < 1 or EntityId > EntityCount then
			continue
		end

		const PropRegister = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
		if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
			continue
		end

		const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
		const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

		const PositionX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PositionY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PositionZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

		const HalfSizeX = math.abs(buffer.readf32(SizeBuffer, CompOffset)) * 0.5 :: number
		const HalfSizeY = math.abs(buffer.readf32(SizeBuffer, CompOffset + 4)) * 0.5 :: number
		const HalfSizeZ = math.abs(buffer.readf32(SizeBuffer, CompOffset + 8)) * 0.5 :: number

		local LookX = buffer.readf32(DirectionsBuffer, DirOffset) :: number
		local LookY = buffer.readf32(DirectionsBuffer, DirOffset + 4) :: number
		local LookZ = buffer.readf32(DirectionsBuffer, DirOffset + 8) :: number

		local UpX = buffer.readf32(DirectionsBuffer, DirOffset + 12) :: number
		local UpY = buffer.readf32(DirectionsBuffer, DirOffset + 16) :: number
		local UpZ = buffer.readf32(DirectionsBuffer, DirOffset + 20) :: number

		local RightX = buffer.readf32(DirectionsBuffer, DirOffset + 24) :: number
		local RightY = buffer.readf32(DirectionsBuffer, DirOffset + 28) :: number
		local RightZ = buffer.readf32(DirectionsBuffer, DirOffset + 32) :: number

		if RightX * RightX + RightY * RightY + RightZ * RightZ < 0.5 then
			LookX, LookY, LookZ = 0, 0, -1
			UpX, UpY, UpZ = 0, 1, 0
			RightX, RightY, RightZ = 1, 0, 0
		end

		const WorldExtentX =
			math.abs(RightX) * HalfSizeX + math.abs(UpX) * HalfSizeY + math.abs(LookX) * HalfSizeZ :: number
		const WorldExtentY =
			math.abs(RightY) * HalfSizeX + math.abs(UpY) * HalfSizeY + math.abs(LookY) * HalfSizeZ :: number
		const WorldExtentZ =
			math.abs(RightZ) * HalfSizeX + math.abs(UpZ) * HalfSizeY + math.abs(LookZ) * HalfSizeZ :: number

		if
			PositionX - WorldExtentX <= QueryMaxX
			and PositionX + WorldExtentX >= QueryMinX
			and PositionY - WorldExtentY <= QueryMaxY
			and PositionY + WorldExtentY >= QueryMinY
			and PositionZ - WorldExtentZ <= QueryMaxZ
			and PositionZ + WorldExtentZ >= QueryMinZ
		then
			ResultCount += 1
			if ResultsTable then
				ResultsTable[ResultCount] = EntityId
			end
		end
	end

	return ResultCount
end

setmetatable(BVH, {
	__call = function(_, ...: any)
		return BVH.Raycast(...)
	end,
})

return BVH
