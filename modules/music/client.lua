local __turn_config = nil

CreateThread(function()
	Wait(1000)
	TriggerServerEvent('music:rtc:requestTurnConfig')
end)

RegisterNetEvent('music:rtc:turnConfig', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	__turn_config = payload
	print("turn config", json.encode(__turn_config))
end)

RegisterNUICallback('music_rtc_get_turn_config', function(data, cb)
	cb({ ok = true, config = __turn_config })
end)

RegisterNUICallback('music_rtc_request_turn_config', function(data, cb)
	TriggerServerEvent('music:rtc:requestTurnConfig')
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_announce_broadcast', function(data, cb)
	local enc = json.encode(data or {})
	TriggerServerEvent('music:rtc:announceBroadcast', enc, #enc)
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_stop_broadcast', function(data, cb)
	TriggerServerEvent('music:rtc:stopBroadcast')
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_offer', function(data, cb)
	print("[music] NUI music_rtc_offer")
	-- data: { sdp: string }
	local sdp = (data and data.sdp) or ""
	TriggerServerEvent('music:rtc:offer', sdp, #sdp)
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_answer', function(data, cb)
	print("[music] NUI music_rtc_answer -> to", (data and data.to) or -1)
	-- data: { to: number, sdp: string }
	local to = (data and data.to) or -1
	local sdp = (data and data.sdp) or ""
	TriggerServerEvent('music:rtc:answer', to, sdp)
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_ice_to_broadcaster', function(data, cb)
	print("[music] NUI music_rtc_ice_to_broadcaster")
	-- data: { candidate: any-json }
	local cand = (data and data.candidate) or nil
	if cand ~= nil then
		TriggerServerEvent('music:rtc:iceToBroadcaster', json.encode(cand))
	end
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_rtc_ice_to_listener', function(data, cb)
	print("[music] NUI music_rtc_ice_to_listener -> to", (data and data.to) or -1)
	-- data: { to: number, candidate: any-json }
	local to = (data and data.to) or -1
	local cand = (data and data.candidate) or nil
	if to ~= -1 and cand ~= nil then
		TriggerServerEvent('music:rtc:iceToListener', to, json.encode(cand))
	end
	if cb then cb({ ok = true }) end
end)

RegisterNetEvent('music:rtc:broadcastStarted', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	SendNUIMessage({
		type = 'music:rtc:broadcastStarted',
		payload = {
			streamId = payload.streamId,
			broadcaster = payload.broadcaster
		}
	})
end)

RegisterNetEvent('music:rtc:broadcastStopped', function(data)
	SendNUIMessage({
		type = 'music:rtc:broadcastStopped',
		payload = {}
	})
end)

RegisterNetEvent('music:rtc:offer', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	SendNUIMessage({
		type = 'music:rtc:offer',
		payload = payload
	})
end)

RegisterNetEvent('music:rtc:answer', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	SendNUIMessage({
		type = 'music:rtc:answer',
		payload = payload
	})
end)

RegisterNetEvent('music:rtc:iceFromListener', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	SendNUIMessage({
		type = 'music:rtc:iceFromListener',
		payload = payload
	})
end)

RegisterNetEvent('music:rtc:iceFromBroadcaster', function(data)
	local payload = {}
	local ok, parsed = pcall(function() return json.decode(data or "{}") end)
	if ok and type(parsed) == "table" then payload = parsed end
	SendNUIMessage({
		type = 'music:rtc:iceFromBroadcaster',
		payload = payload
	})
end)
