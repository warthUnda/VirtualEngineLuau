local Player = game:GetService("Players").LocalPlayer

local PlayerScripts = Player:WaitForChild("PlayerScripts") :: PlayerScripts

local ParralelModule = require(script.Parent.ParralelModule)

ParralelModule.CreateSetup()
