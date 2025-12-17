local DJStations = {}
local StationDBMapping = {} -- Maps game ID to database ID

-- Per-station light controls (in-memory only, not saved to database)
-- flash: 0 = off, 1 = high (every tick), 2 = low (every 2 ticks)
local StationLightControls = {}

-- Initialize default controls for a station if they don't exist

local function getStationLightControls(stationId)
    if not StationLightControls[stationId] then
        StationLightControls[stationId] = {
            lights = {
                ambient = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = false,
                    flash = GetFlashValue("low"), -- low
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                },
                spotlight = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = false, 
                    flash = GetFlashValue("off"), -- off
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                },
                barlight = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = true,
                    flash = GetFlashValue("low"), -- low
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                }
            }
        }
    end
    return StationLightControls[stationId]
end

-- Create database tables on resource start
CreateThread(function()
    MySQL.ready(function()
        -- Main stations table
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_stations` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `name` VARCHAR(255) NOT NULL,
                `coords` TEXT NOT NULL,
                `heading` FLOAT NOT NULL,
                `prop` VARCHAR(50) NOT NULL,
                `created_by` VARCHAR(255),
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        
        -- Entities table for all station-related objects (speakers, lights, etc.)
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_entities` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `station_id` INT(11) NOT NULL,
                `entity_type` VARCHAR(50) NOT NULL,
                `coords` TEXT NOT NULL,
                `heading` FLOAT NOT NULL,
                `model` VARCHAR(50),
                `data` TEXT,
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                INDEX `idx_station_id` (`station_id`),
                INDEX `idx_entity_type` (`entity_type`),
                FOREIGN KEY (`station_id`) REFERENCES `pickle_dj_stations`(`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        
        print("^2[pickle_dj]^0 Database tables initialized")
    end)
end)

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
        lights = station.lights or nil,
    }
    if skipSync then return id end
    TriggerClientEvent('pickle_dj:registerDJStation', -1, id, station)
    -- Send current light controls state for this station
    local controls = getStationLightControls(id)
    TriggerClientEvent('pickle_dj:lightControlsState', -1, id, controls)
    return id
end

-- Load DJ stations from database
function LoadDJStationsFromDatabase()
    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_stations`", {}, function(stationResults)
        if not stationResults or #stationResults == 0 then
            TriggerClientEvent('pickle_dj:registerDJStation', -1, DJStations)
            return
        end
        
        -- Load all entities for all stations
        MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities`", {}, function(entityResults)
            -- Group entities by station_id and entity_type
            local entitiesByStation = {}
            if entityResults then
                for _, entity in ipairs(entityResults) do
                    if not entitiesByStation[entity.station_id] then
                        entitiesByStation[entity.station_id] = {}
                    end
                    if not entitiesByStation[entity.station_id][entity.entity_type] then
                        entitiesByStation[entity.station_id][entity.entity_type] = {}
                    end
                    
                    local coordsData = json.decode(entity.coords)
                    local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                    local data = entity.data and json.decode(entity.data) or {}
                    
                    table.insert(entitiesByStation[entity.station_id][entity.entity_type], {
                        id = entity.id, -- Database ID for deletion
                        coords = coords,
                        heading = entity.heading,
                        model = entity.model and tonumber(entity.model) or nil,
                        speakerType = data.speakerType,
                        rotation = data.rotation,
                        soundOffset = data.soundOffset,
                        data = data
                    })
                end
            end
            
            -- Load stations with their entities
            for _, row in ipairs(stationResults) do
                local coordsData = json.decode(row.coords)
                local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                
                -- Get entities for this station
                local stationEntities = entitiesByStation[row.id] or {}
                local speakers = stationEntities.speaker or nil
                local lights = stationEntities.light or nil
                
                local streamId = CreateMusicInstance(row.name, coords, row.heading, speakers)
                local gameId = RegisterDJStation({
                    name = row.name,
                    coords = coords,
                    heading = row.heading,
                    prop = tonumber(row.prop),
                    speakers = speakers,
                    lights = lights,
                    streamId = streamId,
                }, true)
                -- Store mapping
                StationDBMapping[gameId] = row.id
                print(("^2[pickle_dj]^0 Loaded DJ station '%s' (ID: %s) from database"):format(row.name, row.id))
            end
            
            TriggerClientEvent('pickle_dj:registerDJStation', -1, DJStations)
        end)
    end)
end

CreateThread(function()
    -- Wait for MySQL to be ready
    MySQL.ready(function()
        -- Load from database first
        LoadDJStationsFromDatabase()
        TriggerClientEvent('pickle_dj:registerDJStation', -1, DJStations)
        -- Send light controls state for all stations
        for gameId, _ in pairs(DJStations) do
            local controls = getStationLightControls(gameId)
            TriggerClientEvent('pickle_dj:lightControlsState', -1, gameId, controls)
        end
    end)
end)

RegisterServerEvent('pickle_dj:requestDJStations', function()
    local source = source
    TriggerClientEvent('pickle_dj:registerDJStation', source, DJStations)
    -- Send light controls state for all stations to requesting client
    for gameId, _ in pairs(DJStations) do
        local controls = getStationLightControls(gameId)
        TriggerClientEvent('pickle_dj:lightControlsState', source, gameId, controls)
    end
end)

-- Admin permission check callback
lib.callback.register('pickle_dj:checkAdmin', function(source)
    return IsPlayerAdmin(source) == true
end)

-- Save entity to database
local function SaveEntity(stationId, entityType, entityData, callback)
    local coordsJson = json.encode(entityData.coords)
    local dataJson = entityData.data and json.encode(entityData.data) or nil
    
    MySQL.Async.insert(
        "INSERT INTO `pickle_dj_entities` (`station_id`, `entity_type`, `coords`, `heading`, `model`, `data`) VALUES (@station_id, @entity_type, @coords, @heading, @model, @data)",
        {
            ['@station_id'] = stationId,
            ['@entity_type'] = entityType,
            ['@coords'] = coordsJson,
            ['@heading'] = entityData.heading or 0.0,
            ['@model'] = entityData.model and tostring(entityData.model) or nil,
            ['@data'] = dataJson
        },
        callback
    )
end

-- Save DJ station to database
RegisterServerEvent('pickle_dj:saveStation', function(stationData)
    local source = source
    
    -- Check admin permission
    if not IsPlayerAdmin(source) then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to create DJ stations", "error")
        return
    end
    
    local identifier = GetIdentifier(source)
    if not identifier then
        TriggerClientEvent('pickle_dj:notify', source, "Failed to get player identifier", "error")
        return
    end
    
    -- Prepare data for database
    local coordsJson = json.encode(stationData.coords)
    
    -- Insert station
    MySQL.Async.insert(
        "INSERT INTO `pickle_dj_stations` (`name`, `coords`, `heading`, `prop`, `created_by`) VALUES (@name, @coords, @heading, @prop, @created_by)",
        {
            ['@name'] = stationData.name,
            ['@coords'] = coordsJson,
            ['@heading'] = stationData.heading,
            ['@prop'] = tostring(stationData.prop),
            ['@created_by'] = identifier
        },
        function(stationInsertId)
            if not stationInsertId then
                TriggerClientEvent('pickle_dj:notify', source, "Failed to save DJ station to database", "error")
                return
            end
            
            -- Collect all entities to save
            local entitiesToSave = {}
            
            -- Collect speakers
            if stationData.speakers and type(stationData.speakers) == "table" then
                for _, speaker in ipairs(stationData.speakers) do
                    table.insert(entitiesToSave, {
                        type = "speaker",
                        data = {
                            coords = speaker.coords,
                            heading = speaker.heading,
                            model = speaker.model,
                            data = {
                                speakerType = speaker.speakerType,
                                rotation = speaker.rotation,
                                soundOffset = speaker.soundOffset
                            }
                        }
                    })
                end
            end
            
            -- Collect lights
            if stationData.lights and type(stationData.lights) == "table" then
                for _, light in ipairs(stationData.lights) do
                    table.insert(entitiesToSave, {
                        type = "light",
                        data = {
                            coords = light.coords,
                            heading = light.heading,
                            model = light.model,
                            data = light.data or {}
                        }
                    })
                end
            end
            
            -- Save all entities
            local entityCount = #entitiesToSave
            local savedCount = 0
            local completed = false
            
            local function checkComplete()
                if not completed and savedCount == entityCount then
                    completed = true
                    -- Create music instance
                    local streamId = CreateMusicInstance(stationData.name, stationData.coords, stationData.heading, stationData.speakers)
                    
                    -- Register the station
                    local id = RegisterDJStation({
                        name = stationData.name,
                        coords = stationData.coords,
                        heading = stationData.heading,
                        prop = stationData.prop,
                        speakers = stationData.speakers,
                        lights = stationData.lights,
                        streamId = streamId,
                    }, false)
                    
                    -- Store mapping
                    StationDBMapping[id] = stationInsertId
                    
                    TriggerClientEvent('pickle_dj:notify', source, "DJ station created successfully!", "success")
                    print(("^2[pickle_dj]^0 DJ station '%s' created by %s (DB ID: %s, Game ID: %s)"):format(stationData.name, identifier, stationInsertId, id))
                end
            end
            
            -- If no entities, complete immediately
            if entityCount == 0 then
                checkComplete()
            else
                -- Save each entity
                for _, entityInfo in ipairs(entitiesToSave) do
                    SaveEntity(stationInsertId, entityInfo.type, entityInfo.data, function()
                        savedCount = savedCount + 1
                        checkComplete()
                    end)
                end
            end
        end
    )
end)

-- Add entity to station
RegisterServerEvent('pickle_dj:addEntity', function(gameId, entityType, entityData)
    local source = source
    
    -- Check admin permission
    if not IsPlayerAdmin(source) then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to manage DJ entities", "error")
        return
    end
    
    -- Get database station ID
    local dbId = StationDBMapping[gameId]
    if not dbId then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found in database", "error")
        return
    end
    
    SaveEntityToStation(source, dbId, gameId, entityType, entityData)
end)

function SaveEntityToStation(source, dbId, gameId, entityType, entityData)
    SaveEntity(dbId, entityType, entityData, function(entityInsertId)
        if entityInsertId then
            -- Reload the station with new entity
            local station = DJStations[gameId]
            if station then
                -- Reload entities for this station
                MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE station_id = @station_id", {
                    ['@station_id'] = dbId
                }, function(entityResults)
                    local entitiesByType = {}
                    if entityResults then
                        for _, entity in ipairs(entityResults) do
                            if not entitiesByType[entity.entity_type] then
                                entitiesByType[entity.entity_type] = {}
                            end
                            
                            local coordsData = json.decode(entity.coords)
                            local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                            local data = entity.data and json.decode(entity.data) or {}
                            
                            table.insert(entitiesByType[entity.entity_type], {
                                id = entity.id,
                                coords = coords,
                                heading = entity.heading,
                                model = entity.model and tonumber(entity.model) or nil,
                                speakerType = data.speakerType,
                                rotation = data.rotation,
                                soundOffset = data.soundOffset,
                                data = data
                            })
                        end
                    end
                    
                    -- Update station with new entities
                    station.speakers = entitiesByType.speaker or station.speakers
                    station.lights = entitiesByType.light or station.lights
                    
                    -- Update music instance if speakers changed
                    if station.streamId and entityType == "speaker" then
                        UpdateMusicInstanceSpeakers(station.streamId, station.speakers)
                    end
                    
                    -- Sync to all clients
                    TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, station)
                    TriggerClientEvent('pickle_dj:notify', source, "Entity added successfully!", "success")
                end)
            end
        else
            TriggerClientEvent('pickle_dj:notify', source, "Failed to save entity", "error")
        end
    end)
end

-- Update music instance speakers
function UpdateMusicInstanceSpeakers(musicInstanceId, speakers)
    if not musicInstanceId then return end
    -- Trigger event to update music instance speakers
    TriggerEvent('pickle_dj:updateMusicInstanceSpeakers', musicInstanceId, speakers)
end

-- Remove entity from station
RegisterServerEvent('pickle_dj:removeEntity', function(entityId)
    local source = source
    
    -- Check admin permission
    if not IsPlayerAdmin(source) then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to manage DJ entities", "error")
        return
    end
    
    -- Get entity info to find station
    MySQL.Async.fetchAll("SELECT station_id, entity_type FROM `pickle_dj_entities` WHERE id = @id", {
        ['@id'] = entityId
    }, function(results)
        if not results or #results == 0 then
            TriggerClientEvent('pickle_dj:notify', source, "Entity not found", "error")
            return
        end
        
        local stationId = results[1].station_id
        
        -- Delete entity
        MySQL.Async.execute("DELETE FROM `pickle_dj_entities` WHERE id = @id", {
            ['@id'] = entityId
        }, function(affectedRows)
            if affectedRows > 0 then
                -- Find game ID for this station
                local gameId = nil
                for gId, dbId in pairs(StationDBMapping) do
                    if dbId == stationId then
                        gameId = gId
                        break
                    end
                end
                
                if gameId then
                    -- Reload entities for this station
                    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE station_id = @station_id", {
                        ['@station_id'] = stationId
                    }, function(entityResults)
                        local entitiesByType = {}
                        if entityResults then
                            for _, entity in ipairs(entityResults) do
                                if not entitiesByType[entity.entity_type] then
                                    entitiesByType[entity.entity_type] = {}
                                end
                                
                                local coordsData = json.decode(entity.coords)
                                local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                                local data = entity.data and json.decode(entity.data) or {}
                                
                                table.insert(entitiesByType[entity.entity_type], {
                                    id = entity.id,
                                    coords = coords,
                                    heading = entity.heading,
                                    model = entity.model and tonumber(entity.model) or nil,
                                    speakerType = data.speakerType,
                                    rotation = data.rotation,
                                    soundOffset = data.soundOffset,
                                    data = data
                                })
                            end
                        end
                        
                        -- Update station
                        local station = DJStations[gameId]
                        if station then
                            station.speakers = entitiesByType.speaker or nil
                            station.lights = entitiesByType.light or nil
                            
                            -- Update music instance if speakers changed
                            if station.streamId and results[1].entity_type == "speaker" then
                                UpdateMusicInstanceSpeakers(station.streamId, station.speakers)
                            end
                            
                            -- Sync to all clients
                            TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, station)
                            TriggerClientEvent('pickle_dj:notify', source, "Entity removed successfully!", "success")
                        end
                    end)
                else
                    TriggerClientEvent('pickle_dj:notify', source, "Entity removed, but could not update station", "warning")
                end
            else
                TriggerClientEvent('pickle_dj:notify', source, "Failed to remove entity", "error")
            end
        end)
    end)
end)

-- Request light controls state for a station (kept for backwards compatibility, but not needed)
RegisterNetEvent('pickle_dj:requestLightControls', function(stationId)
    local source = source
    local controls = getStationLightControls(stationId)
    -- Send current state to requesting client
    TriggerClientEvent('pickle_dj:lightControlsState', source, stationId, controls)
end)

-- Update light controls for a station (networked to all clients)
RegisterNetEvent('pickle_dj:updateLightControls', function(stationId, lightType, property, value)
    local source = source
    local controls = getStationLightControls(stationId)
    
    if not controls or not controls.lights or not controls.lights[lightType] then
        return
    end
    
    -- Update the control value
    local numericValue = value
    if property == "enabled" then
        controls.lights[lightType].enabled = value == true
        numericValue = value == true
    elseif property == "rotateHorizontal" or property == "rotateVertical" then
        controls.lights[lightType][property] = value == true
        numericValue = value == true
    elseif property == "flash" then
        -- Use shared function to convert string to number
        numericValue = GetFlashValue(value)
        if numericValue then
            controls.lights[lightType].flash = numericValue
        end
    elseif property == "speed" then
        -- Use shared function to convert string to number
        numericValue = GetSpeedValue(value)
        if numericValue then
            controls.lights[lightType].speed = numericValue
        end
    end
    
    -- Network the update to all clients with the numeric value from server
    TriggerClientEvent('pickle_dj:lightControlsUpdated', -1, stationId, lightType, property, numericValue)
end)

-- Update all light controls for a station (networked to all clients)
RegisterNetEvent('pickle_dj:updateAllLightControls', function(stationId, property, value)
    local source = source
    local controls = getStationLightControls(stationId)
    
    if not controls or not controls.lights then
        return
    end
    
    -- Update all light types with the same value
    local numericValue = value
    local lightTypes = { "ambient", "spotlight", "barlight" }
    
    for _, lightType in ipairs(lightTypes) do
        if not controls.lights[lightType] then
            goto continue_light
        end
        
        -- Update the control value
        if property == "enabled" then
            controls.lights[lightType].enabled = value == true
            numericValue = value == true
        elseif property == "rotateHorizontal" or property == "rotateVertical" then
            controls.lights[lightType][property] = value == true
            numericValue = value == true
        elseif property == "flash" then
            -- Use shared function to convert string to number
            numericValue = GetFlashValue(value)
            if numericValue then
                controls.lights[lightType].flash = numericValue
            end
        elseif property == "speed" then
            -- Use shared function to convert string to number
            numericValue = GetSpeedValue(value)
            if numericValue then
                controls.lights[lightType].speed = numericValue
            end
        end
        
        -- Network the update to all clients with the numeric value from server
        TriggerClientEvent('pickle_dj:lightControlsUpdated', -1, stationId, lightType, property, numericValue)
        
        ::continue_light::
    end
end)

-- Handle DJ controller opening - automatically assign broadcaster
RegisterNetEvent('pickle_dj:openController', function(stationId)
    local source = source
    local station = DJStations[stationId]
    if not station or not station.streamId then
        print(("[pickle_dj] ERROR: Cannot open controller - station %s not found or missing streamId"):format(tostring(stationId)))
        return
    end
    
    -- Get the music instance for this station
    local musicInstanceId = station.streamId
    local MusicInstances = exports['pickle_clubs']:GetMusicInstances() or {}
    local inst = MusicInstances[musicInstanceId]
    if not inst then
        print(("[pickle_dj] ERROR: Cannot open controller - music instance %s not found"):format(tostring(musicInstanceId)))
        return
    end
    
    -- Ensure musicInstanceId is valid
    if not musicInstanceId or musicInstanceId == nil then
        print(("[pickle_dj] ERROR: Cannot open controller - invalid musicInstanceId: %s"):format(tostring(musicInstanceId)))
        return
    end
    
    -- If player is already broadcasting on this exact table, don't do anything
    -- The client is already broadcasting and connections are established
    -- No need to send the event which could reset connections
    if inst.broadcaster == source and inst.streamId ~= nil then
        -- Player is already broadcasting on this table, just return
        -- Client state should already be in sync
        return
    end
    
    -- Check if player is already broadcasting on another table
    for id, otherInst in pairs(MusicInstances) do
        if otherInst.broadcaster == source and id ~= musicInstanceId then
            -- Remove them from the other table
            otherInst.broadcaster = nil
            otherInst.streamId = nil
            TriggerClientEvent("music:musicInstanceUpdated", -1, id, otherInst)
            TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
        end
    end
    
    -- Only allow one broadcaster per instance; replace if same src, ignore if different and already active
    if inst.broadcaster ~= nil and inst.broadcaster ~= source then
        -- Another player is already broadcasting, don't replace them
        return
    end
    
    -- Generate streamId for this broadcaster
    local streamId = tostring(source) .. "_" .. tostring(math.random(100000, 999999))
    
    -- Pre-set the broadcaster and streamId so the instance is marked as active
    -- The client will then announce the broadcast when ready, which will confirm/update this
    inst.broadcaster = source
    inst.streamId = streamId
    
    -- Notify client to start broadcasting (client will announce via music:rtc:announceBroadcast when ready)
    TriggerClientEvent('pickle_dj:startBroadcasting', source, musicInstanceId, streamId)
    
    -- Push updated instance to clients
    TriggerClientEvent("music:musicInstanceUpdated", -1, musicInstanceId, inst)
    -- legacy: notify broadcast started
    TriggerClientEvent('music:rtc:broadcastStarted', -1, json.encode({ streamId = streamId, broadcaster = source }))
end)

-- Note: We no longer stop broadcasting when controller closes
-- Broadcasting continues until player leaves range of all speakers (handled by range check thread)

-- Check if broadcaster is in range of speakers (called periodically)
CreateThread(function()
    while true do
        Wait(5000) -- Check every 5 seconds
        
        local MusicInstances = exports['pickle_clubs']:GetMusicInstances() or {}
        for instanceId, inst in pairs(MusicInstances) do
            if inst.broadcaster and inst.streamId then
                local broadcasterSrc = inst.broadcaster
                local broadcasterPed = GetPlayerPed(broadcasterSrc)
                if not broadcasterPed or broadcasterPed == 0 then
                    -- Player disconnected, remove broadcaster
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    goto continue_instance
                end
                
                local broadcasterCoords = GetEntityCoords(broadcasterPed)
                if not broadcasterCoords or broadcasterCoords.x == 0.0 then
                    -- Invalid coords, remove broadcaster
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    goto continue_instance
                end
                
                -- Check if broadcaster is in range of any speaker
                local inRange = false
                if inst.speakers and type(inst.speakers) == "table" and #inst.speakers > 0 then
                    for _, sp in ipairs(inst.speakers) do
                        if sp.coords then
                            local spec = (Config and Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
                            local r = (spec and spec.soundRadius) or 0.0
                            if r > 0.0 then
                                local d = #(broadcasterCoords - sp.coords)
                                if d <= r then
                                    inRange = true
                                    break
                                end
                            end
                        end
                    end
                elseif inst.coords then
                    -- Fallback to controller coords with default radius
                    local controllerRadius = Config.MusicRadius or 50.0
                    local d = #(broadcasterCoords - inst.coords)
                    if d <= controllerRadius then
                        inRange = true
                    end
                end
                
                -- If broadcaster is out of range, remove them
                if not inRange then
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    TriggerClientEvent('pickle_dj:stopBroadcasting', broadcasterSrc)
                end
                
                ::continue_instance::
            end
        end
    end
end)
