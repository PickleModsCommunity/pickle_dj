local DJStations = {}
local LocalDJStations = {}
function UnregisterDJStation(id)
    if LocalDJStations[id] then
        DeleteScriptObject(LocalDJStations[id].entity)
        if LocalDJStations[id].speakerEntities then
            for _, ent in ipairs(LocalDJStations[id].speakerEntities) do
                DeleteScriptObject(ent)
            end
        end
        -- Clean up entity data entities
        if LocalDJStations[id].entityData then
            for _, speakerData in ipairs(LocalDJStations[id].entityData.speakers or {}) do
                if speakerData.entity and DoesEntityExist(speakerData.entity) then
                    DeleteScriptObject(speakerData.entity)
                end
            end
            for _, lightData in ipairs(LocalDJStations[id].entityData.lights or {}) do
                if lightData.entity and DoesEntityExist(lightData.entity) then
                    DeleteScriptObject(lightData.entity)
                end
            end
        end
        for k,v in pairs(LocalDJStations[id].vfxEntities) do
            DeleteScriptObject(v.lightProp)
            DeleteScriptObject(v.visualProp)
            DeleteScriptObject(v.lampProp)
        end
        LocalDJStations[id].vfxEntities = nil
    end
    LocalDJStations[id] = nil
end

local ind = 0
local tmodels = {
    `ba_rig_dj_01_lights_04_a`,
    `ba_rig_dj_01_lights_04_b`,
    `ba_rig_dj_01_lights_04_c`,
    `ba_rig_dj_02_lights_04_a`,
    `ba_rig_dj_02_lights_04_b`,
    `ba_rig_dj_02_lights_04_c`,
    `ba_rig_dj_03_lights_04_a`,
    `ba_rig_dj_03_lights_04_b`,
    `ba_rig_dj_03_lights_04_c`,
    `ba_rig_dj_04_lights_04_a`,
    `ba_rig_dj_04_lights_04_b`,
    `ba_rig_dj_04_lights_04_c`,
}
local lampModels = {
    `stg_blinder`,
    `stg_strobe_blinder`,
    `stg_spot_sharpy`,
    `stg_strobe_hdgh`,
    `stg_rays_bar12_spr`,
    `stg_rays_strobe12_spr_t2`,
}
local sndInd = 0

function CreateVFX(id)
    local vfx = {
        lightProp = nil,
        visualProp = nil,
    }
    local currentTheme = Config.LightingThemes["Rainbow"]
    sndInd = sndInd + 1
    if sndInd > #currentTheme then
        sndInd = 1
    end
    local color = currentTheme[sndInd]
    local station = DJStations[id]
    if not station then return end
    local localStation = LocalDJStations[id]
    local dir = GetEntityForwardVector(localStation.entity)
    local newCoords = vector3(station.coords.x + (dir.x * 2), station.coords.y + (dir.y * 2), station.coords.z + 1.0)
    -- vfx.lightProp = CreateProp(`prop_tennis_ball`, newCoords.x, newCoords.y, newCoords.z + (ind * 0.15), false, true, false)
    -- vfx.visualProp = CreateProp(tmodels[ind + 1], newCoords.x, newCoords.y, newCoords.z - 1.0, false, true, false)
    -- local pos = vector3(-3.0, 0.0, -3.385)
    -- local rot = vector3(0.0, 0.0, 0.0)
    -- AttachEntityToEntity(vfx.visualProp, vfx.lightProp, 0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, false, true, false, true, 2, true)
    -- FreezeEntityPosition(vfx.lightProp, true)
    -- SetEntityRotation(vfx.lightProp, 0.0, 0.0, GetEntityHeading(localStation.entity), 2, true)
    vfx.lampProp = CreateProp(lampModels[ind + 1], newCoords.x + ((-dir.x * 5) * ind), newCoords.y + ((dir.y * 5) * ind), newCoords.z + 1.0 + (ind * 0.15), false, true, false)
    SetObjectLightColor(vfx.lampProp, 1, color.r, color.g, color.b)
    SetEntityRotation(vfx.lampProp, 0.0, 0.0, GetEntityHeading(localStation.entity) + 180.0, 2, true)
    FreezeEntityPosition(vfx.lampProp, true)
    ind = ind + 1
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
            lib.registerContext({
                id = 'dj_station_' .. id,
                title = station.name,
                options = {
                    { 
                        title = 'Open DJ Controller', 
                        description = 'Open the DJ controller for this station.',
                        icon = 'music',
                        onSelect = function()
                            SetMusicController(station.streamId)
                            CreateThread(function()
                                SetNuiFocus(true, true)
                                SendNUIMessage({
                                    type = 'music:setControllerVisible',
                                    visible = true
                                })
                            end)
                        end
                    },
                    { 
                        title = 'Manage DJ Objects', 
                        description = 'Place speakers, lights, and other objects for this station.',
                        icon = 'cog',
                        onSelect = function()
                            OpenEntityManagementMenu(id)
                        end
                    },
                }
            })
            lib.showContext('dj_station_' .. id)

		end),
        entity = nil,
        vfxEntities = {},
        speakerEntities = {},
	}
    LocalDJStations[id].entity = CreateProp(station.prop, station.coords.x, station.coords.y, station.coords.z, false, true, false)
    SetEntityRotation(LocalDJStations[id].entity, 0.0, 0.0, station.heading, 2, true)
    -- Initialize entity storage
    LocalDJStations[id].entityData = {
        speakers = {},
        lights = {},
        other = {}
    }
    
    -- Spawn configured speakers for this station (visuals only)
    if station.speakers and type(station.speakers) == "table" then
        for _, sp in ipairs(station.speakers) do
            local spec = (Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
            local model = (spec and spec.model) or (sp.model or `prop_speaker_06`)
            local offset = (spec and spec.soundOffset) or vector3(0.0, 0.0, 0.0)
            local sc = sp.coords or station.coords
            local pos = vector3(sc.x + offset.x, sc.y + offset.y, sc.z + offset.z)
            local ent = CreateProp(model, pos.x, pos.y, pos.z, false, true, false)
            local h = sp.heading or (spec and spec.heading) or station.heading or 0.0
            local rot = spec and spec.rotation or vector3(0.0, 0.0, 0.0)
            SetEntityRotation(ent, rot.x, rot.y, h + rot.z, 2, true)
            FreezeEntityPosition(ent, true)
            table.insert(LocalDJStations[id].speakerEntities, ent)
            -- Store entity data with database ID
            table.insert(LocalDJStations[id].entityData.speakers, {
                entity = ent,
                dbId = sp.id,
                data = sp
            })
        end
    end
    
    -- Spawn configured lights for this station
    if station.lights and type(station.lights) == "table" then
        for _, light in ipairs(station.lights) do
            local model = light.model or `stg_blinder`
            local ent = CreateProp(model, light.coords.x, light.coords.y, light.coords.z, false, true, false)
            SetEntityRotation(ent, 0.0, 0.0, light.heading, 2, true)
            FreezeEntityPosition(ent, true)
            table.insert(LocalDJStations[id].entityData.lights, {
                entity = ent,
                dbId = light.id,
                data = light
            })
        end
    end
    -- Keep old VFX system for backwards compatibility (auto-generated lights)
    LocalDJStations[id].vfxEntities = {}
    -- Only create auto VFX if no lights are defined in station
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
    
    -- If viewing entities for this station, refresh view
    if viewingEntities and viewingStationId == id then
        -- Viewing will automatically update as entities are re-registered
    end
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
    cb(true)
end)

-- DJ Station Creation System
local isPlacingDJ = false
local previewEntity = nil
local defaultProp = `sf_prop_sf_dj_desk_01a`

-- Raycast function
local function RaycastFromCamera()
    local camRot = GetGameplayCamRot(2)
    local camCoord = GetGameplayCamCoord()
    local distance = 50.0
    
    local raycast = StartExpensiveSynchronousShapeTestLosProbe(
        camCoord.x, camCoord.y, camCoord.z,
        camCoord.x + (-math.sin(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)) * distance),
        camCoord.y + (math.cos(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)) * distance),
        camCoord.z + (math.sin(math.rad(camRot.x)) * distance),
        -1, -- flags (all entities)
        PlayerPedId(),
        7 -- flags
    )
    
    local retval, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(raycast)
    return hit == 1, endCoords, surfaceNormal, entityHit
end

-- Register notification event (defined before ShowNotification function)
RegisterNetEvent('pickle_dj:notify', function(message, type)
    if lib then
        lib.notify({
            title = 'DJ Station',
            description = message,
            type = type or 'info'
        })
    end
end)

-- Draw 3D text helper
function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local camCoords = GetGameplayCamCoord()
    local distance = #(vector3(x, y, z) - camCoords)
    
    local scale = (1 / distance) * 2
    local fov = (1 / GetGameplayCamFov()) * 100
    scale = scale * fov
    
    if onScreen then
        SetTextScale(0.0 * scale, 0.55 * scale)
        SetTextFont(0)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

-- Command handler
RegisterCommand('createdj', function()
    if isPlacingDJ then
        ShowNotification("You are already placing a DJ station. Press Q to cancel.", "error")
        return
    end
    
    -- Check if player has admin permission (server will also check)
    lib.callback('pickle_dj:checkAdmin', false, function(isAdmin)
        if not isAdmin then
            ShowNotification("You don't have permission to use this command", "error")
            return
        end
        local options = {}
        for k,v in pairs(Config.DJStations) do
            table.insert(options, {label = k, value = v.prop})
        end
        print(json.encode(options))
        local input = lib.inputDialog('Create DJ Station', {
            {type = 'input', label = 'Station Name', description = 'Enter a name for this DJ station', required = true, min = 1, max = 50},
            {type = 'select', label = 'Prop', description = 'Select a prop for the DJ station', options = options, required = true, default = options[1].value}
        })
        if not input or not input[1] or not input[2] then
            ShowNotification("No DJ station selected", "error")
            return
        end
        local result = StartGizmoEditor({
            model = input[2],
            coords = GetEntityCoords(PlayerPedId()),
            rotation = GetEntityRotation(PlayerPedId()),
            enableCancel = true
        })
        ShowNotification("Look where you want to place the DJ station. Press E to place, Q to cancel, A/D to rotate", "info")
        
        if result and result.position then
            local stationName = input[1]
            local prop = input[2]
            isPlacingDJ = false
            
            -- Send to server
            TriggerServerEvent('pickle_dj:saveStation', {
                name = stationName,
                coords = result.position,
                heading = result.rotation.z,
                prop = prop,
                speakers = {}, -- Empty initially, can be added later
                lights = {} -- Empty initially, lights are auto-generated
            })
        else
            isPlacingDJ = false
            ShowNotification("DJ station creation cancelled", "error")
        end
    end)
end, false)

-- Entity Management System
local isPlacingEntity = false
local viewingEntities = false
local viewingStationId = nil

-- Entity type definitions
local EntityTypes = {
    speaker = {
        label = "Speaker",
        icon = "volume-high",
        defaultModel = `h4_prop_battle_club_speaker_med`,
        configKey = "speaker_1"
    },
    light = {
        label = "Light",
        icon = "lightbulb",
        defaultModel = `stg_blinder`,
    }
}

-- Show notification helper
function ShowNotification(message, type)
    if lib then
        lib.notify({
            title = 'DJ Station',
            description = message,
            type = type or 'info'
        })
    end
end

-- Open entity management menu
function OpenEntityManagementMenu(stationId)
    local station = DJStations[stationId]
    if not station then return end
    
    local localStation = LocalDJStations[stationId]
    if not localStation then return end
    
    -- Check admin permission
    lib.callback('pickle_dj:checkAdmin', false, function(isAdmin)
        if not isAdmin then
            ShowNotification("You don't have permission to manage DJ entities", "error")
            return
        end
        
        local options = {
            {
                title = "Place Entity",
                description = "Place a new speaker, light, or other object",
                icon = "plus",
                onSelect = function()
                    OpenEntityTypeMenu(stationId)
                end
            },
            {
                title = "View Entities",
                description = "View all entities for this station",
                icon = "eye",
                onSelect = function()
                    ToggleEntityViewing(stationId)
                end
            },
            {
                title = "Remove Entity",
                description = "Remove an entity from this station",
                icon = "trash",
                onSelect = function()
                    OpenEntityRemoveMenu(stationId)
                end
            }
        }
        
        lib.registerContext({
            id = 'dj_entity_manage_' .. stationId,
            title = station.name .. " - Entity Management",
            options = options
        })
        lib.showContext('dj_entity_manage_' .. stationId)
    end)
end

-- Open entity type selection menu
function OpenEntityTypeMenu(stationId)
    local options = {}
    
    for entityType, entityInfo in pairs(EntityTypes) do
        table.insert(options, {
            title = entityInfo.label,
            description = "Place a " .. entityInfo.label:lower(),
            icon = entityInfo.icon,
            onSelect = function()
                StartEntityPlacement(stationId, entityType)
            end
        })
    end
    
    lib.registerContext({
        id = 'dj_entity_type_' .. stationId,
        title = "Select Entity Type",
        menu = 'dj_entity_manage_' .. stationId,
        options = options
    })
    lib.showContext('dj_entity_type_' .. stationId)
end

-- Start entity placement
function StartEntityPlacement(stationId, entityType)
    if isPlacingEntity then
        ShowNotification("You are already placing an entity", "error")
        return
    end
    
    local entityInfo = EntityTypes[entityType]
    if not entityInfo then return end
    
    local station = DJStations[stationId]
    if not station then return end
    
    -- Get model
    local model = entityInfo.defaultModel
    if entityType == "speaker" and entityInfo.configKey and Config.SpeakerProps and Config.SpeakerProps[entityInfo.configKey] then
        model = Config.SpeakerProps[entityInfo.configKey].model
    end
    -- Start gizmo editor
    local result = StartGizmoEditor({
        model = model,
        coords = GetEntityCoords(PlayerPedId()),
        rotation = vector3(0.0, 0.0, GetEntityHeading(PlayerPedId())),
        lightColor = {255, 255, 255},
        enableCancel = true,
        deleteEntity = true
    })
    if result and result.position then
        -- Prepare entity data
        local entityData = {
            coords = result.position,
            heading = result.rotation.z,
            model = model
        }
        
        -- Add entity-specific data
        if entityType == "speaker" and entityInfo.configKey and Config.SpeakerProps and Config.SpeakerProps[entityInfo.configKey] then
            local spec = Config.SpeakerProps[entityInfo.configKey]
            entityData.data = {
                speakerType = entityInfo.configKey,
                rotation = spec.rotation,
                soundOffset = spec.soundOffset
            }
        end
        
        -- Send to server
        TriggerServerEvent('pickle_dj:addEntity', stationId, entityType, entityData)
        ShowNotification(entityInfo.label .. " placed successfully!", "success")
    else
        ShowNotification("Entity placement cancelled", "error")
    end
end

-- Toggle entity viewing
function ToggleEntityViewing(stationId)
    if viewingEntities and viewingStationId == stationId then
        viewingEntities = false
        viewingStationId = nil
        ShowNotification("Entity viewing disabled", "info")
    else
        viewingEntities = true
        viewingStationId = stationId
        ShowNotification("Entity viewing enabled - Look at entities to see their info", "info")
    end
end

-- Entity viewing thread
CreateThread(function()
    while true do
        Wait(0)
        if viewingEntities and viewingStationId then
            local localStation = LocalDJStations[viewingStationId]
            if not localStation or not localStation.entityData then
                viewingEntities = false
                viewingStationId = nil
            else
                local playerCoords = GetEntityCoords(PlayerPedId())
                
                -- Draw speakers
                for _, speakerData in ipairs(localStation.entityData.speakers or {}) do
                    if speakerData.entity and DoesEntityExist(speakerData.entity) then
                        local entCoords = GetEntityCoords(speakerData.entity)
                        local dist = #(playerCoords - entCoords)
                        if dist < 10.0 then
                            DrawText3D(entCoords.x, entCoords.y, entCoords.z + 0.5, "Speaker #" .. (speakerData.dbId or "?") .. "\n[E] Remove")
                            
                            if dist < 2.0 and IsControlJustPressed(0, 38) then -- E key
                                if speakerData.dbId then
                                    TriggerServerEvent('pickle_dj:removeEntity', speakerData.dbId)
                                end
                            end
                        end
                    end
                end
                
                -- Draw lights
                for _, lightData in ipairs(localStation.entityData.lights or {}) do
                    if lightData.entity and DoesEntityExist(lightData.entity) then
                        local entCoords = GetEntityCoords(lightData.entity)
                        local dist = #(playerCoords - entCoords)
                        if dist < 10.0 then
                            DrawText3D(entCoords.x, entCoords.y, entCoords.z + 0.5, "Light #" .. (lightData.dbId or "?") .. "\n[E] Remove")
                            
                            if dist < 2.0 and IsControlJustPressed(0, 38) then -- E key
                                if lightData.dbId then
                                    TriggerServerEvent('pickle_dj:removeEntity', lightData.dbId)
                                end
                            end
                        end
                    end
                end
            end
        else
            Wait(500)
        end
    end
end)

-- Open entity removal menu
function OpenEntityRemoveMenu(stationId)
    local localStation = LocalDJStations[stationId]
    if not localStation or not localStation.entityData then
        ShowNotification("No entities found", "error")
        return
    end
    
    local options = {}
    
    -- Add speakers
    for i, speakerData in ipairs(localStation.entityData.speakers or {}) do
        table.insert(options, {
            title = "Speaker #" .. (speakerData.dbId or i),
            description = "Remove this speaker",
            icon = "volume-high",
            onSelect = function()
                if speakerData.dbId then
                    TriggerServerEvent('pickle_dj:removeEntity', speakerData.dbId)
                else
                    ShowNotification("Entity ID not found", "error")
                end
            end
        })
    end
    
    -- Add lights
    for i, lightData in ipairs(localStation.entityData.lights or {}) do
        table.insert(options, {
            title = "Light #" .. (lightData.dbId or i),
            description = "Remove this light",
            icon = "lightbulb",
            onSelect = function()
                if lightData.dbId then
                    TriggerServerEvent('pickle_dj:removeEntity', lightData.dbId)
                else
                    ShowNotification("Entity ID not found", "error")
                end
            end
        })
    end
    
    if #options == 0 then
        ShowNotification("No entities to remove", "info")
        return
    end
    
    lib.registerContext({
        id = 'dj_entity_remove_' .. stationId,
        title = "Remove Entity",
        menu = 'dj_entity_manage_' .. stationId,
        options = options
    })
    lib.showContext('dj_entity_remove_' .. stationId)
end

-- Update entity data when station is updated
RegisterNetEvent('pickle_dj:entityUpdated', function(stationId)
    -- Reload the station
    if DJStations[stationId] then
        RegisterDJStation(stationId)
    end
end)