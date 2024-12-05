---
sidebar_position: 1
---

# Introduction

## Features
- **Session Locking** - Documents can only be accessed from one server at a time. This prevents some bugs and duping methods.
- **Validation** - Ensure your data is correct before saving it.
- **Migrations** - Update the structure of your data over time.
- **Retries** - Failed DataStore requests will be retried.
- **Throttling** - DataStore requests will never exceed their budget and throw an error.
- **Promise-based API** - Promises are used instead of yielding.
- **Immutability** - By default, documents are deep frozen must be updated immutably. This can be disabled.
- **Save Batching** - Pending `Document:save()` and `Document:close()` calls are combined into one DataStore request when possible.
- **Auto Save** - Documents are automatically saved every 5 minutes.
- **BindToClose** - All documents are automatically closed when the game shuts down.