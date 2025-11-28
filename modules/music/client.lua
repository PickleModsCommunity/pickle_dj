local __turn_config = nil
local MusicInstances = {}
local LocalMusicInstances = {}
local CurrentControlInstanceId = nil
local CurrentListeningInstanceId = nil

CreateThread(function()
	Wait(1000)
	TriggerServerEvent('music:rtc:requestTurnConfig')
	TriggerServerEvent('music:requestSync')
end)

function UnregisterMusicInstance(id)
	LocalMusicInstances[id] = nil
end

function RegisterMusicInstance(id)
	if LocalMusicInstances[id] then UnregisterMusicInstance(id) end
	local inst = MusicInstances[id]
	if not inst then return end
	LocalMusicInstances[id] = {
		interact = CreateInteraction({
			label = inst.name,
			coords = inst.coords,
			heading = inst.heading,
		}, function(selection, targetData)
			CurrentControlInstanceId = id
			CreateThread(function()
				SetNuiFocus(true, true)
				SendNUIMessage({
					type = 'music:setControllerVisible',
					visible = true
				})
				-- Inform UI of the active instance context
				SendNUIMessage({
					type = 'music:setActiveInstance',
					instanceId = id,
					payload = {
						name = inst.name
					}
				})
			end)
		end)
	}
end

RegisterNetEvent("music:syncMusicInstances", function(data)
	for k,v in pairs(data) do
		MusicInstances[k] = v
		RegisterMusicInstance(k)
	end
end)

RegisterNetEvent("music:musicInstanceUpdated", function(id, instance)
	MusicInstances[id] = instance
	RegisterMusicInstance(id)
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
	-- Ensure instanceId is set (use the controller the player opened)
	local payload = data or {}
	if payload.instanceId == nil then payload.instanceId = CurrentControlInstanceId end
	local enc = json.encode(payload)
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
	-- Include the instance the listener is attempting to join
	local payload = {
		instanceId = CurrentListeningInstanceId,
		sdp = sdp
	}
	local enc = json.encode(payload)
	TriggerServerEvent('music:rtc:offer', enc, #enc)
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
		local enc = json.encode({ instanceId = CurrentListeningInstanceId, candidate = cand })
		TriggerServerEvent('music:rtc:iceToBroadcaster', enc)
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

-- Proximity-based listening to nearest active instance
CreateThread(function()
	while true do
		local wait = 1500
		local ped = PlayerPedId()
		local pcoords = GetEntityCoords(ped)
		local nearestId = nil
		local nearestDist = 999999.0
		for id, inst in pairs(MusicInstances) do
			print("[MSC] INST", id, inst.streamId, inst.broadcaster, inst.coords)
			if inst and inst.streamId ~= nil and inst.broadcaster ~= nil and inst.coords ~= nil then
				local dist = #(pcoords - inst.coords)
				if dist < nearestDist then
					nearestDist = dist
					nearestId = id
				end
			end
		end
		local radius = (Config and Config.MusicRadius) or 50.0
		if nearestId ~= nil and nearestDist <= radius then
			wait = 0
			if CurrentListeningInstanceId ~= nearestId then
				-- Switch to this instance
				if CurrentListeningInstanceId ~= nil then
					print("[MSC] STOP BROADCAST", CurrentListeningInstanceId)
					SendNUIMessage({
						type = 'music:rtc:broadcastStopped',
						payload = {}
					})
				end
				local inst = MusicInstances[nearestId]
				CurrentListeningInstanceId = nearestId
				print("[MSC] START BROADCAST", nearestId)
				SendNUIMessage({
					type = 'music:rtc:broadcastStarted',
					payload = {
						instanceId = nearestId,
						streamId = inst.streamId,
						broadcaster = inst.broadcaster
					}
				})
			end
			-- Distance-based linear attenuation
			local vol = 1.0 - (nearestDist / radius)
			if vol < 0.0 then vol = 0.0 end
			if vol > 1.0 then vol = 1.0 end
			SendNUIMessage({
				type = 'music:setVolume',
				payload = { volume = vol }
			})
		else
			if CurrentListeningInstanceId ~= nil then
				-- Leave current instance
				CurrentListeningInstanceId = nil
				SendNUIMessage({
					type = 'music:rtc:broadcastStopped',
					payload = {}
				})
				-- Ensure volume is zeroed when out of range
				SendNUIMessage({
					type = 'music:setVolume',
					payload = { volume = 0.0 }
				})
			end
		end
		Wait(wait)
	end
end)
