--!strict
--!native
--!optimize 2

local PlayerService = {}
PlayerService.__index = PlayerService

-- 3 reasons are why i should manually code here in assistance of ai of course

-- 1. to maintain my code muscle
-- 2. To make it actually be useable and perfected as i need to juggle trade offs in the abstractions and performance 
-- 3. i need to understand the core here so that i can later move better and think more, simple words: i should understand this system here more

--[=[
	Creates a new PlayerService wrapper for the specified player.
	@param PlayerInstance Player -- Target player instance.
	@return table
]=]
function PlayerService.New(PlayerInstance: Player)
	local self = setmetatable({}, PlayerService)

	return self
end

return PlayerService
