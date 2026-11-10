local Queue = {}

Queue.PlayerQueue = {} -- Every frame must get cleaned
Queue.ObjectQueue = buffer.create() -- you may create more variables like direction and all that, i dont know much about physics but more buffers can get created
-- you should optimize for performance,
-- Playermovements, and all that get made here

-- Should have inertia and weight and acceleration
-- Avoid whats arcade-y and floaty

function Queue.AddMovement() end

return Queue
