local LocalDJStations = {}
local CurrentControlDJStationId = nil

function UnregisterDJStation(id)
    LocalDJStations[id] = nil
end

function RegisterDJStation(id)
    if LocalDJStations[id] then UnregisterDJStation(id) end
	local station = DJStations[id]
	if not station then return end
	LocalDJStations[id] = {
		interact = CreateInteraction({
			label = station.name,
			coords = station.coords,
			heading = station.heading,
		}, function(selection, targetData)
            SetMusicController(id)
			CreateThread(function()
				SetNuiFocus(true, true)
				SendNUIMessage({
					type = 'music:setControllerVisible',
					visible = true
				})
			end)
		end)
	}
end