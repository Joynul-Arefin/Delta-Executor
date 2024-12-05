local Migration = {}

function Migration.getLastCompatibleVersion(migrations)
	local serverVersion = #migrations

	for version = serverVersion, 1, -1 do
		local migration = migrations[version]

		if migration.backwardsCompatible ~= true then
			return version
		end
	end

	return 0
end

function Migration.migrate(migrations, value)
	local serverVersion = #migrations
	local savedVersion = value.migrationVersion

	local data = value.data
	local lastCompatibleVersion = value.lastCompatibleVersion

	if serverVersion > savedVersion then
		for version = savedVersion + 1, #migrations do
			local ok, migrated = pcall(migrations[version].migrate, data)
			if not ok then
				return false, `Migration {version} threw an error: {migrated}`
			end

			if migrated == nil then
				return false, `Migration {version} returned 'nil'`
			end

			data = migrated
		end

		lastCompatibleVersion = Migration.getLastCompatibleVersion(migrations)
	elseif serverVersion < savedVersion then
		-- lastCompatibleVersion will be nil for documents that existed before backwards compatibilty was added and haven't been migrated to a new version since.
		if lastCompatibleVersion == nil or serverVersion < lastCompatibleVersion then
			return false,
				`Saved migration version {savedVersion} is not backwards compatible with version {serverVersion}`
		end
	end

	return true, data, lastCompatibleVersion
end

return Migration
