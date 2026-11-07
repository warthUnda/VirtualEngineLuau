local Player = game:GetService("Players").LocalPlayer

local PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

local RenderBootstrap = require(script.Parent.RenderBootstrap)

RenderBootstrap.CreateSetup()
