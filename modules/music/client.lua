-- Simple NUI echo bridge for local testing of MusicController -> Client -> MusicPlayer
-- Receives POSTs from NUI (fetch to https://<resource>/<name>) and immediately
-- forwards them back into the same NUI as window messages.

RegisterNUICallback('music_stream_start', function(data, cb)
	-- data: { streamId: string, mimeType: string }
	SendNUIMessage({
		type = 'music:streamStart',
		payload = {
			streamId = data and data.streamId or nil,
			mimeType = data and data.mimeType or nil
		}
	})
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_stream_chunk', function(data, cb)
	-- data: { streamId: string, seq: number, mimeType?: string, base64: string }
	SendNUIMessage({
		type = 'music:streamChunk',
		payload = {
			streamId = data and data.streamId or nil,
			seq = data and data.seq or 0,
			base64 = data and data.base64 or ''
		}
	})
	if cb then cb({ ok = true }) end
end)

RegisterNUICallback('music_stream_stop', function(data, cb)
	-- data: { streamId: string }
	SendNUIMessage({
		type = 'music:streamStop',
		payload = {
			streamId = data and data.streamId or nil
		}
	})
	if cb then cb({ ok = true }) end
end)


