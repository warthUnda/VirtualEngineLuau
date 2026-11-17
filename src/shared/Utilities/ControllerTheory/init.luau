--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheory
	Public subsystem facade exposing the singleton ResourceController, ControllerInterpreter,
	and ControllerTheoryMath for both Server and Client environments.
]=]

-- Static References --
const CoreFolder = script:WaitForChild("Core")
const ControllerFolder = script:WaitForChild("Controller")

-- Libraries --
const ControllerInterpreter = require(CoreFolder:WaitForChild("ControllerInterpreter"))
const ControllerTheoryMath = require(CoreFolder:WaitForChild("ControllerTheoryMath"))
const ResourceController = require(ControllerFolder:WaitForChild("ResourceController"))

-- Tables --
local ControllerTheory = {
	State = ResourceController.State,
	ResourceController = ResourceController,
	ControllerInterpreter = ControllerInterpreter,
	ControllerTheoryMath = ControllerTheoryMath,
	Initialize = ResourceController.Initialize,
	BeginFrame = ResourceController.BeginFrame,
	EndFrame = ResourceController.EndFrame,
	StepController = ResourceController.StepController,
	UpdateWhereInFrame = ResourceController.UpdateWhereInFrame,
	ReportPhysicsFeedback = ResourceController.ReportPhysicsFeedback,
	ReportRendererFeedback = ResourceController.ReportRendererFeedback,
	GetRendererScore = ResourceController.GetRendererScore,
	GetPhysicsScore = ResourceController.GetPhysicsScore,
	SetWeights = ResourceController.SetWeights,
	Reset = ResourceController.Reset,
}

return ControllerTheory
