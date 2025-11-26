-- Simple NUI echo bridge for local testing of MusicController -> Client -> MusicPlayer
-- Receives POSTs from NUI (fetch to https://<resource>/<name>) and immediately
-- forwards them back into the same NUI as window messages.

RegisterNUICallback('music_stream_start', function(data, cb)
	local data = json.encode(data)
    TriggerServerEvent('music:streamStart', data, #data)
	-- data: { streamId: string, mimeType: string }
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_stream_chunk', function(data, cb)
	-- data: { streamId: string, seq: number, mimeType?: string, base64: string }
	local data = json.encode(data)
    TriggerServerEvent('music:streamChunk', data, #data)
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_stream_stop', function(data, cb)
	-- data: { streamId: string }
	local data = json.encode(data)
    TriggerServerEvent('music:streamStop', data, #data)
	if cb then cb({ ok = true }) end
end)

RegisterNetEvent("music:streamStart", function(data)
	data = json.decode(data)
	SendNUIMessage({
		type = 'music:streamStart',
		payload = {
			streamId = data and data.streamId or nil,
			mimeType = data and data.mimeType or nil
		}
	})
end)

local __music_last_seq_by_stream = {}

RegisterNetEvent("music:streamChunk", function(data)
	data = json.decode(data)
    local sid = data and data.streamId or nil
    local seq = data and data.seq or 0
    if sid then
        local last = __music_last_seq_by_stream[sid] or -1
        if seq <= last then
            return
        end
        __music_last_seq_by_stream[sid] = seq
    end
	SendNUIMessage({
		type = 'music:streamChunk',
		payload = {
			streamId = sid,
			seq = seq,
            mimeType = data and data.mimeType or nil,
			base64 = data and data.base64 or ''
		}
	})
end)

RegisterNetEvent("music:streamStop", function(data)
	data = json.decode(data)
	SendNUIMessage({
		type = 'music:streamStop',
		payload = {
			streamId = data and data.streamId or nil
		}
	})
end)
