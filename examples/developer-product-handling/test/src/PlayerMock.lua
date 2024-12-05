local Players = game:GetService("Players")

local Player = {}
Player.__index = Player

function Player.new(userId)
	return setmetatable({
		UserId = userId,
		Parent = Players,
	}, Player)
end

return Player
