local DJStations = {}

function RegisterDJStation(station, skipSync)
    local id
    repeat
        id = math.random(1, 1000000)
    until not DJStations[id]
    DJStations[id] = {
        name = station.name or "Unknown",
        coords = station.coords or vec3(0.0, 0.0, 0.0),
        heading = station.heading or 0.0,
        streamId = station.streamId or nil,
        prop = station.prop or nil,
        speakers = station.speakers or nil,
    }
    if skipSync then return id end
    TriggerClientEvent('pickle_dj:registerDJStation', -1, id, station)
    return id
end

CreateThread(function()
    for _, instance in pairs(Config.DJStations) do
        local streamId = CreateMusicInstance(instance.name, instance.coords, instance.heading, instance.speakers)
        RegisterDJStation({
            name = instance.name,
            coords = instance.coords,
            heading = instance.heading,
            prop = instance.prop,
            speakers = instance.speakers,
            streamId = streamId,
        }, true)
        print(("Created dj instance %s at %s"):format(instance.name, json.encode(instance.coords)))
    end
    TriggerClientEvent('pickle_dj:registerDJStation', -1, DJStations)
end)

RegisterServerEvent('pickle_dj:requestDJStations', function()
    local source = source
    TriggerClientEvent('pickle_dj:registerDJStation', source, DJStations)
end)