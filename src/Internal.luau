local AutoSave = require(script.Parent.AutoSave)
local Collection = require(script.Parent.Collection)
local Config = require(script.Parent.Config)
local Data = require(script.Parent.Data)

local Internal = {}

function Internal.new(enableAutoSave)
	local config = Config.new()
	local data = Data.new(config)
	local autoSave = AutoSave.new(data)

	if enableAutoSave then
		autoSave:start()
	end

	local usedCollections = {}

	local internal = {}

	if not enableAutoSave then
		-- This exposes AutoSave to unit tests.
		internal.autoSave = autoSave
	end

	function internal.setConfig(values)
		config:set(values)
	end

	function internal.createCollection(name, options)
		if usedCollections[name] then
			error(`Collection "{name}" already exists`)
		end

		usedCollections[name] = true

		return Collection.new(name, options, data, autoSave, config)
	end

	return internal
end

return Internal
