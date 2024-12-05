local DataStoreService = game:GetService("DataStoreService")

local Config = {}
Config.__index = Config

function Config.new()
	return setmetatable({
		config = {
			saveAttempts = 5,
			loadAttempts = 20,
			loadRetryDelay = 1,
			showRetryWarnings = true,
			dataStoreService = DataStoreService,
		},
	}, Config)
end

function Config:get(key)
	return self.config[key]
end

function Config:set(values)
	for key, value in values do
		if self.config[key] == nil then
			error(`Invalid config key "{tostring(key)}"`)
		end

		self.config[key] = value
	end
end

return Config
