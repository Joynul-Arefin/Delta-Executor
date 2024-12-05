local Error = require(script.Parent.Error)
local freezeDeep = require(script.Parent.freezeDeep)
local Promise = require(script.Parent.Parent.Promise)
local noYield = require(script.Parent.noYield)

local function runCallback(document, name, callback)
	if callback == nil then
		return Promise.resolve()
	end

	document.callingCallback = name

	return Promise.new(function(resolve, reject)
		local ok, message = pcall(noYield, callback)

		document.callingCallback = nil

		if not ok then
			reject(Error.new("BeforeSaveCloseCallbackThrew", `{name} callback threw error: {message}`))
		else
			resolve()
		end
	end)
end

--[=[
	@class Document
]=]
local Document = {}
Document.__index = Document

function Document.new(collection, key, validate, lockId, data, keyInfo)
	return setmetatable({
		collection = collection,
		key = key,
		validate = validate,
		lockId = lockId,
		data = data,
		userIds = keyInfo:GetUserIds(),
		lastKeyInfo = keyInfo,
		closed = false,
	}, Document)
end

--[=[
	Returns the document's data.

	@return any
]=]
function Document:read()
	return self.data
end

--[=[
	Updates the document's cached data. This method doesn't save the data to the DataStore; it only modifies the
	document's in-memory data.

	This method should be used when performing immutable updates to the document's data. For mutable updates, the data
	can be directly modified:
	```lua
	local data = document:read()
	data.coins += 100
	```

	:::warning
	Throws an error if the document was closed or if the data is invalid.
	:::

	@param data any
]=]
function Document:write(data)
	assert(not self.closed, "Cannot write to a closed document")

	if self.validate ~= nil then
		assert(self.validate(data))
	end

	if self.collection.options.freezeData then
		freezeDeep(data)
	end

	self.data = data
end

--[=[
	Adds a user id to the document's `DataStoreKeyInfo:GetUserIds()`. The change won't apply until the document is
	saved or closed.

	If the user id is already associated with the document the method won't do anything.

	@param userId number
]=]
function Document:addUserId(userId)
	assert(not self.closed, "Cannot add user id to a closed document")

	if table.find(self.userIds, userId) == nil then
		table.insert(self.userIds, userId)
	end
end

--[=[
	Removes a user id from the document's `DataStoreKeyInfo:GetUserIds()`. The change won't apply until the document is
	saved or closed.

	If the user id is not associated with the document the method won't do anything.

	@param userId number
]=]
function Document:removeUserId(userId)
	assert(not self.closed, "Cannot remove user id from a closed document")

	local index = table.find(self.userIds, userId)

	if index ~= nil then
		table.remove(self.userIds, index)
	end
end

--[=[
	Returns the last updated `DataStoreKeyInfo` returned from loading, saving, or closing the document.

	@return DataStoreKeyInfo
]=]
function Document:keyInfo()
	return self.lastKeyInfo
end

--[=[
	Saves the document's data. If the save is throttled and you call it multiple times, it will save only once with the
	latest data.

	Documents are saved automatically. This method is used mainly to handle developer product purchases
	(see the [example](../docs/DeveloperProduct)) or other situations requiring immediate saving.

	:::warning
	Throws an error if the document was closed.
	:::

	:::warning
	If the beforeSave callback yields or errors, the returned promise will reject and the data will not be saved.
	:::

	@return Promise<()>
]=]
function Document:save()
	assert(not self.closed, "Cannot save a closed document")
	assert(self.callingCallback == nil, `Cannot save in {self.callingCallback} callback`)

	return runCallback(self, "beforeSave", self.beforeSaveCallback)
		:andThen(function()
			return self.collection.data
				:save(self.collection.dataStore, self.key, function(value, keyInfo)
					if value == nil then
						return "fail", Error.new("DocumentRemoved", "The document was removed")
					end

					if value.lockId ~= self.lockId then
						return "fail", Error.new("SessionLockStolen", "The session lock was stolen")
					end

					if not self.collection.options.freezeData and self.validate ~= nil then
						local validateOk, valid, message = pcall(self.validate, self.data)
						if not validateOk then
							return "fail", Error.new("ValidateThrew", `'validate' threw an error: {valid}`)
						elseif not valid then
							return "fail", Error.new("ValidateFailed", `Invalid data: {message}`)
						end
					end

					value.data = self.data

					return "succeed", value, self.userIds, keyInfo:GetMetadata()
				end)
				:andThen(function(_, keyInfo)
					self.lastKeyInfo = keyInfo
				end)
		end)
		:catch(function(err)
			return Promise.reject(`DataStoreFailure({err.message})`)
		end)
end

--[=[
	Saves the document and removes the session lock. The document is unusable after calling. If a save is currently in
	progress it will close the document instead.

	If called again, it will return the promise from the original call.

	:::warning
	If the beforeSave or beforeClose callbacks yield or error, the returned promise will reject and the data will not be saved.
	:::

	@return Promise<()>
]=]
function Document:close()
	assert(self.callingCallback == nil, `Cannot close in {self.callingCallback} callback`)

	if self.closePromise == nil then
		self.closePromise = runCallback(self, "beforeSave", self.beforeSaveCallback)
			:andThenCall(runCallback, self, "beforeClose", self.beforeCloseCallback)
			:finally(function()
				self.closed = true

				self.collection.autoSave:removeDocument(self)
			end)
			:andThen(function()
				return self.collection.data:save(self.collection.dataStore, self.key, function(value, keyInfo)
					if value == nil then
						return "fail", Error.new("DocumentRemoved", "The document was removed")
					end

					if value.lockId ~= self.lockId then
						return "fail", Error.new("SessionLockStolen", "The session lock was stolen")
					end

					if not self.collection.options.freezeData and self.validate ~= nil then
						local validateOk, valid, message = pcall(self.validate, self.data)
						if not validateOk then
							return "fail", Error.new("ValidateThrew", `'validate' threw an error: {valid}`)
						elseif not valid then
							return "fail", Error.new("ValidateFailed", `Invalid data: {message}`)
						end
					end

					value.data = self.data
					value.lockId = nil

					return "succeed", value, self.userIds, keyInfo:GetMetadata()
				end)
			end)
			:andThen(function(_, keyInfo)
				self.lastKeyInfo = keyInfo
			end)
			:catch(function(err)
				if
					err.kind == "BeforeSaveCloseCallbackThrew"
					or err.kind == "ValidateThrew"
					or err.kind == "ValidateFailed"
				then
					self.collection.autoSave.ongoingRemoveLocks += 1

					self.collection.data
						:removeLock(self.collection.dataStore, self.key, self.lockId)
						:catch(function(removeLockErr)
							warn(`RemoveLockFailure({removeLockErr.message})`)
						end)
						:finally(function()
							self.collection.autoSave.ongoingRemoveLocks -= 1
						end)
				end

				return Promise.reject(`DataStoreFailure({err.message})`)
			end)
	end

	return self.closePromise
end

--[=[
	Sets a callback that is run inside `document:save` and `document:close` before it saves. The document can be read and written to in the
	callback.

	The callback will run before the beforeClose callback inside of `document:close`.

	:::warning
	Throws an error if it was called previously.
	:::

	@param callback () -> ()
]=]
function Document:beforeSave(callback)
	assert(self.beforeSaveCallback == nil, "Document:beforeSave can only be called once")

	self.beforeSaveCallback = callback
end

--[=[
	Sets a callback that is run inside `document:close` before it saves. The document can be read and written to in the
	callback.

	:::warning
	Throws an error if it was called previously.
	:::

	@param callback () -> ()
]=]
function Document:beforeClose(callback)
	assert(self.beforeCloseCallback == nil, "Document:beforeClose can only be called once")

	self.beforeCloseCallback = callback
end

return Document
