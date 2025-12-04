local DJStations = {}
local LocalDJStations = {}
function UnregisterDJStation(id)
    if LocalDJStations[id] then
        DeleteScriptObject(LocalDJStations[id].entity)
        for k,v in pairs(LocalDJStations[id].vfxEntities) do
            DeleteScriptObject(v.lightProp)
        end
        LocalDJStations[id].vfxEntities = nil
    end
    LocalDJStations[id] = nil
end

function CreateVFX(id)
    local vfx = {
        lightProp = nil,
    }
    local station = DJStations[id]
    if not station then return end
    local localStation = LocalDJStations[id]
    local dir = GetEntityForwardVector(localStation.entity)
    local newCoords = vector3(station.coords.x + (dir.x * 2), station.coords.y + (dir.y * 2), station.coords.z + 1.0)
    vfx.lightProp = CreateProp(`sf_int1_dropdownlight041`, newCoords.x, newCoords.y, newCoords.z, false, true, false)
    SetEntityRotation(vfx.lightProp, 0.0, 0.0, station.heading, 2, true)
    CreateThread(function()
        local sequences = {
            {
                x = {enabled = true, start = 0, finish = 90, duration = 1000},
                y = {enabled = false, start = 90, finish = 0, duration = 1000},
            },
            {
                x = {enabled = true, start = 90, finish = 0, duration = 1000},
                y = {enabled = false, start = 0, finish = 90, duration = 1000},
            },
        }
        local sequenceIndex = 1
        local sequenceTime = 0
        local rx = 0.0
        local ry = 0.0
        local r = 255
        local g = 127
        local b = 127
        while true do
            if not station then return end
            local sequence = sequences[sequenceIndex]
            if sequence.x.enabled then
                if sequence.x.start < sequence.x.finish then
                    rx = rx - (10 / sequence.x.duration)
                else
                    rx = rx + (10 / sequence.x.duration)
                end
            end
            if sequence.y.enabled then
                if sequence.y.start < sequence.y.finish then
                    ry = ry - (10 / sequence.y.duration)
                else
                    ry = ry + (10 / sequence.y.duration)
                end
            end
            sequenceTime = sequenceTime + 10
            local done = false
            for k,v in pairs(sequences[sequenceIndex]) do
                if v.enabled and sequenceTime > v.duration then
                    done = true
                end
            end
            if done then
                sequenceIndex = sequenceIndex + 1
                if sequenceIndex > #sequences then
                    sequenceIndex = 1
                end
                sequenceTime = 0
            end
            local dir = GetEntityForwardVector(localStation.entity)
            local newCoords = vector3(station.coords.x + (dir.x * 2), station.coords.y + (dir.y * 2), station.coords.z + 1.0)
            print(90.0 + rx * 360, 90.0 + ry * 360, station.heading)
            DrawMarker(1, newCoords.x, newCoords.y, newCoords.z, dir.x, dir.y, dir.z, 90.0 + ry * 360, 0.0, 0.0, 0.04, 0.04, 10.0, r, g, b, 255, false, false, 2, false, nil, nil, false)
            -- DrawSpotLightWithShadow(newCoords.x, newCoords.y, newCoords.z, dir.x, dir.y, dir.z, 255, 255, 255, 50.0, 1.0, 0.0, 4.0, 1.0, 1)
            Wait(0)
        end
    end)
    return vfx
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
            SetMusicController(station.streamId)
			CreateThread(function()
				SetNuiFocus(true, true)
				SendNUIMessage({
					type = 'music:setControllerVisible',
					visible = true
				})
			end)
		end),
        entity = nil,
        vfxEntities = {},
	}
    LocalDJStations[id].entity = CreateProp(station.prop, station.coords.x, station.coords.y, station.coords.z, false, true, false)
    SetEntityRotation(LocalDJStations[id].entity, 0.0, 0.0, station.heading, 2, true)
    LocalDJStations[id].vfxEntities = {
        ["L_1"] = CreateVFX(id),
    }
    return station
end

RegisterNetEvent('pickle_dj:registerDJStation', function(id, station)
    if type(id) == 'table' then
        for id, station in pairs(id) do
            DJStations[id] = station
            RegisterDJStation(id)
        end
        return
    end
    DJStations[id] = station
    RegisterDJStation(id)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        TriggerServerEvent('pickle_dj:requestDJStations')
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for id, station in pairs(DJStations) do
            UnregisterDJStation(id)
        end
    end
end)

RegisterNUICallback('setVisible', function(data, cb)
    SetNuiFocus(data.visible, data.visible)
    SendNUIMessage({
        type = 'music:setControllerVisible',
        visible = data.visible
    })
    cb(true)
end)