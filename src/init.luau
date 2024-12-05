--!strict

local Internal = require(script.Internal)
local PromiseTypes = require(script.PromiseTypes)

local internal = Internal.new(true)

type Migrate = (any) -> any
type Migration = Migrate | { backwardsCompatible: boolean?, migrate: Migrate }

export type DataStoreService = {
	GetDataStore: (name: string) -> GlobalDataStore,
	GetRequestBudgetForRequestType: (requestType: Enum.DataStoreRequestType) -> number,
}

export type PartialLapisConfig = {
	saveAttempts: number?,
	loadAttempts: number?,
	loadRetryDelay: number?,
	showRetryWarnings: boolean?,
	dataStoreService: DataStoreService?,
	[any]: nil,
}

export type CollectionOptions<T> = {
	defaultData: T | (key: string) -> T,
	migrations: { Migration }?,
	validate: ((any) -> (boolean, string?))?,
	freezeData: boolean?,
	[any]: nil,
}

export type Collection<T> = {
	load: (self: Collection<T>, key: string, defaultUserIds: { number }?) -> PromiseTypes.TypedPromise<Document<T>>,
	read: (self: Collection<T>, key: string) -> PromiseTypes.TypedPromise<T?>,
	remove: (self: Collection<T>, key: string) -> PromiseTypes.TypedPromise<()>,
}

export type Document<T> = {
	read: (self: Document<T>) -> T,
	write: (self: Document<T>, T) -> (),
	addUserId: (self: Document<T>, userId: number) -> (),
	removeUserId: (self: Document<T>, userId: number) -> (),
	save: (self: Document<T>) -> PromiseTypes.TypedPromise<()>,
	close: (self: Document<T>) -> PromiseTypes.TypedPromise<()>,
	beforeSave: (self: Document<T>, callback: () -> ()) -> (),
	beforeClose: (self: Document<T>, callback: () -> ()) -> (),
}

--[=[
	@class Lapis
]=]
local Lapis = {}

--[=[
	@interface PartialLapisConfig
	@within Lapis
	.saveAttempts number? -- Max save/close retry attempts
	.loadAttempts number? -- Max load retry attempts
	.loadRetryDelay number? -- Seconds between load attempts
	.showRetryWarnings boolean? -- Show warning on retry
	.dataStoreService (DataStoreService | table)? -- Useful for mocking DataStoreService, especially in a local place
]=]

--[=[
	@type Migration (any) -> any | { backwardsCompatible: boolean?, migrate: (any) -> any }
	@within Lapis
]=]

--[=[
	```lua
	Lapis.setConfig({
		saveAttempts = 10,
		showRetryWarnings = false,
	})
	```

	```lua
	-- The default config values:
	{
		saveAttempts = 5,
		loadAttempts = 20,
		loadRetryDelay = 1,
		showRetryWarnings = true,
		dataStoreService = DataStoreService,
	}
	```

	@param partialConfig PartialLapisConfig
]=]
function Lapis.setConfig(partialConfig: PartialLapisConfig)
	internal.setConfig(partialConfig)
end

--[=[
	@interface CollectionOptions<T>
	@within Lapis
	.validate ((any) -> true | (false, string))? -- Takes a document's data and returns true on success or false and an error on fail.
	.defaultData T | (key: string) -> T -- If set to a function, it's called when a new document is created and is passed the key of the document.
	.freezeData boolean? -- If `true`, data will be deep frozen and can only be updated immutably by calling [`Document:write`](Document#write). Default: `true`
	.migrations { Migration }? -- Migrations take old data and return new data. Order is first to last. For more information, see: [Migrations](../docs/Migrations).
]=]

--[=[
	Creates a [Collection].

	@param name string
	@param options CollectionOptions
	@return Collection
]=]
function Lapis.createCollection<T>(name: string, options: CollectionOptions<T>): Collection<T>
	return internal.createCollection(name, options)
end

return Lapis
