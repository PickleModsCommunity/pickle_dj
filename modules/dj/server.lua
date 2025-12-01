CreateThread(function()
    local stations = {}
    for _, instance in pairs(Config.DJStations) do
        locastreamId = CreateMusicInstance(instance.name, instance.coords, instance.heading)
        print(("Created music instance %s at %s"):format(instance.name, json.encode(instance.coords)))
    end
end)