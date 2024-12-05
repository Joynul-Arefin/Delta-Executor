local HttpService = game:GetService("HttpService")

local Document = require(script.Parent.Document)
local Error = require(script.Parent.Error)
local freezeDeep = require(script.Parent.freezeDeep)
local Migration = require(script.Parent.Migration)
local Promise = require(script.Parent.Parent.Promise)
local copyDeep = require(script.Parent.copyDeep)

local LOCK_EXPIRE = 30 * 60

--[=[
	Collections are analagous to [GlobalDataStore].

	@class Collection
]=]
local Collection = {}
Collection.__index = Collection

function Collection.new(name, options, data, autoSave, config)
	if typeof(options.defaultData) ~= "function" and options.validate ~= nil then
		assert(options.validate(options.defaultData))
	end

	local migrations = {}
	if options.migrations ~= nil then
		for _, migration in options.migrations do
			if typeof(migration) == "function" then
				table.insert(migrations, { migrate = migration })
			else
				table.insert(migrations, migration)
			end
		end
	end
	options.migrations = migrations

	options.freezeData = if options.freezeData ~= nil then options.freezeData else true

	freezeDeep(options)

	return setmetatable({
		dataStore = config:get("dataStoreService"):GetDataStore(name),
		options = options,
		data = data,
		autoSave = autoSave,
	}, Collection)
end

--[=[
	Loads the document with `key`, migrates it, and session locks it.

	If specified, the document's `DataStoreKeyInfo:GetUserIds()` will be set to `defaultUserIds` if the document has
	never been loaded.

	@param key string
	@param defaultUserIds {number}?
	@return Promise<Document>
]=]
function Collection:load(key, defaultUserIds)
	if self.autoSave.gameClosed then
		-- If game:BindToClose has been called, this infinitely yields so the document can't load.
		return Promise.new(function() end)
	end

	local lockId = HttpService:GenerateGUID(false)

	self.autoSave.ongoingLoads += 1

	return self.data
		:load(self.dataStore, key, function(value, keyInfo)
			if value == nil then
				local defaultData
				if typeof(self.options.defaultData) == "function" then
					local defaultOk, tailoredDefaultData = pcall(self.options.defaultData, key)
					if not defaultOk then
						return "fail",
							Error.new("DefaultDataThrew", `'defaultData' threw an error: {tailoredDefaultData}`)
					end

					if self.options.validate ~= nil then
						local validateOk, valid, message = pcall(self.options.validate, tailoredDefaultData)
						if not validateOk then
							return "fail", Error.new("ValidateThrew", `'validate' threw an error: {valid}`)
						elseif not valid then
							return "fail", Error.new("ValidateFailed", `Invalid data: {message}`)
						end
					end

					defaultData = copyDeep(tailoredDefaultData)
				else
					-- The data was validated when the collection was created.
					defaultData = if self.options.freezeData
						then self.options.defaultData
						else copyDeep(self.options.defaultData)
				end

				local data = {
					migrationVersion = #self.options.migrations,
					lastCompatibleVersion = Migration.getLastCompatibleVersion(self.options.migrations),
					lockId = lockId,
					data = defaultData,
				}

				return "succeed", data, defaultUserIds
			end

			if
				value.lockId ~= nil
				and (DateTime.now().UnixTimestampMillis - keyInfo.UpdatedTime) / 1000 < LOCK_EXPIRE
			then
				return "retry", Error.new("SessionLocked", "Could not acquire lock")
			end

			local savedVersion = value.migrationVersion

			local migrationOk, migrated, lastCompatibleVersion = Migration.migrate(self.options.migrations, value)
			if not migrationOk then
				return "fail", Error.new("MigrationError", migrated)
			end

			if self.options.validate ~= nil then
				local validateOk, valid, message = pcall(self.options.validate, migrated)
				if not validateOk then
					return "fail", Error.new("ValidateThrew", `'validate' threw an error: {valid}`)
				elseif not valid then
					return "fail", Error.new("ValidateFailed", `Invalid data: {message}`)
				end
			end

			local data = {
				migrationVersion = math.max(savedVersion, #self.options.migrations),
				lastCompatibleVersion = lastCompatibleVersion,
				lockId = lockId,
				data = migrated,
			}

			return "succeed", data, keyInfo:GetUserIds(), keyInfo:GetMetadata()
		end)
		:andThen(function(value, keyInfo)
			if value == "cancelled" then
				self.autoSave.ongoingLoads -= 1

				-- Infinitely yield because the load was cancelled by game:BindToClose.
				return Promise.new(function() end)
			end

			local data = value.data

			if self.options.freezeData then
				freezeDeep(data)
			end

			local document = Document.new(self, key, self.options.validate, lockId, data, keyInfo)

			self.autoSave:finishLoad(document)

			if self.autoSave.gameClosed then
				-- Infinitely yield because the document will automatically be closed.
				return Promise.new(function() end)
			end

			self.autoSave:addDocument(document)

			return document
		end)
		:catch(function(err)
			self.autoSave.ongoingLoads -= 1

			return Promise.reject(`DataStoreFailure({err.message})`)
		end)
end

--[=[
	Reads the data of the document with `key` regardless of whether it is session locked. This is useful for viewing a
	document without editing or session locking it. The data gets migrated but not saved.

	If the document has never been loaded, the promise will return `nil`.

	[DataStoreGetOptions.UseCache](https://create.roblox.com/docs/reference/engine/classes/DataStoreGetOptions#UseCache) is disabled.

	@param key string
	@return Promise<T?>
]=]
function Collection:read(key)
	return self.data:read(self.dataStore, key):andThen(function(value, keyInfo)
		if value == nil then
			return nil
		end

		local migrationOk, migrated = Migration.migrate(self.options.migrations, value)
		if not migrationOk then
			return Promise.reject(migrated)
		end

		if self.options.validate ~= nil then
			local validateOk, valid, message = pcall(self.options.validate, migrated)
			if not validateOk then
				return Promise.reject(`'validate' threw an error: {valid}`)
			elseif not valid then
				return Promise.reject(`Invalid data: {message}`)
			end
		end

		return value.data, keyInfo
	end)
end

--[=[
	Removes the data of the document with `key`.

	If a document is open while `remove` is called, the open document will fail to save/close and the data will still be removed.

	@param key string
	@return Promise<()>
]=]
function Collection:remove(key)
	return self.data:remove(self.dataStore, key)
end

return Collection
