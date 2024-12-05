---
sidebar_position: 2
---

# Example Usage
The following code is an example of how you would load and close player data:
```lua
local DEFAULT_DATA = { coins = 100 }

local collection = Lapis.createCollection("PlayerData", {
	defaultData = DEFAULT_DATA,
	-- You can use t by osyrisrblx to type check your data at runtime.
	validate = t.strictInterface({ coins = t.integer }),
})

local documents = {}

local function onPlayerAdded(player: Player)
	-- The second argument associates the document with the player's UserId which is useful
	-- for GDPR compliance.
	collection
		:load(`Player{player.UserId}`, { player.UserId })
		:andThen(function(document)
			if player.Parent == nil then
				-- The player might have left before the document finished loading.
				-- The document needs to be closed because PlayerRemoving won't fire at this point.
				document:close():catch(warn)
				return
			end

			documents[player] = document
		end)
		:catch(function(message)
			warn(`Player {player.Name}'s data failed to load: {message}`)

			-- Optionally, you can kick the player when their data fails to load:
			player:Kick("Data failed to load.")
		end)
end

local function onPlayerRemoving(player: Player)
	local document = documents[player]

	-- The document won't be added to the dictionary if PlayerRemoving fires bofore it finishes loading.
	if document ~= nil then
		documents[player] = nil
		document:close():catch(warn)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
```
:::info
You do not need to handle `game:BindToClose` or auto saving. Lapis automatically does both of those.
:::