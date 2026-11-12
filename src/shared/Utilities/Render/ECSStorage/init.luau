--!strict
--!native
--!optimize 2

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules --
const ECSMain = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ECSMain"))

return ECSMain.CreateStorage(false)
