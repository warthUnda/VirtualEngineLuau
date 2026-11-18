--!strict
--!native
--!optimize 2

--[=[
	@class ResourceController
	Singleton control-theory resource orchestrator operating on both Server and Client.
	Reserves 2ms of untouched spike headroom, computes (OtherSystemsFrameTime - UsableTargetTime),
	and uses internal plant-model equilibrium + exponential-backoff ceiling locks so adapted
	1..100 scores lock steady without oscillating back into lag.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ControllerTheoryRoot = script.Parent.Parent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ControllerTheoryMath = require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))
const ResourceControllerHelper = require(script.Parent:WaitForChild("ResourceControllerHelper"))

-- Configs --
const TARGET_FRAME_TIME = SystemsConfigs.ControllerTargetFrameTime :: number
const FREE_TIME_RESERVE = SystemsConfigs.ControllerFreeTimeReserve :: number
const USABLE_FRAME_TIME = math.max(1e-4, TARGET_FRAME_TIME - FREE_TIME_RESERVE) :: number
const DEFAULT_RENDERER_WEIGHT = SystemsConfigs.ControllerRendererWeight :: number
const DEFAULT_PHYSICS_WEIGHT = SystemsConfigs.ControllerPhysicsWeight :: number
const INITIAL_SCORE = SystemsConfigs.ControllerInitialScore :: number

export type ControllerWeights = {
	Renderer: number,
	Physics: number,
}

export type ControllerScores = {
	Renderer: number,
	Physics: number,
}

export type ControllerFeedback = {
	RendererFrameTime: number,
	PhysicsFrameTime: number,
}

export type ControllerSingletonState = {
	Weights: ControllerWeights,
	Scores: ControllerScores,
	RawScores: ControllerScores,
	CeilingScores: ControllerScores,
	Feedback: ControllerFeedback,
	PreviousErrors: ControllerScores,
	RendererChannel: ControllerTheoryMath.ChannelState,
	PhysicsChannel: ControllerTheoryMath.ChannelState,
	TargetFrameTime: number,
	FreeTimeReserve: number,
	FreeFrameTime: number,
	FrameStartClock: number,
	WhereInFrame: number,
	TotalFrameTime: number,
	OtherSystemsFrameTime: number,
	OtherMinusTargetFrameTime: number,
	RendererBudget: number,
	PhysicsBudget: number,
	FrameTick: number,
	Initialized: boolean,
}

-- Variables --
local HeartbeatConnection: RBXScriptConnection? = nil

-- Tables --
local RendererChannelState = ResourceControllerHelper.CreateChannelState(false)
local PhysicsChannelState = ResourceControllerHelper.CreateChannelState(true)

local SingletonState: ControllerSingletonState = {
	Weights = { Renderer = DEFAULT_RENDERER_WEIGHT, Physics = DEFAULT_PHYSICS_WEIGHT },
	Scores = { Renderer = INITIAL_SCORE, Physics = INITIAL_SCORE },
	RawScores = { Renderer = INITIAL_SCORE, Physics = INITIAL_SCORE },
	CeilingScores = { Renderer = INITIAL_SCORE, Physics = INITIAL_SCORE },
	Feedback = { RendererFrameTime = 0, PhysicsFrameTime = 0 },
	PreviousErrors = { Renderer = 0, Physics = 0 },
	RendererChannel = RendererChannelState,
	PhysicsChannel = PhysicsChannelState,
	TargetFrameTime = TARGET_FRAME_TIME,
	FreeTimeReserve = FREE_TIME_RESERVE,
	FreeFrameTime = TARGET_FRAME_TIME,
	FrameStartClock = os.clock(),
	WhereInFrame = 0,
	TotalFrameTime = TARGET_FRAME_TIME,
	OtherSystemsFrameTime = 0,
	OtherMinusTargetFrameTime = -USABLE_FRAME_TIME,
	RendererBudget = DEFAULT_RENDERER_WEIGHT * USABLE_FRAME_TIME,
	PhysicsBudget = DEFAULT_PHYSICS_WEIGHT * USABLE_FRAME_TIME,
	FrameTick = 0,
	Initialized = false,
}

local ResourceController = {
	State = SingletonState,
}

-- Functions --
-- ============================================================================
-- 1. SINGLETON CONTROL-THEORY LIFECYCLE, FEEDBACK & NON-HUNTING 1..100 SCORES
-- ============================================================================

--[=[
	Updates and returns the current elapsed seconds inside the active frame (WhereInFrame).
	@param NowClockOverride number? -- Optional clock timestamp override for deterministic tests.
	@return number -- Elapsed seconds since FrameStartClock.
]=]
function ResourceController.UpdateWhereInFrame(NowClockOverride: number?): number
	const CurrentClock = (NowClockOverride or os.clock()) :: number
	const Elapsed = math.max(0, CurrentClock - SingletonState.FrameStartClock) :: number
	SingletonState.WhereInFrame = Elapsed
	return Elapsed
end

--[=[
	Records measured physics execution time feedback for the closed-loop controller.
	@param ElapsedSeconds number -- Physics frame execution duration in seconds.
]=]
function ResourceController.ReportPhysicsFeedback(ElapsedSeconds: number)
	SingletonState.Feedback.PhysicsFrameTime = math.max(0, ElapsedSeconds)
	SingletonState.WhereInFrame = math.max(0, os.clock() - SingletonState.FrameStartClock)
end

--[=[
	Records measured renderer execution time feedback for the closed-loop controller.
	@param ElapsedSeconds number -- Renderer frame execution duration in seconds.
]=]
function ResourceController.ReportRendererFeedback(ElapsedSeconds: number)
	SingletonState.Feedback.RendererFrameTime = math.max(0, ElapsedSeconds)
	SingletonState.WhereInFrame = math.max(0, os.clock() - SingletonState.FrameStartClock)
end

--[=[
	Steps the internal-model + ceiling-locked feedback equations for a completed frame duration,
	reserving 2ms of free spike time and locking scores at steady equilibrium without hunting.
	@param TotalFrameDeltaTime number -- Observed total frame duration in seconds.
]=]
function ResourceController.StepController(TotalFrameDeltaTime: number)
	const TargetDt = SingletonState.TargetFrameTime :: number
	const SafeTotalDt = if TotalFrameDeltaTime > 0 then TotalFrameDeltaTime else TargetDt :: number
	const PhysTime = SingletonState.Feedback.PhysicsFrameTime :: number
	const RendTime = SingletonState.Feedback.RendererFrameTime :: number

	const OtherTime: number, OtherMinusTarget: number, RendBudget: number, PhysBudget: number =
		ControllerTheoryMath.ComputeBudgetAllocation(
			SafeTotalDt,
			PhysTime,
			RendTime,
			SingletonState.WhereInFrame,
			TargetDt,
			SingletonState.Weights.Renderer,
			SingletonState.Weights.Physics,
			SingletonState.FreeTimeReserve
		)

	const EffectiveSpan = math.max(SafeTotalDt, SingletonState.WhereInFrame) :: number
	SingletonState.TotalFrameTime = SafeTotalDt
	SingletonState.FreeFrameTime = math.max(0, TargetDt - EffectiveSpan)
	SingletonState.OtherSystemsFrameTime = OtherTime
	SingletonState.OtherMinusTargetFrameTime = OtherMinusTarget
	SingletonState.RendererBudget = RendBudget
	SingletonState.PhysicsBudget = PhysBudget

	ControllerTheoryMath.StepChannel(RendererChannelState, RendBudget, RendTime, TargetDt)
	ControllerTheoryMath.StepChannel(PhysicsChannelState, PhysBudget, PhysTime, TargetDt)

	SingletonState.RawScores.Renderer = RendererChannelState.RawScore
	SingletonState.Scores.Renderer = RendererChannelState.Score
	SingletonState.CeilingScores.Renderer = RendererChannelState.CeilingScore
	SingletonState.PreviousErrors.Renderer = RendererChannelState.PreviousError

	SingletonState.RawScores.Physics = PhysicsChannelState.RawScore
	SingletonState.Scores.Physics = PhysicsChannelState.Score
	SingletonState.CeilingScores.Physics = PhysicsChannelState.CeilingScore
	SingletonState.PreviousErrors.Physics = PhysicsChannelState.PreviousError
	SingletonState.FrameTick += 1
end

--[=[
	Marks the start of active execution for the incoming frame so WhereInFrame measures true intra-frame progress.
	@param TotalFrameDeltaTime number? -- Optional explicit frame duration to step immediately.
]=]
function ResourceController.BeginFrame(TotalFrameDeltaTime: number?)
	const NowClock = os.clock() :: number
	if TotalFrameDeltaTime ~= nil then
		const MeasuredSpan = math.max(0, NowClock - SingletonState.FrameStartClock) :: number
		SingletonState.WhereInFrame = MeasuredSpan
		ResourceController.StepController(TotalFrameDeltaTime)
	end
	SingletonState.FrameStartClock = NowClock
	SingletonState.WhereInFrame = 0
end

--[=[
	Completes active frame execution, separating real active CPU work and <60 FPS frame stalls
	from idle 60 Hz VSync wait time inside RenderStepped before stepping the controller.
	@param SchedulerDeltaTime number -- Raw RenderStepped DeltaTime in seconds.
]=]
function ResourceController.EndFrame(SchedulerDeltaTime: number)
	const ActiveLoopSpan = math.max(0, os.clock() - SingletonState.FrameStartClock) :: number
	SingletonState.WhereInFrame = ActiveLoopSpan
	const ManagedWork = (SingletonState.Feedback.PhysicsFrameTime + SingletonState.Feedback.RendererFrameTime) :: number
	const ActiveFrameWork = math.max(ActiveLoopSpan, ManagedWork) :: number
	const EffectiveFrameTime = ResourceControllerHelper.ResolveEffectiveFrameTime(
		SchedulerDeltaTime,
		ActiveFrameWork,
		SingletonState.TargetFrameTime
	)
	ResourceController.StepController(EffectiveFrameTime)
end

--[=[
	Initializes the singleton controller; on the Server binds Heartbeat to drive closed-loop updates automatically.
]=]
function ResourceController.Initialize()
	if SingletonState.Initialized then
		return
	end
	SingletonState.Initialized = true
	SingletonState.FrameStartClock = os.clock()

	if not IS_CLIENT and not HeartbeatConnection then
		HeartbeatConnection = RunService.Heartbeat:Connect(function(DeltaTime: number)
			const PhysWork = math.max(SingletonState.Feedback.PhysicsFrameTime, 0.0005) :: number
			const EffectiveServerDt = ResourceControllerHelper.ResolveEffectiveFrameTime(
				DeltaTime,
				PhysWork,
				SingletonState.TargetFrameTime
			)
			SingletonState.WhereInFrame = EffectiveServerDt
			ResourceController.StepController(EffectiveServerDt)
			SingletonState.FrameStartClock = os.clock()
			SingletonState.WhereInFrame = 0
		end)
	end
end

--[=[
	Returns the current 1..100 resource allocation score for the Renderer.
	@return number -- Integer score in [1, 100].
]=]
function ResourceController.GetRendererScore(): number
	return SingletonState.Scores.Renderer
end

--[=[
	Returns the current 1..100 resource allocation score for Physics.
	@return number -- Integer score in [1, 100].
]=]
function ResourceController.GetPhysicsScore(): number
	return SingletonState.Scores.Physics
end

--[=[
	Updates runtime resource weights on the singleton controller (normalized to sum to 1.0).
	@param RendererWeight number -- Desired renderer weight.
	@param PhysicsWeight number -- Desired physics weight.
]=]
function ResourceController.SetWeights(RendererWeight: number, PhysicsWeight: number)
	if
		RendererWeight ~= RendererWeight
		or PhysicsWeight ~= PhysicsWeight
		or math.abs(RendererWeight) == math.huge
		or math.abs(PhysicsWeight) == math.huge
	then
		return
	end
	const ClampedR = math.max(0, RendererWeight) :: number
	const ClampedP = math.max(0, PhysicsWeight) :: number
	const WeightSum = ClampedR + ClampedP :: number
	if WeightSum <= 1e-6 then
		return
	end
	SingletonState.Weights.Renderer = ClampedR / WeightSum
	SingletonState.Weights.Physics = ClampedP / WeightSum
end

--[=[
	Restores all singleton controller scores, ceilings, weights, and timing accumulators to defaults.
]=]
function ResourceController.Reset()
	SingletonState.Weights.Renderer = DEFAULT_RENDERER_WEIGHT
	SingletonState.Weights.Physics = DEFAULT_PHYSICS_WEIGHT
	SingletonState.Scores.Renderer = INITIAL_SCORE
	SingletonState.Scores.Physics = INITIAL_SCORE
	SingletonState.RawScores.Renderer = INITIAL_SCORE
	SingletonState.RawScores.Physics = INITIAL_SCORE
	SingletonState.CeilingScores.Renderer = INITIAL_SCORE
	SingletonState.CeilingScores.Physics = INITIAL_SCORE
	SingletonState.Feedback.RendererFrameTime = 0
	SingletonState.Feedback.PhysicsFrameTime = 0
	SingletonState.PreviousErrors.Renderer = 0
	SingletonState.PreviousErrors.Physics = 0
	ResourceControllerHelper.ResetChannelState(RendererChannelState)
	ResourceControllerHelper.ResetChannelState(PhysicsChannelState)
	SingletonState.TargetFrameTime = TARGET_FRAME_TIME
	SingletonState.FreeTimeReserve = FREE_TIME_RESERVE
	SingletonState.FreeFrameTime = TARGET_FRAME_TIME
	SingletonState.FrameStartClock = os.clock()
	SingletonState.WhereInFrame = 0
	SingletonState.TotalFrameTime = TARGET_FRAME_TIME
	SingletonState.OtherSystemsFrameTime = 0
	SingletonState.OtherMinusTargetFrameTime = -USABLE_FRAME_TIME
	SingletonState.RendererBudget = DEFAULT_RENDERER_WEIGHT * USABLE_FRAME_TIME
	SingletonState.PhysicsBudget = DEFAULT_PHYSICS_WEIGHT * USABLE_FRAME_TIME
	SingletonState.FrameTick = 0
end

return ResourceController
