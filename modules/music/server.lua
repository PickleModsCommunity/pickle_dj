local CURRENT_BROADCASTER = nil
local CURRENT_STREAM_ID = nil

-- TURN ICE config is fetched from Cloudflare's ephemeral credentials endpoint at runtime.

local function sendTurnConfigTo(targetSrc)
	-- Prefer Cloudflare token-based ephemeral credentials
	local apiToken = ConfigSV.StreamingServer.cloudflare.apiToken
	local turnTokenId = ConfigSV.StreamingServer.cloudflare.turnTokenId
    local ephemeralUrl = "https://rtc.live.cloudflare.com/v1/turn/keys/"..turnTokenId.."/credentials/generate-ice-servers"
	if turnTokenId ~= '' then
		local method = 'GET'
		local body = nil
		local headers = { ['Content-Type'] = 'application/json' }
		if apiToken ~= '' then
			headers['Authorization'] = 'Bearer ' .. apiToken
		end
		-- If a turnTokenId is provided, POST it in the body (common pattern)
		if turnTokenId ~= '' then
			method = 'POST'
			body = json.encode({ turnTokenId = turnTokenId })
		end
		PerformHttpRequest(ephemeralUrl, function(status, resp, respHeaders)
			local cfg = nil
			if status >= 200 and status < 300 then
				local ok, parsed = pcall(function() return json.decode(resp or '{}') end)
				if ok and type(parsed) == "table" then
					if parsed.iceServers ~= nil then
						cfg = { iceServers = parsed.iceServers }
					else
						-- Some providers return full RTCConfiguration directly
						cfg = parsed
					end
				end
            else
                print("Failed to get turn config", status, resp, respHeaders)
			end
			if cfg == nil then
				-- Fallback to Cloudflare STUN-only if token request fails
				cfg = {
					iceServers = {
						{ urls = { "stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53" } }
					}
				}
			end
            print("turn config", json.encode(cfg))
			TriggerClientEvent('music:rtc:turnConfig', targetSrc, json.encode(cfg))
		end, method, body, headers)
		return
	end

	-- STUN-only fallback when no token is configured
	local stunOnly = {
		iceServers = {
			{ urls = { "stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53" } }
		}
	}
	TriggerClientEvent('music:rtc:turnConfig', targetSrc, json.encode(stunOnly))
end

AddEventHandler('playerDropped', function()
	local src = tonumber(source)
	if CURRENT_BROADCASTER ~= nil and src == CURRENT_BROADCASTER then
		CURRENT_BROADCASTER = nil
		CURRENT_STREAM_ID = nil
		local players = GetPlayers()
		for i=1, #players do
			local player = tonumber(players[i])
			TriggerClientEvent('music:rtc:broadcastStopped', player, json.encode({}))
		end
	end
end)

RegisterNetEvent('music:rtc:requestTurnConfig', function()
	local src = tonumber(source)
	sendTurnConfigTo(src)
end)

RegisterNetEvent('music:rtc:announceBroadcast', function(data, datalen)
	local src = tonumber(source)
	local payload = {}
	do
		local ok, parsed = pcall(function() return json.decode(data or "{}") end)
		if ok and type(parsed) == "table" then payload = parsed end
	end
	local streamId = payload.streamId or tostring(src) .. "_" .. tostring(math.random(100000, 999999))
	CURRENT_BROADCASTER = src
	CURRENT_STREAM_ID = streamId
	print(("[music] broadcast announced by %s streamId=%s"):format(src, streamId))
	local players = GetPlayers()
	for i=1, #players do
		local player = tonumber(players[i])
		TriggerClientEvent('music:rtc:broadcastStarted', player, json.encode({ streamId = streamId, broadcaster = src }))
	end
end)

RegisterNetEvent('music:rtc:stopBroadcast', function()
	local src = tonumber(source)
	if CURRENT_BROADCASTER ~= nil and src == CURRENT_BROADCASTER then
		CURRENT_BROADCASTER = nil
		CURRENT_STREAM_ID = nil
		local players = GetPlayers()
		for i=1, #players do
			local player = tonumber(players[i])
			TriggerClientEvent('music:rtc:broadcastStopped', player, json.encode({}))
		end
	end
end)

RegisterNetEvent('music:rtc:offer', function(data, datalen)
	local src = tonumber(source)
	if CURRENT_BROADCASTER == nil then return end
	-- Forward listener offer to broadcaster
	print(("[music] offer from %s -> broadcaster %s, sdpLen=%s"):format(src, CURRENT_BROADCASTER, tostring(datalen)))
	TriggerClientEvent('music:rtc:offer', CURRENT_BROADCASTER, json.encode({ from = src, sdp = data }))
end)

RegisterNetEvent('music:rtc:answer', function(targetId, sdp)
	local src = tonumber(source)
	if CURRENT_BROADCASTER == nil then return end
	if src ~= CURRENT_BROADCASTER then return end
	local toId = tonumber(targetId)
	if not toId then return end
	print(("[music] answer from broadcaster %s -> %s, sdpLen=%s"):format(src, toId, tostring(#(sdp or ""))))
	TriggerClientEvent('music:rtc:answer', toId, json.encode({ sdp = sdp }))
end)

RegisterNetEvent('music:rtc:iceToBroadcaster', function(candidate)
	local src = tonumber(source)
	if CURRENT_BROADCASTER == nil then return end
	print(("[music] ice to broadcaster from %s"):format(src))
	TriggerClientEvent('music:rtc:iceFromListener', CURRENT_BROADCASTER, json.encode({ from = src, candidate = candidate }))
end)

RegisterNetEvent('music:rtc:iceToListener', function(targetId, candidate)
	local src = tonumber(source)
	if CURRENT_BROADCASTER == nil then return end
	if src ~= CURRENT_BROADCASTER then return end
	local toId = tonumber(targetId)
	if not toId then return end
	print(("[music] ice to listener %s from broadcaster %s"):format(toId, src))
	TriggerClientEvent('music:rtc:iceFromBroadcaster', toId, json.encode({ candidate = candidate }))
end)