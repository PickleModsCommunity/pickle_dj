-- NUI <-> server bridge for the per-player music library.

-- Re-assert NUI focus. CEF loses keyboard/mouse focus on the NUI overlay
-- after the OS file picker closes; the NUI must call this to re-arm input
-- before subsequent clicks (like opening another file picker) will register.
RegisterNUICallback('keepFocus', function(_, cb)
    SetNuiFocus(true, true)
    cb({ ok = true })
end)


RegisterNUICallback('library_list', function(_, cb)
    lib.callback('pickle_dj:library:list', false, function(result)
        cb(result or { ok = false, error = "no_response", items = {} })
    end)
end)

RegisterNUICallback('library_upload', function(data, cb)
    lib.callback('pickle_dj:library:upload', false, function(result)
        cb(result or { ok = false, error = "no_response" })
    end, data)
end)

RegisterNUICallback('library_delete', function(data, cb)
    local id = data and data.id
    lib.callback('pickle_dj:library:delete', false, function(result)
        cb(result or { ok = false, error = "no_response" })
    end, id)
end)
