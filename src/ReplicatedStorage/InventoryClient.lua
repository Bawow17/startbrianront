local InventoryClient = {}

local itemChanged = Instance.new("BindableEvent")
InventoryClient.ItemChanged = itemChanged.Event

-- Hook: replace with server-authoritative inventory later if needed.
local items = {}

local function emit(changeType, entry)
    itemChanged:Fire(changeType, entry)
end

function InventoryClient.GetItems()
    return items
end

function InventoryClient.Clear()
    table.clear(items)
    emit("cleared")
end

function InventoryClient.AddItem(name)
    name = tostring(name or "Unknown")
    local entry = items[name]
    if not entry then
        entry = {
            name = name,
            count = 0,
            firstAddedAt = os.clock(),
        }
        items[name] = entry
    end
    entry.count += 1
    entry.lastAddedAt = os.clock()
    emit("added", entry)
    return entry
end

function InventoryClient.RemoveOne(name)
    local entry = items[name]
    if not entry then
        return nil
    end
    entry.count -= 1
    if entry.count <= 0 then
        items[name] = nil
        emit("removed", nil)
        return nil
    end
    emit("removed", entry)
    return entry
end

return InventoryClient
