type ErrorKind =
	"RobloxApiError"
	| "DefaultDataThrew"
	| "SessionLocked"
	| "MigrationError"
	| "BeforeSaveCloseCallbackThrew"
	| "DocumentRemoved"
	| "SessionLockStolen"
	| "ValidateThrew"
	| "ValidateFailed"

local Error = {}

function Error.new(kind: ErrorKind, message: string)
	return {
		kind = kind,
		message = message,
	}
end

return Error
