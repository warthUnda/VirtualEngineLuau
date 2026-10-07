local ParralelModule = {}

local RenderParralelTemplate = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("RenderParralelTemplate") :: Folder

local ControllerTemplate = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("Render")
	:WaitForChild("ControllerActor")

function ParralelModule.CreateSetup()
	local StarterPlayerScripts = game.StarterPlayer:WaitForChild("StarterPlayerScripts")

	local ParallelFolder = Instance.new("Folder")
	ParallelFolder.Name = "RenderParralel"
	ParallelFolder.Parent = StarterPlayerScripts

	local ControllerFolder = Instance.new("Folder")
	ControllerFolder.Parent = StarterPlayerScripts
	local ControllerActor = Instance.new("Actor")

	ControllerActor.Name = "Controller"
	ControllerActor.Parent = ControllerFolder

	local ControllerScript = ControllerTemplate:Clone()
	ControllerScript.Name = "ControllerScript"
	ControllerScript.Parent = ControllerActor

	for i = 1, 6 do
		local NewActor = Instance.new("Actor")
		NewActor.Parent = ParallelFolder
		NewActor.Name = "ParallelSetup" .. i

		local NewRenderTemplate = RenderParralelTemplate:Clone()
		NewRenderTemplate.Name = "ParallelRender" .. i
		NewRenderTemplate.Parent = NewActor
	end
end

return ParralelModule
