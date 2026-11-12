--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
const IS_SERVER = RunService:IsServer() :: boolean
const SelfActor = script:GetActor() :: Actor?

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

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
const SAFE_BALANCED_DEPTH = math.max(16, STACK_CAPACITY - 16) :: number
const MUTATION_SCAN_BUDGET = 256 :: number

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
local DefaultServerStorage: ECSMain.ECSStorage? = nil
local DefaultClientStorage: ECSMain.ECSStorage? = nil
local DefaultRenderStorage: ECSMain.ECSStorage? = nil

local AllocatedNodeBytes = 0 :: number
local DynamicEntityCount = 0 :: number
local LastBuiltEntityCount = -1 :: number
local LastDynamicNextId = -1 :: number
local LastDynamicActiveCount = -1 :: number
local MutationScanCursor = 1 :: number
local RayGeneration = 0 :: number

local BVH = {}

-- ============================================================================
-- 1. STORAGE RESOLUTION & MUTATION DETECTION
-- ============================================================================

local function IsECSStorage(Candidate: any): boolean
	return type(Candidate) == "table"
		and Candidate.ECSData ~= nil
		and Candidate.PositionData ~= nil
		and Candidate.SizeData ~= nil
		and Candidate.DirectionsData ~= nil
end

local function ResolveStorage(ProvidedStorage: ECSMain.ECSStorage?): ECSMain.ECSStorage?
	if ProvidedStorage and IsECSStorage(ProvidedStorage) then
		return ProvidedStorage
	end

	if IS_SERVER then
		if not DefaultServerStorage then
			const ServerFolder = ServerScriptService:FindFirstChild("Server")
			const ObjectsFolder = if ServerFolder then ServerFolder:FindFirstChild("Objects") else nil
			const ObjectsECS = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectsECS") else nil
			const StorageModule = if ObjectsECS then ObjectsECS:FindFirstChild("Storage") else nil
			if StorageModule and StorageModule:IsA("ModuleScript") then
				DefaultServerStorage = require(StorageModule) :: any
			end
		end
		return DefaultServerStorage
	end

	if not DefaultClientStorage then
		const ActorStorage = if SelfActor then SelfActor:FindFirstChild("ObjectStorage") else nil
		if ActorStorage and ActorStorage:IsA("ModuleScript") then
			DefaultClientStorage = require(ActorStorage) :: any
		else
			const LocalPlayer = Players.LocalPlayer :: Player?
			const PlayerScripts = if LocalPlayer then LocalPlayer:FindFirstChild("PlayerScripts") else nil
			const ControllerActor = if PlayerScripts then PlayerScripts:FindFirstChild("Controller") else nil
			const ControllerStorage = if ControllerActor then ControllerActor:FindFirstChild("ObjectStorage") else nil
			if ControllerStorage and ControllerStorage:IsA("ModuleScript") then
				DefaultClientStorage = require(ControllerStorage) :: any
			elseif PlayerScripts then
				const ClientFolder = PlayerScripts:FindFirstChild("Client")
				const ObjectsFolder = if ClientFolder then ClientFolder:FindFirstChild("Objects") else nil
				const ObjStorage = if ObjectsFolder then ObjectsFolder:FindFirstChild("ObjectStorage") else nil
				if ObjStorage and ObjStorage:IsA("ModuleScript") then
					DefaultClientStorage = require(ObjStorage) :: any
				end
			end
		end
	end

	if DefaultClientStorage and DefaultClientStorage.ECSData.GetCounts().EntityECSCount > 0 then
		return DefaultClientStorage
	end

	if not DefaultRenderStorage then
		const SharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		const UtilitiesFolder = if SharedFolder then SharedFolder:FindFirstChild("Utilities") else nil
		const RenderFolder = if UtilitiesFolder then UtilitiesFolder:FindFirstChild("Render") else nil
		const RenderStorageModule = if RenderFolder then RenderFolder:FindFirstChild("ECSStorage") else nil
		if RenderStorageModule and RenderStorageModule:IsA("ModuleScript") then
			DefaultRenderStorage = require(RenderStorageModule) :: any
		end
	end

	return DefaultRenderStorage or DefaultClientStorage
end

local function NeedsRebuild(Storage: ECSMain.ECSStorage, EntityCount: number): boolean
	if Storage ~= ActiveStorage or EntityCount ~= LastBuiltEntityCount then
		return true
	end

	const DynList = Storage.DynamicObjectsList
	if DynList then
		if DynList.Counts.ActiveCount ~= LastDynamicActiveCount or DynList.Counts.NextId ~= LastDynamicNextId then
			return true
		end
	end

	if EntityCount <= 0 then
		return false
	end

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer

	const CheckCount = math.min(EntityCount, MUTATION_SCAN_BUDGET) :: number
	local EntityId = MutationScanCursor :: number
	if EntityId < 1 or EntityId > EntityCount then
		EntityId = 1
	end

	for _ = 1, CheckCount do
		const StateOffset = (EntityId - 1) * CACHED_STATE_STRIDE :: number
		const PropOffset = (EntityId - 1) * PROPERTIES_STRIDE :: number
		const CurrentProp = buffer.readu32(PropertiesBuffer, PropOffset) :: number

		if CurrentProp ~= buffer.readu32(CachedStateBuffer, StateOffset + 24) then
			MutationScanCursor = EntityId
			return true
		end

		if buffer.readu8(EntityIsDynamicBuffer, EntityId) == 0 then
			const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number
			const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number
			const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number

			if
				buffer.readf32(PositionBuffer, CompOffset) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 24)
				or buffer.readf32(PositionBuffer, CompOffset + 4) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 28)
				or buffer.readf32(PositionBuffer, CompOffset + 8) ~= buffer.readf32(ItemBoundsBuffer, BoundsOffset + 32)
				or buffer.readf32(SizeBuffer, CompOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset)
				or buffer.readf32(SizeBuffer, CompOffset + 4) ~= buffer.readf32(CachedStateBuffer, StateOffset + 4)
				or buffer.readf32(SizeBuffer, CompOffset + 8) ~= buffer.readf32(CachedStateBuffer, StateOffset + 8)
				or buffer.readf32(DirectionsBuffer, DirOffset) ~= buffer.readf32(CachedStateBuffer, StateOffset + 12)
				or buffer.readf32(DirectionsBuffer, DirOffset + 16) ~= buffer.readf32(CachedStateBuffer, StateOffset + 16)
				or buffer.readf32(DirectionsBuffer, DirOffset + 32) ~= buffer.readf32(CachedStateBuffer, StateOffset + 20)
			then
				MutationScanCursor = EntityId
				return true
			end
		end

		EntityId += 1
		if EntityId > EntityCount then
			EntityId = 1
		end
	end

	MutationScanCursor = EntityId
	return false
end

-- ============================================================================
-- 2. FLAT-BUFFER TREE BUILDER
-- ============================================================================

local function BuildSubtree(StartIdx: number, EndIdx: number, Depth: number): number
	const NodeOffset = AllocatedNodeBytes :: number
	AllocatedNodeBytes += NODE_STRIDE

	local MinX: number, MinY: number, MinZ: number = math.huge, math.huge, math.huge
	local MaxX: number, MaxY: number, MaxZ: number = -math.huge, -math.huge, -math.huge
	local CMinX: number, CMinY: number, CMinZ: number = math.huge, math.huge, math.huge
	local CMaxX: number, CMaxY: number, CMaxZ: number = -math.huge, -math.huge, -math.huge

	for i = StartIdx, EndIdx do
		const EntityId = buffer.readu32(ItemIndicesBuffer, (i - 1) * 4) :: number
		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number

		const BMinX = buffer.readf32(ItemBoundsBuffer, BoundsOffset) :: number
		const BMinY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 4) :: number
		const BMinZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 8) :: number
		const BMaxX = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 12) :: number
		const BMaxY = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 16) :: number
		const BMaxZ = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 20) :: number
		const Cx = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 24) :: number
		const Cy = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 28) :: number
		const Cz = buffer.readf32(ItemBoundsBuffer, BoundsOffset + 32) :: number

		if BMinX < MinX then MinX = BMinX end
		if BMinY < MinY then MinY = BMinY end
		if BMinZ < MinZ then MinZ = BMinZ end
		if BMaxX > MaxX then MaxX = BMaxX end
		if BMaxY > MaxY then MaxY = BMaxY end
		if BMaxZ > MaxZ then MaxZ = BMaxZ end

		if Cx < CMinX then CMinX = Cx end
		if Cy < CMinY then CMinY = Cy end
		if Cz < CMinZ then CMinZ = Cz end
		if Cx > CMaxX then CMaxX = Cx end
		if Cy > CMaxY then CMaxY = Cy end
		if Cz > CMaxZ then CMaxZ = Cz end
	end

	buffer.writef32(NodeBuffer, NodeOffset, MinX)
	buffer.writef32(NodeBuffer, NodeOffset + 4, MinY)
	buffer.writef32(NodeBuffer, NodeOffset + 8, MinZ)
	buffer.writef32(NodeBuffer, NodeOffset + 16, MaxX)
	buffer.writef32(NodeBuffer, NodeOffset + 20, MaxY)
	buffer.writef32(NodeBuffer, NodeOffset + 24, MaxZ)

	if StartIdx >= EndIdx or AllocatedNodeBytes + (NODE_STRIDE * 2) > MAX_NODE_BYTES then
		const LeafEntityId = buffer.readu32(ItemIndicesBuffer, (StartIdx - 1) * 4) :: number
		buffer.writeu32(NodeBuffer, NodeOffset + 12, LeafEntityId)
		buffer.writeu32(NodeBuffer, NodeOffset + 28, 0)
		return NodeOffset
	end

	const ExtentX = CMaxX - CMinX :: number
	const ExtentY = CMaxY - CMinY :: number
	const ExtentZ = CMaxZ - CMinZ :: number

	local AxisOffset = 24 :: number
	local SplitPos = (CMinX + CMaxX) * 0.5 :: number
	local MaxExtent = ExtentX :: number

	if ExtentY > MaxExtent then
		AxisOffset = 28
		SplitPos = (CMinY + CMaxY) * 0.5
		MaxExtent = ExtentY
	end
	if ExtentZ > MaxExtent then
		AxisOffset = 32
		SplitPos = (CMinZ + CMaxZ) * 0.5
		MaxExtent = ExtentZ
	end

	local Mid = (StartIdx + EndIdx) // 2 :: number
	if MaxExtent > 1e-4 and Depth < SAFE_BALANCED_DEPTH then
		local Left = StartIdx :: number
		local Right = EndIdx :: number

		while Left <= Right do
			const LeftEntity = buffer.readu32(ItemIndicesBuffer, (Left - 1) * 4) :: number
			const CenterVal = buffer.readf32(ItemBoundsBuffer, (LeftEntity - 1) * ITEM_BOUNDS_STRIDE + AxisOffset) :: number
			if CenterVal < SplitPos then
				Left += 1
			else
				const RightEntity = buffer.readu32(ItemIndicesBuffer, (Right - 1) * 4) :: number
				buffer.writeu32(ItemIndicesBuffer, (Left - 1) * 4, RightEntity)
				buffer.writeu32(ItemIndicesBuffer, (Right - 1) * 4, LeftEntity)
				Right -= 1
			end
		end

		if Left > StartIdx and Left <= EndIdx then
			Mid = Left - 1
		end
	end

	const NextDepth = Depth + 1 :: number
	const LeftNodeOffset = BuildSubtree(StartIdx, Mid, NextDepth) :: number
	const RightNodeOffset = BuildSubtree(Mid + 1, EndIdx, NextDepth) :: number

	buffer.writeu32(NodeBuffer, NodeOffset + 12, LeftNodeOffset)
	buffer.writeu32(NodeBuffer, NodeOffset + 28, RightNodeOffset)

	return NodeOffset
end

function BVH.Rebuild(ProvidedStorage: ECSMain.ECSStorage?)
	const Storage = ResolveStorage(ProvidedStorage)
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
		const IsDynamic = HasDynamicObject
			or (StaticBuffer ~= nil and buffer.readu8(StaticBuffer, EntityId - 1) == 0)
			or (PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_ANCHORED)) :: boolean

		if IsDynamic then
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 1)
			buffer.writeu32(DynamicEntitiesBuffer, DynamicEntityCount * 4, EntityId)
			DynamicEntityCount += 1
		else
			buffer.writeu8(EntityIsDynamicBuffer, EntityId, 0)
		end

		const PosX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PosY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

		const Hx = math.abs(RawSizeX) * 0.5 :: number
		const Hy = math.abs(RawSizeY) * 0.5 :: number
		const Hz = math.abs(RawSizeZ) * 0.5 :: number

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

		const WorldHx = math.abs(RightX) * Hx + math.abs(UpX) * Hy + math.abs(LookX) * Hz :: number
		const WorldHy = math.abs(RightY) * Hx + math.abs(UpY) * Hy + math.abs(LookY) * Hz :: number
		const WorldHz = math.abs(RightZ) * Hx + math.abs(UpZ) * Hy + math.abs(LookZ) * Hz :: number

		const BoundsOffset = (EntityId - 1) * ITEM_BOUNDS_STRIDE :: number
		buffer.writef32(ItemBoundsBuffer, BoundsOffset, PosX - WorldHx)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 4, PosY - WorldHy)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 8, PosZ - WorldHz)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 12, PosX + WorldHx)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 16, PosY + WorldHy)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 20, PosZ + WorldHz)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 24, PosX)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 28, PosY)
		buffer.writef32(ItemBoundsBuffer, BoundsOffset + 32, PosZ)

		if not IsDynamic then
			StaticItemCount += 1
			buffer.writeu32(ItemIndicesBuffer, (StaticItemCount - 1) * 4, EntityId)
		end
	end

	if StaticItemCount > 0 then
		BuildSubtree(1, StaticItemCount, 0)
	end
end

-- ============================================================================
-- 3. SCALAR RAY-AABB & RAY-OBB INTERSECTION KERNELS
-- ============================================================================

local function TestNodeAABB(
	NodeOffset: number,
	Ox: number,
	Oy: number,
	Oz: number,
	InvDx: number,
	InvDy: number,
	InvDz: number,
	MaxDist: number
): (boolean, number)
	const MinX = buffer.readf32(NodeBuffer, NodeOffset) :: number
	const MinY = buffer.readf32(NodeBuffer, NodeOffset + 4) :: number
	const MinZ = buffer.readf32(NodeBuffer, NodeOffset + 8) :: number
	const MaxX = buffer.readf32(NodeBuffer, NodeOffset + 16) :: number
	const MaxY = buffer.readf32(NodeBuffer, NodeOffset + 20) :: number
	const MaxZ = buffer.readf32(NodeBuffer, NodeOffset + 24) :: number

	const Tx1 = (MinX - Ox) * InvDx :: number
	const Tx2 = (MaxX - Ox) * InvDx :: number
	local Tmin = math.min(Tx1, Tx2) :: number
	local Tmax = math.max(Tx1, Tx2) :: number

	const Ty1 = (MinY - Oy) * InvDy :: number
	const Ty2 = (MaxY - Oy) * InvDy :: number
	Tmin = math.max(Tmin, math.min(Ty1, Ty2))
	Tmax = math.min(Tmax, math.max(Ty1, Ty2))

	const Tz1 = (MinZ - Oz) * InvDz :: number
	const Tz2 = (MaxZ - Oz) * InvDz :: number
	Tmin = math.max(Tmin, math.min(Tz1, Tz2))
	Tmax = math.min(Tmax, math.max(Tz1, Tz2))

	const EntryDist = math.max(0, Tmin) :: number
	return (Tmax >= EntryDist) and (EntryDist < MaxDist), EntryDist
end

local function TestBoxOBB(
	Ox: number,
	Oy: number,
	Oz: number,
	Dx: number,
	Dy: number,
	Dz: number,
	PosX: number,
	PosY: number,
	PosZ: number,
	Hx: number,
	Hy: number,
	Hz: number,
	RightX: number,
	RightY: number,
	RightZ: number,
	UpX: number,
	UpY: number,
	UpZ: number,
	LookX: number,
	LookY: number,
	LookZ: number,
	MaxDist: number
): (boolean, number, number, number, number)
	const DeltaX = Ox - PosX :: number
	const DeltaY = Oy - PosY :: number
	const DeltaZ = Oz - PosZ :: number

	const LocalOx = DeltaX * RightX + DeltaY * RightY + DeltaZ * RightZ :: number
	const LocalOy = DeltaX * UpX + DeltaY * UpY + DeltaZ * UpZ :: number
	const LocalOz = DeltaX * LookX + DeltaY * LookY + DeltaZ * LookZ :: number

	const LocalDx = Dx * RightX + Dy * RightY + Dz * RightZ :: number
	const LocalDy = Dx * UpX + Dy * UpY + Dz * UpZ :: number
	const LocalDz = Dx * LookX + Dy * LookY + Dz * LookZ :: number

	const InvLx = if math.abs(LocalDx) > 1e-8 then 1 / LocalDx else (if LocalDx >= 0 then 1e30 else -1e30) :: number
	const InvLy = if math.abs(LocalDy) > 1e-8 then 1 / LocalDy else (if LocalDy >= 0 then 1e30 else -1e30) :: number
	const InvLz = if math.abs(LocalDz) > 1e-8 then 1 / LocalDz else (if LocalDz >= 0 then 1e30 else -1e30) :: number

	const Tx1 = (-Hx - LocalOx) * InvLx :: number
	const Tx2 = (Hx - LocalOx) * InvLx :: number
	local Tmin = math.min(Tx1, Tx2) :: number
	local Tmax = math.max(Tx1, Tx2) :: number
	local HitAxis = 0 :: number

	const Ty1 = (-Hy - LocalOy) * InvLy :: number
	const Ty2 = (Hy - LocalOy) * InvLy :: number
	const TyMin = math.min(Ty1, Ty2) :: number
	const TyMax = math.max(Ty1, Ty2) :: number
	if TyMin > Tmin then
		Tmin = TyMin
		HitAxis = 1
	end
	if TyMax < Tmax then
		Tmax = TyMax
	end

	const Tz1 = (-Hz - LocalOz) * InvLz :: number
	const Tz2 = (Hz - LocalOz) * InvLz :: number
	const TzMin = math.min(Tz1, Tz2) :: number
	const TzMax = math.max(Tz1, Tz2) :: number
	if TzMin > Tmin then
		Tmin = TzMin
		HitAxis = 2
	end
	if TzMax < Tmax then
		Tmax = TzMax
	end

	const EntryDist = math.max(0, Tmin) :: number
	if Tmax < EntryDist or EntryDist >= MaxDist then
		return false, MaxDist, 0, 0, 0
	end

	if HitAxis == 0 then
		const Sign = if LocalDx > 0 then -1 else 1 :: number
		return true, EntryDist, RightX * Sign, RightY * Sign, RightZ * Sign
	elseif HitAxis == 1 then
		const Sign = if LocalDy > 0 then -1 else 1 :: number
		return true, EntryDist, UpX * Sign, UpY * Sign, UpZ * Sign
	else
		const Sign = if LocalDz > 0 then -1 else 1 :: number
		return true, EntryDist, LookX * Sign, LookY * Sign, LookZ * Sign
	end
end

local function TestEntityOBB(
	EntityId: number,
	Ox: number,
	Oy: number,
	Oz: number,
	Dx: number,
	Dy: number,
	Dz: number,
	MaxDist: number,
	PositionBuffer: buffer,
	SizeBuffer: buffer,
	DirectionsBuffer: buffer,
	PropertiesBuffer: buffer
): (boolean, number, number, number, number)
	const PropRegister = buffer.readu32(PropertiesBuffer, (EntityId - 1) * PROPERTIES_STRIDE) :: number
	if PropRegister ~= 0 and not bit32.btest(PropRegister, FLAG_CAN_COLLIDE) then
		return false, MaxDist, 0, 0, 0
	end

	const CompOffset = (EntityId - 1) * COMPONENT_STRIDE :: number

	const PosX = buffer.readf32(PositionBuffer, CompOffset) :: number
	const PosY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
	const PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

	const Hx = math.abs(buffer.readf32(SizeBuffer, CompOffset)) * 0.5 :: number
	const Hy = math.abs(buffer.readf32(SizeBuffer, CompOffset + 4)) * 0.5 :: number
	const Hz = math.abs(buffer.readf32(SizeBuffer, CompOffset + 8)) * 0.5 :: number

	const RelX = PosX - Ox :: number
	const RelY = PosY - Oy :: number
	const RelZ = PosZ - Oz :: number
	const RadiusSq = Hx * Hx + Hy * Hy + Hz * Hz :: number
	const Proj = RelX * Dx + RelY * Dy + RelZ * Dz :: number
	const PerpDistSq = (RelX * RelX + RelY * RelY + RelZ * RelZ) - (Proj * Proj) :: number
	if PerpDistSq > RadiusSq + 1e-5 then
		return false, MaxDist, 0, 0, 0
	end

	const Radius = math.sqrt(RadiusSq) :: number
	if Proj < -Radius or (Proj - Radius) >= MaxDist then
		return false, MaxDist, 0, 0, 0
	end

	const DirOffset = (EntityId - 1) * DIRECTION_STRIDE :: number

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

	return TestBoxOBB(
		Ox,
		Oy,
		Oz,
		Dx,
		Dy,
		Dz,
		PosX,
		PosY,
		PosZ,
		Hx,
		Hy,
		Hz,
		RightX,
		RightY,
		RightZ,
		UpX,
		UpY,
		UpZ,
		LookX,
		LookY,
		LookZ,
		MaxDist
	)
end

local function IsIgnored(
	EntityId: number,
	DynObject: any,
	IgnoredId: number,
	IgnoreFilter: any
): boolean
	if EntityId > 0 and EntityId == IgnoredId then
		return true
	end
	if IgnoreFilter == nil then
		return false
	end
	if DynObject ~= nil and IgnoreFilter == DynObject then
		return true
	end
	if type(IgnoreFilter) == "table" then
		if EntityId > 0 and IgnoreFilter[EntityId] == true then
			return true
		end
		for _, Item in ipairs(IgnoreFilter) do
			if (EntityId > 0 and Item == EntityId) or (DynObject ~= nil and Item == DynObject) then
				return true
			end
		end
	end
	return false
end

-- ============================================================================
-- 4. UNIFIED 1-CALL RAYCAST (STATIC BVH + LIVE DYNAMIC OOP OBJECTS)
-- ============================================================================

function BVH.Raycast(
	Arg1: any,
	Arg2: any,
	Arg3: any?,
	Arg4: any?,
	Arg5: any?
): (number?, any?, number, Vector3?, Vector3?)
	local Origin: Vector3? = nil
	local Dir: Vector3? = nil
	local MaxDistanceArg: number? = nil
	local IgnoreFilter: any = nil
	local ProvidedStorage: ECSMain.ECSStorage? = nil

	if typeof(Arg1) == "Vector3" then
		Origin = Arg1
		Dir = if typeof(Arg2) == "Vector3" then Arg2 else nil
		if type(Arg3) == "number" then
			MaxDistanceArg = Arg3
			if IsECSStorage(Arg4) then
				ProvidedStorage = Arg4
				IgnoreFilter = Arg5
			else
				IgnoreFilter = Arg4
				ProvidedStorage = if IsECSStorage(Arg5) then Arg5 else nil
			end
		elseif IsECSStorage(Arg3) then
			ProvidedStorage = Arg3
			if type(Arg4) == "number" then
				MaxDistanceArg = Arg4
				IgnoreFilter = Arg5
			else
				IgnoreFilter = Arg4
			end
		else
			IgnoreFilter = Arg3
			ProvidedStorage = if IsECSStorage(Arg4) then Arg4 elseif IsECSStorage(Arg5) then Arg5 else nil
		end
	elseif IsECSStorage(Arg1) then
		ProvidedStorage = Arg1
		Origin = if typeof(Arg2) == "Vector3" then Arg2 else nil
		Dir = if typeof(Arg3) == "Vector3" then Arg3 else nil
		if type(Arg4) == "number" then
			MaxDistanceArg = Arg4
			IgnoreFilter = Arg5
		else
			IgnoreFilter = Arg4
		end
	end

	if not Origin or not Dir then
		return nil, nil, 0, nil, nil
	end

	const Ox: number, Oy: number, Oz: number = Origin.X, Origin.Y, Origin.Z
	if
		Ox ~= Ox
		or Oy ~= Oy
		or Oz ~= Oz
		or math.abs(Ox) == math.huge
		or math.abs(Oy) == math.huge
		or math.abs(Oz) == math.huge
	then
		return nil, nil, 0, nil, nil
	end

	const DirLen = Dir.Magnitude :: number
	if not (DirLen > 1e-8 and DirLen < math.huge) then
		return nil, nil, 0, nil, nil
	end

	if MaxDistanceArg ~= nil and not (MaxDistanceArg > 0) then
		return nil, nil, 0, nil, nil
	end

	const InvDirLen = 1 / DirLen :: number
	const Dx = Dir.X * InvDirLen :: number
	const Dy = Dir.Y * InvDirLen :: number
	const Dz = Dir.Z * InvDirLen :: number
	const MaxDist = if MaxDistanceArg then math.min(MaxDistanceArg, 1e15) else DirLen :: number

	const Storage = ResolveStorage(ProvidedStorage)
	if not Storage then
		return nil, nil, MaxDist, nil, nil
	end

	const RawEntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const EntityCount = math.clamp(RawEntityCount, 0, MAX_ENTITIES) :: number
	if NeedsRebuild(Storage, EntityCount) then
		BVH.Rebuild(Storage)
	end

	const InvDx = if math.abs(Dx) > 1e-8 then 1 / Dx else (if Dx >= 0 then 1e30 else -1e30) :: number
	const InvDy = if math.abs(Dy) > 1e-8 then 1 / Dy else (if Dy >= 0 then 1e30 else -1e30) :: number
	const InvDz = if math.abs(Dz) > 1e-8 then 1 / Dz else (if Dz >= 0 then 1e30 else -1e30) :: number

	const PositionBuffer = Storage.PositionData.GetData() :: buffer
	const SizeBuffer = Storage.SizeData.GetData() :: buffer
	const DirectionsBuffer = Storage.DirectionsData.GetData() :: buffer
	const PropertiesBuffer = Storage.PropertiesData.GetData() :: buffer
	const DynamicObjectsList = Storage.DynamicObjectsList

	RayGeneration += 1
	const CurrentRayGen = RayGeneration :: number
	const IgnoredId = if type(IgnoreFilter) == "number" then IgnoreFilter else 0 :: number
	const HasComplexIgnore = IgnoreFilter ~= nil and type(IgnoreFilter) ~= "number" :: boolean

	local ClosestDist = MaxDist :: number
	local HitEntityId = 0 :: number
	local HitDynamicObject: any = nil
	local BestNx: number, BestNy: number, BestNz: number = 0, 1, 0

	-- 1. Traverse Flat-Buffer Static BVH (Near-First Child Ordering)
	if AllocatedNodeBytes > 0 then
		const RootHit, _ = TestNodeAABB(0, Ox, Oy, Oz, InvDx, InvDy, InvDz, ClosestDist)
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
						if IsIgnored(EntityId, EntityObj, IgnoredId, IgnoreFilter) then
							continue
						end
					end

					buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)

					const Hit, HitDist, Nx, Ny, Nz = TestEntityOBB(
						EntityId,
						Ox,
						Oy,
						Oz,
						Dx,
						Dy,
						Dz,
						ClosestDist,
						PositionBuffer,
						SizeBuffer,
						DirectionsBuffer,
						PropertiesBuffer
					)
					if Hit then
						ClosestDist = HitDist
						HitEntityId = EntityId
						HitDynamicObject = nil
						BestNx, BestNy, BestNz = Nx, Ny, Nz
					end
				else
					const LeftOffset = buffer.readu32(NodeBuffer, NodeOffset + 12) :: number
					const HitL, DistL = TestNodeAABB(LeftOffset, Ox, Oy, Oz, InvDx, InvDy, InvDz, ClosestDist)
					const HitR, DistR = TestNodeAABB(RightOffset, Ox, Oy, Oz, InvDx, InvDy, InvDz, ClosestDist)

					if HitL and HitR then
						if StackTop + 2 <= STACK_CAPACITY then
							if DistL < DistR then
								buffer.writeu32(TraversalStackBuffer, StackTop * 4, RightOffset)
								buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, LeftOffset)
							else
								buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
								buffer.writeu32(TraversalStackBuffer, (StackTop + 1) * 4, RightOffset)
							end
							StackTop += 2
						end
					elseif HitL and StackTop < STACK_CAPACITY then
						buffer.writeu32(TraversalStackBuffer, StackTop * 4, LeftOffset)
						StackTop += 1
					elseif HitR and StackTop < STACK_CAPACITY then
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
			if IsIgnored(EntityId, EntityObj, IgnoredId, IgnoreFilter) then
				continue
			end
		end

		buffer.writeu32(TestedGenBuffer, EntityId * 4, CurrentRayGen)

		const Hit, HitDist, Nx, Ny, Nz = TestEntityOBB(
			EntityId,
			Ox,
			Oy,
			Oz,
			Dx,
			Dy,
			Dz,
			ClosestDist,
			PositionBuffer,
			SizeBuffer,
			DirectionsBuffer,
			PropertiesBuffer
		)
		if Hit then
			ClosestDist = HitDist
			HitEntityId = EntityId
			HitDynamicObject = nil
			BestNx, BestNy, BestNz = Nx, Ny, Nz
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
				if HasComplexIgnore and IsIgnored(BoundEntityId, DynObject, IgnoredId, IgnoreFilter) then
					continue
				end

				buffer.writeu32(TestedGenBuffer, BoundEntityId * 4, CurrentRayGen)

				const Hit, HitDist, Nx, Ny, Nz = TestEntityOBB(
					BoundEntityId,
					Ox,
					Oy,
					Oz,
					Dx,
					Dy,
					Dz,
					ClosestDist,
					PositionBuffer,
					SizeBuffer,
					DirectionsBuffer,
					PropertiesBuffer
				)
				if Hit then
					ClosestDist = HitDist
					HitEntityId = BoundEntityId
					HitDynamicObject = DynObject
					BestNx, BestNy, BestNz = Nx, Ny, Nz
				end
			elseif type(DynObject) == "table" or typeof(DynObject) == "Instance" then
				const ObjEntityId = if type(DynObject) == "table" and type((DynObject :: any).EntityId) == "number"
					then (DynObject :: any).EntityId :: number
					else 0
				if IsIgnored(ObjEntityId, DynObject, IgnoredId, IgnoreFilter) then
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
					const Hx = math.abs(ObjSize.X) * 0.5 :: number
					const Hy = math.abs(ObjSize.Y) * 0.5 :: number
					const Hz = math.abs(ObjSize.Z) * 0.5 :: number

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

					const Hit, HitDist, Nx, Ny, Nz = TestBoxOBB(
						Ox,
						Oy,
						Oz,
						Dx,
						Dy,
						Dz,
						ObjPos.X,
						ObjPos.Y,
						ObjPos.Z,
						Hx,
						Hy,
						Hz,
						RightX,
						RightY,
						RightZ,
						UpX,
						UpY,
						UpZ,
						LookX,
						LookY,
						LookZ,
						ClosestDist
					)
					if Hit then
						ClosestDist = HitDist
						HitEntityId = ObjEntityId
						HitDynamicObject = DynObject
						BestNx, BestNy, BestNz = Nx, Ny, Nz
					end
				end
			end
		end
	end

	if HitEntityId == 0 and HitDynamicObject == nil then
		return nil, nil, MaxDist, nil, nil
	end

	if HitDynamicObject == nil and HitEntityId > 0 and DynamicObjectsList then
		const PropRegister = buffer.readu32(PropertiesBuffer, (HitEntityId - 1) * PROPERTIES_STRIDE) :: number
		if bit32.btest(PropRegister, FLAG_HAS_DYNAMIC_ID) then
			const DynId = bit32.rshift(PropRegister, DYNAMIC_ID_SHIFT) :: number
			HitDynamicObject = DynamicObjectsList.ObjectsTable[DynId]
		end
	end

	const HitPosition = Vector3.new(Ox + Dx * ClosestDist, Oy + Dy * ClosestDist, Oz + Dz * ClosestDist) :: Vector3
	const HitNormal = Vector3.new(BestNx, BestNy, BestNz) :: Vector3

	return if HitEntityId > 0 then HitEntityId else nil, HitDynamicObject, ClosestDist, HitPosition, HitNormal
end

-- ============================================================================
-- 5. FAST AABB SPATIAL QUERY
-- ============================================================================

function BVH.QueryAABB(
	QueryMin: Vector3,
	QueryMax: Vector3,
	ResultsTable: { number }?,
	ProvidedStorage: ECSMain.ECSStorage?
): number
	if typeof(QueryMin) ~= "Vector3" or typeof(QueryMax) ~= "Vector3" then
		return 0
	end

	const Storage = ResolveStorage(ProvidedStorage)
	if not Storage then
		return 0
	end

	const RawEntityCount = Storage.ECSData.GetCounts().EntityECSCount :: number
	const EntityCount = math.clamp(RawEntityCount, 0, MAX_ENTITIES) :: number
	if NeedsRebuild(Storage, EntityCount) then
		BVH.Rebuild(Storage)
	end

	const QMinX = math.min(QueryMin.X, QueryMax.X) :: number
	const QMinY = math.min(QueryMin.Y, QueryMax.Y) :: number
	const QMinZ = math.min(QueryMin.Z, QueryMax.Z) :: number
	const QMaxX = math.max(QueryMin.X, QueryMax.X) :: number
	const QMaxY = math.max(QueryMin.Y, QueryMax.Y) :: number
	const QMaxZ = math.max(QueryMin.Z, QueryMax.Z) :: number

	local ResultCount = 0 :: number

	if AllocatedNodeBytes > 0 then
		local StackTop = 1 :: number
		buffer.writeu32(TraversalStackBuffer, 0, 0)

		while StackTop > 0 do
			StackTop -= 1
			const NodeOffset = buffer.readu32(TraversalStackBuffer, StackTop * 4) :: number

			if
				buffer.readf32(NodeBuffer, NodeOffset) > QMaxX
				or buffer.readf32(NodeBuffer, NodeOffset + 16) < QMinX
				or buffer.readf32(NodeBuffer, NodeOffset + 4) > QMaxY
				or buffer.readf32(NodeBuffer, NodeOffset + 20) < QMinY
				or buffer.readf32(NodeBuffer, NodeOffset + 8) > QMaxZ
				or buffer.readf32(NodeBuffer, NodeOffset + 24) < QMinZ
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

		const PosX = buffer.readf32(PositionBuffer, CompOffset) :: number
		const PosY = buffer.readf32(PositionBuffer, CompOffset + 4) :: number
		const PosZ = buffer.readf32(PositionBuffer, CompOffset + 8) :: number

		const Hx = math.abs(buffer.readf32(SizeBuffer, CompOffset)) * 0.5 :: number
		const Hy = math.abs(buffer.readf32(SizeBuffer, CompOffset + 4)) * 0.5 :: number
		const Hz = math.abs(buffer.readf32(SizeBuffer, CompOffset + 8)) * 0.5 :: number

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

		const WorldHx = math.abs(RightX) * Hx + math.abs(UpX) * Hy + math.abs(LookX) * Hz :: number
		const WorldHy = math.abs(RightY) * Hx + math.abs(UpY) * Hy + math.abs(LookY) * Hz :: number
		const WorldHz = math.abs(RightZ) * Hx + math.abs(UpZ) * Hy + math.abs(LookZ) * Hz :: number

		if
			PosX - WorldHx <= QMaxX
			and PosX + WorldHx >= QMinX
			and PosY - WorldHy <= QMaxY
			and PosY + WorldHy >= QMinY
			and PosZ - WorldHz <= QMaxZ
			and PosZ + WorldHz >= QMinZ
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
