

RegisterServerEvent('music:streamStart', function(data, datalen)
    local source = tonumber(source)
    local players = GetPlayers()
    for i=1, #players do
        local player = tonumber(players[i])
        if player ~= source then
            TriggerClientEvent('music:streamStart', player, data, datalen)
        end
    end
end)

RegisterServerEvent('music:streamChunk', function(data, datalen)
    local source = tonumber(source)
    local players = GetPlayers()
    for i=1, #players do
        local player = tonumber(players[i])
        if player ~= source then
            TriggerClientEvent('music:streamChunk', player, data, datalen)
        end
    end
end)

RegisterServerEvent('music:streamStop', function(data, datalen)
    local source = tonumber(source)
    local players = GetPlayers()
    for i=1, #players do
        local player = tonumber(players[i])
        if player ~= source then
            TriggerClientEvent('music:streamStop', player, data, datalen)
        end
    end
end)