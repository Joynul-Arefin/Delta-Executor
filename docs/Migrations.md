---
sidebar_position: 3
---

# Migrations

## Writing Migrations
Migrations allow you to update the structure of your data over time. You can add new keys, remove ones you no longer need, or change the way you store something.

Here is an example of a few migrations:
```lua
local MIGRATIONS = {
    -- Migrate from version 0 to 1.
    function(old)
        return Dictionary.merge(old, {
            coins = 0, -- Add a key called coins to the data.
        })
    end,
    -- Migrate from version 1 to 2.
    function(old)
        -- We no longer need the playTime key, so we remove it.
        -- Note: Migrations can update the data mutably but you still need to return the value.
        old.playTime = nil

        return old
    end,
}

local collection = Lapis.createCollection("collection", {
    migrations = MIGRATIONS,
    validate = validate,
    defaultData = DEFAULT_DATA,
})
```

## Backwards Compatibility
If you release an update that includes a migration, a player might join a new server, leave, and then join an old server.
This would cause the player's document to fail to load on the old server since the document's version would be ahead of the old server's version.

To solve this problem, you have two options:
1. Use Roblox's `Migrate To Latest Update` feature to ensure all servers are up-to-date.
2. Make your migrations backwards compatible.

Here's an example of how to make migrations backwards compatible:
```lua
local function v1()
    -- v1 removes a key which causes an error on servers with version 0.
    old.playTime = nil
    return old
end

local function v2()
    -- v2 adds a new value to the player's data which won't result in an error on servers with version 1.
    old.items = {}
    return old
end

local function v3()
    -- v3 removes a key which causes an error on servers with version 0, 1, or 2.
    old.coins = nil
    return old
end

local MIGRATIONS = {
    {
        migrate = v1,
        backwardsCompatible = false, -- Version 1 isn't backwards compatible with version 0.
    },
    {
        migrate = v2,
        backwardsCompatible = true, -- Version 2 is backwards compatible with version 1.
    },
    v3, -- Migrations aren't backwards compatible by default.
}
```

A migration is backwards compatible with the previous version if it can be safely loaded on an old server without resulting in bugs, errors, or incorrect behavior.

Generally, additive changes are backwards compatible, while removals are not. It's up to you to determine when a change is backwards compatible.

Backward compatibility is transitive, so for example, if `v2` is backwards compatible with `v1` and `v3` is backwards compatible with `v2`, `v3` is also backwards compatible with `v1`.

Note that a migration won't be backwards compatible if it fails to pass the previous version's validation. If you intend to
use backwards compatibilty, you should use functions like `t.interface` over `t.strictInterface`.

### How to fix mistakes in backwards compatibilty?
If you mistakenly mark a change as backwards compatible when it isn't, you will need to use `Migrate To Latest Update` to correct it. Therefore, be careful not to mark `backwardsCompatible` incorrectly!
