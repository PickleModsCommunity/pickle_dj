-- Per-player music library backed by FiveManage uploads.
-- API host/token is configured in config_sv.lua under ConfigSV.FiveManage.
-- Tracks are isolated per player identifier and never shared.

local FM = ConfigSV and ConfigSV.FiveManage or {}

local function getPlayerIdentifier(src)
    src = tonumber(src)
    if not src then return nil end
    if Config and Config.IdentifierPrefix and GetPlayerPrefixIdentifier then
        local ok, id = pcall(GetPlayerPrefixIdentifier, src)
        if ok and id and id ~= "" then return id end
    end
    for _, t in ipairs({ "license2", "license", "steam", "fivem", "discord" }) do
        local v = GetPlayerIdentifierByType(src, t)
        if v and v ~= "" then return v end
    end
    return nil
end

-- Minimal pure-Lua base64 decoder. Input is expected to be ASCII-safe.
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(data)
    if type(data) ~= "string" then return nil end
    data = data:gsub("[^"..b64chars.."=]", "")
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b64chars:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

local function buildMultipart(boundary, fileField, filename, mime, fileBytes)
    local CRLF = "\r\n"
    return table.concat({
        "--", boundary, CRLF,
        'Content-Disposition: form-data; name="', fileField, '"; filename="', filename, '"', CRLF,
        "Content-Type: ", mime, CRLF, CRLF,
        fileBytes, CRLF,
        "--", boundary, "--", CRLF,
    })
end

local function sanitizeFilename(name)
    if type(name) ~= "string" or name == "" then return "track.mp3" end
    -- strip path separators, keep a sensible subset
    name = name:gsub("[\\/]+", "_"):gsub("[^%w%._%-%s%(%)%[%]]", "_")
    if #name > 120 then name = name:sub(1, 120) end
    return name
end

CreateThread(function()
    MySQL.ready(function()
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_library` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `identifier` VARCHAR(255) NOT NULL,
                `title` VARCHAR(255) NOT NULL,
                `url` TEXT NOT NULL,
                `remote_id` VARCHAR(128),
                `mime` VARCHAR(64),
                `file_size` INT(11),
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                INDEX `idx_identifier` (`identifier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        debugPrint("^2[pickle_dj]^0 Library table initialized")
    end)
end)

lib.callback.register('pickle_dj:library:list', function(source)
    local identifier = getPlayerIdentifier(source)
    if not identifier then return { ok = false, error = "no_identifier", items = {} } end
    local rows = MySQL.Sync.fetchAll(
        "SELECT id, title, url, mime, file_size, created_at FROM `pickle_dj_library` WHERE identifier = @id ORDER BY created_at DESC",
        { ['@id'] = identifier }
    ) or {}
    local uploadEnabled = FM.enabled == true and type(FM.apiKey) == "string" and FM.apiKey ~= ""
    return { ok = true, items = rows, uploadEnabled = uploadEnabled }
end)

lib.callback.register('pickle_dj:library:delete', function(source, itemId)
    local identifier = getPlayerIdentifier(source)
    if not identifier then return { ok = false, error = "no_identifier" } end
    itemId = tonumber(itemId)
    if not itemId then return { ok = false, error = "bad_id" } end

    local row = MySQL.Sync.fetchAll(
        "SELECT id, remote_id FROM `pickle_dj_library` WHERE id = @id AND identifier = @ident LIMIT 1",
        { ['@id'] = itemId, ['@ident'] = identifier }
    )
    if not row or not row[1] then return { ok = false, error = "not_found" } end

    MySQL.Async.execute(
        "DELETE FROM `pickle_dj_library` WHERE id = @id AND identifier = @ident",
        { ['@id'] = itemId, ['@ident'] = identifier }
    )

    -- Best-effort remote delete; ignore failure (DB row already gone)
    if FM.enabled and FM.apiKey and FM.apiKey ~= "" and row[1].remote_id and row[1].remote_id ~= "" then
        local url = (FM.deleteUrl or "https://api.fivemanage.com/api/audio") .. "/" .. row[1].remote_id
        PerformHttpRequest(url, function(status, _, _)
            debugPrint(("[pickle_dj] FiveManage delete remote_id=%s status=%s"):format(row[1].remote_id, tostring(status)))
        end, "DELETE", "", { ["Authorization"] = FM.apiKey })
    end

    return { ok = true }
end)

-- Upload a track to FiveManage and persist a row in the player's library.
-- payload: { filename, mimeType, dataBase64, title? }
lib.callback.register('pickle_dj:library:upload', function(source, payload)
    if not FM.enabled then return { ok = false, error = "disabled" } end
    if not FM.apiKey or FM.apiKey == "" then return { ok = false, error = "no_api_key" } end

    local identifier = getPlayerIdentifier(source)
    if not identifier then return { ok = false, error = "no_identifier" } end
    if type(payload) ~= "table" then return { ok = false, error = "bad_payload" } end

    local filename = sanitizeFilename(payload.filename)
    local mime = type(payload.mimeType) == "string" and payload.mimeType or "audio/mpeg"
    local title = type(payload.title) == "string" and payload.title ~= "" and payload.title or filename

    local bytes = b64decode(payload.dataBase64 or "")
    if not bytes or #bytes == 0 then return { ok = false, error = "empty_file" } end

    local maxBytes = (tonumber(FM.maxFileSizeMB) or 12) * 1024 * 1024
    if #bytes > maxBytes then
        return { ok = false, error = "too_large", maxFileSizeMB = FM.maxFileSizeMB }
    end

    -- Per-player cap
    local cap = tonumber(FM.maxTracksPerPlayer) or 0
    if cap > 0 then
        local count = MySQL.Sync.fetchScalar(
            "SELECT COUNT(*) FROM `pickle_dj_library` WHERE identifier = @ident",
            { ['@ident'] = identifier }
        ) or 0
        if tonumber(count) and tonumber(count) >= cap then
            return { ok = false, error = "library_full", maxTracksPerPlayer = cap }
        end
    end

    local boundary = "----pickleDJ" .. tostring(math.random(100000, 999999)) .. tostring(os.time())
    local body = buildMultipart(boundary, "file", filename, mime, bytes)
    local headers = {
        ["Authorization"] = FM.apiKey,
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
    }

    -- PerformHttpRequest is async — bridge to callback via promise
    local p = promise.new()
    PerformHttpRequest(FM.uploadUrl or "https://api.fivemanage.com/api/audio", function(status, respBody, _)
        p:resolve({ status = status, body = respBody })
    end, "POST", body, headers)
    local result = Citizen.Await(p)

    if not result or not result.status or result.status < 200 or result.status >= 300 then
        debugPrint(("^1[pickle_dj]^0 FiveManage upload failed status=%s body=%s"):format(tostring(result and result.status), tostring(result and result.body)))
        return { ok = false, error = "upload_failed", status = result and result.status }
    end

    local parsed
    pcall(function() parsed = json.decode(result.body or "{}") end)
    if type(parsed) ~= "table" or type(parsed.url) ~= "string" or parsed.url == "" then
        return { ok = false, error = "bad_response" }
    end

    local remoteId = parsed.id or parsed.fileId or parsed.audioId
    if remoteId == nil then
        -- some responses return only the URL; derive an id from the filename component
        remoteId = parsed.url:match("/([^/?#]+)%.[%w]+$") or ""
    end

    local insertId = MySQL.Sync.insert(
        "INSERT INTO `pickle_dj_library` (identifier, title, url, remote_id, mime, file_size) VALUES (@ident, @title, @url, @rid, @mime, @sz)",
        {
            ['@ident'] = identifier,
            ['@title'] = title,
            ['@url']   = parsed.url,
            ['@rid']   = tostring(remoteId or ""),
            ['@mime']  = mime,
            ['@sz']    = #bytes,
        }
    )

    return {
        ok = true,
        item = {
            id = insertId,
            title = title,
            url = parsed.url,
            mime = mime,
            file_size = #bytes,
        }
    }
end)
