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
	-- No need
end

function RegisterMusicInstance(id)
	-- No need
end

function SetMusicController(id)
	CurrentControlInstanceId = id
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
	-- Prevent broadcaster from listening to their own stream unless DebugListen is true
	local myId = GetPlayerServerId(PlayerId())
	-- if not (Config and Config.DebugListen) and payload.broadcaster == myId then
	-- 	return
	-- end
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
				-- If I'm the broadcaster and DebugListen is false, do not start listening
				-- local myId = GetPlayerServerId(PlayerId())
				-- if inst.broadcaster == myId then
				-- 	CurrentListeningInstanceId = nil
				-- 	-- ensure UI is stopped and volume/pan reset
				-- 	SendNUIMessage({ type = 'music:rtc:broadcastStopped', payload = {} })
				-- 	SendNUIMessage({ type = 'music:setVolume', payload = { volume = 0.0 } })
				-- 	SendNUIMessage({ type = 'music:setPanning', payload = { pan = 0.0 } })
				-- 	goto __after_listen_tick
				-- end
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
			-- Distance-based linear attenuation (0..1)
			local vol = 1.0 - (nearestDist / radius)
			if vol < 0.0 then vol = 0.0 end
			if vol > 1.0 then vol = 1.0 end
			SendNUIMessage({
				type = 'music:setVolume',
				payload = { volume = vol }
			})
			local inst2 = MusicInstances[nearestId]
			local toSrcX = (inst2.coords.x - pcoords.x)
			local toSrcY = (inst2.coords.y - pcoords.y)
			local len = math.sqrt(toSrcX * toSrcX + toSrcY * toSrcY)
			if len > 0.0001 then
				toSrcX = toSrcX / len
				toSrcY = toSrcY / len
				local camRot = GetGameplayCamRot(0) or vector3(0.0, 0.0, 0.0)
				local heading = camRot.z or 0.0
				local rad = math.rad(heading)
				-- GTA/FiveM: heading 0 faces north (positive Y). Forward vector:
				-- fx = -sin(heading), fy = cos(heading)
				local fx = -math.sin(rad)
				local fy = math.cos(rad)
				local rx = fy
				local ry = -fx
				local pan = (toSrcX * rx) + (toSrcY * ry)
				if pan < -1.0 then pan = -1.0 end
				if pan > 1.0 then pan = 1.0 end
				SendNUIMessage({
					type = 'music:setPanning',
					payload = { pan = pan }
				})
			else
				SendNUIMessage({
					type = 'music:setPanning',
					payload = { pan = 0.0 }
				})
			end
		else
			if CurrentListeningInstanceId ~= nil then
				-- Leave current instance
				CurrentListeningInstanceId = nil
				SendNUIMessage({
					type = 'music:rtc:broadcastStopped',
					payload = {}
				})
				SendNUIMessage({
					type = 'music:setVolume',
					payload = { volume = 0.0 }
				})
				SendNUIMessage({
					type = 'music:setPanning',
					payload = { pan = 0.0 }
				})
			end
		end
		::__after_listen_tick::
		Wait(wait)
	end
end)
