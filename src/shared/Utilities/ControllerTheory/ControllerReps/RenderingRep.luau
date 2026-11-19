--!strict
--!native
--!optimize 2

--[=[
	@class RenderingRep
	System representative for Software Rendering inside ControllerTheory.
	Owns Renderer score/feedback binding, area-fraction plant curve mapping, and
	area-proportional viewport resolution interpretation.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ControllerTheoryRoot = script.Parent.Parent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ControllerTheoryMath = require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))
const ResourceController = require(ControllerTheoryRoot:WaitForChild("Controller"):WaitForChild("ResourceController"))

-- Configs --
const CHANNEL_NAME = "Renderer" :: string
const MIN_SCORE = SystemsConfigs.ControllerMinScore :: number
const MAX_SCORE = SystemsConfigs.ControllerMaxScore :: number
const MIN_RES_SCALE = SystemsConfigs.ControllerMinResolutionScale :: number
const MIN_AREA_FRACTION = MIN_RES_SCALE * MIN_RES_SCALE :: number
const RES_STEP = math.max(1, SystemsConfigs.ControllerResolutionStep :: number) :: number
const MIN_VIEWPORT_DIM = SystemsConfigs.ControllerMinViewportDim :: number

-- Tables --
local RenderingRep = {}

-- Functions --
-- ============================================================================
-- 1. RENDERER CHANNEL CURVES, CONTROLLER FEEDBACK & RESOLUTION INTERPRETER
-- ============================================================================

--[=[
	Maps a 1..100 Renderer score to its active pixel area fraction in [MIN_AREA_FRACTION, 1.0].
	@param RawScore number -- Continuous Renderer score in [1, 100].
	@return number -- Active pixel area fraction in (0, 1].
]=]
function RenderingRep.GetLoadFraction(RawScore: number): number
	const Clamped = math.clamp(RawScore, MIN_SCORE, MAX_SCORE) :: number
	const Unit = (Clamped - MIN_SCORE) / (MAX_SCORE - MIN_SCORE) :: number
	return MIN_AREA_FRACTION + (1 - MIN_AREA_FRACTION) * Unit
end

--[=[
	Inverts a target Renderer pixel area fraction back into a continuous 1..100 Renderer score.
	@param LoadFraction number -- Target pixel area fraction.
	@return number -- Continuous Renderer score in [1, 100].
]=]
function RenderingRep.ScoreFromLoadFraction(LoadFraction: number): number
	const ClampedArea = math.clamp(LoadFraction, MIN_AREA_FRACTION, 1.0) :: number
	const Unit = (ClampedArea - MIN_AREA_FRACTION) / (1 - MIN_AREA_FRACTION) :: number
	return MIN_SCORE + (MAX_SCORE - MIN_SCORE) * Unit
end

--[=[
	Returns the current 1..100 ControllerTheory allocation score for the Renderer.
	@return number -- Integer score in [1, 100].
]=]
function RenderingRep.GetScore(): number
	return ResourceController.GetChannelScore(CHANNEL_NAME)
end

--[=[
	Returns the current normalized runtime weight assigned to the Renderer channel.
	@return number -- Runtime Renderer weight in [0, 1].
]=]
function RenderingRep.GetWeight(): number
	return ResourceController.State.Weights.Renderer
end

--[=[
	Reports measured renderer execution duration back into ResourceController.
	@param ElapsedSeconds number -- Measured renderer frame duration in seconds.
]=]
function RenderingRep.ReportFeedback(ElapsedSeconds: number)
	ResourceController.ReportChannelFeedback(CHANNEL_NAME, ElapsedSeconds)
end

--[=[
	Converts the current (or overridden) 1..100 renderer score into area-proportional scaled viewport
	dimensions so total rasterized pixel count scales linearly with the controller's score.
	@param BaseWidth number -- Native 100% viewport width in pixels.
	@param BaseHeight number -- Native 100% viewport height in pixels.
	@param ScoreOverride number? -- Optional explicit 1..100 score (defaults to RenderingRep.GetScore()).
	@return (number, number, number) -- (ScaledWidth, ScaledHeight, LinearScale).
]=]
function RenderingRep.Interpret(
	BaseWidth: number,
	BaseHeight: number,
	ScoreOverride: number?
): (number, number, number)
	const TargetScore = if ScoreOverride ~= nil then ScoreOverride else ResourceController.GetChannelScore(CHANNEL_NAME) :: number
	const ClampedScore = ControllerTheoryMath.ClampScore(TargetScore) :: number
	if ClampedScore >= 100 then
		return BaseWidth, BaseHeight, 1.0
	end

	const NormalizedUnit = (ClampedScore - MIN_SCORE) / (MAX_SCORE - MIN_SCORE) :: number
	const AreaFraction = MIN_AREA_FRACTION + (1 - MIN_AREA_FRACTION) * NormalizedUnit :: number
	const LinearScale = math.sqrt(AreaFraction) :: number

	const FloorWidth = math.min(BaseWidth, MIN_VIEWPORT_DIM) :: number
	const FloorHeight = math.min(BaseHeight, MIN_VIEWPORT_DIM) :: number
	const QuantizedWidth = math.floor((BaseWidth * LinearScale) / RES_STEP + 0.5) * RES_STEP :: number
	const QuantizedHeight = math.floor((BaseHeight * LinearScale) / RES_STEP + 0.5) * RES_STEP :: number

	const ScaledWidth = math.clamp(QuantizedWidth, FloorWidth, BaseWidth) :: number
	const ScaledHeight = math.clamp(QuantizedHeight, FloorHeight, BaseHeight) :: number
	return ScaledWidth, ScaledHeight, LinearScale
end

ResourceController.BindChannelCurves(CHANNEL_NAME, RenderingRep.GetLoadFraction, RenderingRep.ScoreFromLoadFraction)

return RenderingRep
