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
                            print('Manage DJ Objects')
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
    -- Spawn configured speakers for this station (visuals only)
    if station.speakers and type(station.speakers) == "table" then
        for _, sp in ipairs(station.speakers) do
            local spec = (Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
            local model = (spec and spec.model) or `prop_speaker_06`
            local offset = (spec and spec.soundOffset) or vector3(0.0, 0.0, 0.0)
            local sc = sp.coords or station.coords
            local pos = vector3(sc.x + offset.x, sc.y + offset.y, sc.z + offset.z)
            local ent = CreateProp(model, pos.x, pos.y, pos.z, false, true, false)
            local h = sp.heading or (spec and spec.heading) or station.heading or 0.0
            SetEntityRotation(ent, spec.rotation.x, spec.rotation.y, h + spec.rotation.z, 2, true)
            FreezeEntityPosition(ent, true)
            table.insert(LocalDJStations[id].speakerEntities, ent)
        end
    end
    LocalDJStations[id].vfxEntities = {}
    for i=1, #lampModels do
        LocalDJStations[id].vfxEntities["L_" .. i] = CreateVFX(id)
    end
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
    cb(true)
end)