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
const CONTROLLER_ENABLED = if SystemsConfigs.ControllerEnabled ~= nil then SystemsConfigs.ControllerEnabled :: boolean else true
const TARGET_FRAME_TIME = SystemsConfigs.ControllerTargetFrameTime :: number
const FREE_TIME_RESERVE = SystemsConfigs.ControllerFreeTimeReserve :: number
const USABLE_FRAME_TIME = math.max(1e-4, TARGET_FRAME_TIME - FREE_TIME_RESERVE) :: number
const DEFAULT_RENDERER_WEIGHT = SystemsConfigs.ControllerRendererWeight :: number
const DEFAULT_PHYSICS_WEIGHT = SystemsConfigs.ControllerPhysicsWeight :: number
const MAX_SCORE = SystemsConfigs.ControllerMaxScore :: number
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
	Enabled: boolean,
	Initialized: boolean,
}

-- Variables --
local HeartbeatConnection: RBXScriptConnection? = nil

-- Tables --
local RendererChannelState = ResourceControllerHelper.CreateChannelState()
local PhysicsChannelState = ResourceControllerHelper.CreateChannelState()

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
	Enabled = CONTROLLER_ENABLED,
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
	Binds system-specific load fraction and inverse score curves from a ControllerRep onto a channel.
	@param ChannelName string -- Channel identifier ("Renderer" or "Physics").
	@param GetLoadFractionFn (number) -> number -- Score-to-load-fraction curve.
	@param ScoreFromLoadFractionFn (number) -> number -- Load-fraction-to-score curve.
]=]
function ResourceController.BindChannelCurves(
	ChannelName: string,
	GetLoadFractionFn: (number) -> number,
	ScoreFromLoadFractionFn: (number) -> number
)
	const TargetChannel = if ChannelName == "Physics" then PhysicsChannelState else RendererChannelState
	TargetChannel.GetLoadFraction = GetLoadFractionFn
	TargetChannel.ScoreFromLoadFraction = ScoreFromLoadFractionFn
end

--[=[
	Records measured frame execution time feedback for a named managed channel.
	@param ChannelName string -- Channel identifier ("Renderer" or "Physics").
	@param ElapsedSeconds number -- Frame execution duration in seconds.
]=]
function ResourceController.ReportChannelFeedback(ChannelName: string, ElapsedSeconds: number)
	if not SingletonState.Enabled then
		return
	end
	const ClampedElapsed = math.max(0, ElapsedSeconds) :: number
	if ChannelName == "Physics" then
		SingletonState.Feedback.PhysicsFrameTime = ClampedElapsed
	else
		SingletonState.Feedback.RendererFrameTime = ClampedElapsed
	end
	SingletonState.WhereInFrame = math.max(0, os.clock() - SingletonState.FrameStartClock)
end

--[=[
	Returns the current 1..100 resource allocation score for a named managed channel.
	@param ChannelName string -- Channel identifier ("Renderer" or "Physics").
	@return number -- Integer score in [1, 100].
]=]
function ResourceController.GetChannelScore(ChannelName: string): number
	if not SingletonState.Enabled then
		return MAX_SCORE
	end
	if ChannelName == "Physics" then
		return SingletonState.Scores.Physics
	end
	return SingletonState.Scores.Renderer
end

--[=[
	Steps the internal-model + ceiling-locked feedback equations for a completed frame duration,
	reserving 2ms of free spike time and locking scores at steady equilibrium without hunting.
	@param TotalFrameDeltaTime number -- Observed total frame duration in seconds.
]=]
function ResourceController.StepController(TotalFrameDeltaTime: number)
	if not SingletonState.Enabled then
		return
	end
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
	if not SingletonState.Enabled then
		return
	end
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
	if not SingletonState.Enabled then
		return
	end
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
	HeartbeatConnection = ResourceControllerHelper.SyncServerHeartbeat(IS_CLIENT, HeartbeatConnection, SingletonState, ResourceController.StepController)
end

--[=[
	Returns whether the closed-loop ResourceController is currently enabled.
	@return boolean -- True when enabled, false when bypassed at max score.
]=]
function ResourceController.IsEnabled(): boolean
	return SingletonState.Enabled
end

--[=[
	Enables or disables the closed-loop ResourceController at runtime.
	When disabled, scores are immediately restored and locked at ControllerMaxScore (100).
	@param Enabled boolean -- Desired enabled state.
]=]
function ResourceController.SetEnabled(Enabled: boolean)
	const NextEnabled = if Enabled then true else false
	if SingletonState.Enabled == NextEnabled then
		return
	end
	SingletonState.Enabled = NextEnabled
	if not NextEnabled then
		ResourceControllerHelper.ApplyScorePreset(SingletonState, MAX_SCORE)
	end
	HeartbeatConnection = ResourceControllerHelper.SyncServerHeartbeat(IS_CLIENT, HeartbeatConnection, SingletonState, ResourceController.StepController)
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
	ResourceControllerHelper.ApplyScorePreset(SingletonState, INITIAL_SCORE)
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
	SingletonState.Enabled = CONTROLLER_ENABLED
	HeartbeatConnection = ResourceControllerHelper.SyncServerHeartbeat(IS_CLIENT, HeartbeatConnection, SingletonState, ResourceController.StepController)
end

return ResourceController
