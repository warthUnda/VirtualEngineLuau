local ParralelModule = {}

local RenderParralelTemplate = game.ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Utilities")
	:WaitForChild("RenderParralelTemplate") :: Folder

function ParralelModule.CreateSetup()
	local StarterPlayerScripts = game.StarterPlayer:WaitForChild("StarterPlayerScripts")

	local ParallelFolder = Instance.new("Folder")
	ParallelFolder.Name = "RenderParralel"
	ParallelFolder.Parent = StarterPlayerScripts

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
