
COOP = COOP or {}
local C = COOP

C.partnerId = C.partnerId or nil
C.mode = C.mode or "shadow"
C.isHost = (C.isHost == nil) and true or C.isHost
C.history = {}


C.hasNetPos = false
C.targetPos = nil
C.targetAng = nil
C.targetStance = 0
C.currentPos = nil

C.knownNPCs = C.knownNPCs or {}
C.recentKills = C.recentKills or {}
C.executedKills = C.executedKills or {}
C.aiTargets = C.aiTargets or {}           -- [slotId] = { entId, x, y, z, yaw, archId, spTag, lastSeen }
C.boundClientToSlot = C.boundClientToSlot or {}
C.archetypePalette = C.archetypePalette or nil

C.killCounter = C.killCounter or 0
C.localAlertState = 0
C.remoteAlertCooldown = 0
C.frame = 0
C.keyCooldown = 0
C.hookInstalled = false
C.isSyncingDamage = false

local SAVE_DIR = (os.getenv("USERPROFILE") or ".") .. "/Saved Games/Sniper Ghost Warrior 3/"
C.posOutFile = SAVE_DIR .. "coop_pos_out.dat"
C.posInFile  = SAVE_DIR .. "coop_pos_in.dat"

local function log(msg)
    if SGW3 and SGW3.Log then
        SGW3.Log("coop", msg)
    else
        print("[coop] " .. tostring(msg))
    end
end

local function lerp_vec(a, b, t)
    if t > 1.0 then t = 1.0 end
    return {
        x = a.x + (b.x - a.x) * t,
        y = a.y + (b.y - a.y) * t,
        z = a.z + (b.z - a.z) * t
    }
end

local function lerp_angle(a, b, t)
    local diff = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + diff * math.min(1.0, t)
end


local function is_real_human(e, localPlayerId)
    if not e or e.id == localPlayerId or e.id == C.partnerId then return false end
    local name = tostring(e:GetName())
    local cls = tostring(e.class):lower()

    if cls == "aispawnpoint" or cls == "tagpoint" or cls == "trigger" or cls == "smartobject" then
        return false
    end
    if name:find("^trainer_") or name:find("^Coop_Partner") then return false end

    if e.actor then return true end
    if cls:find("human") or cls:find("grunt") or cls:find("civilian") or cls:find("worker") or cls:find("hostage") or cls:find("sniper") then
        return true
    end
    return false
end

local function get_npc_health(e)
    if not e then return 0 end
    if e.actor and e.actor.GetHealth then
        return e.actor:GetHealth() or 0
    end
    if e.GetHealth and type(e.GetHealth) == "function" then
        return e:GetHealth() or 0
    end
    return 0
end

local function is_npc_dead(e)
    if not e then return true end
    if e.IsDead and type(e.IsDead) == "function" and e:IsDead() then return true end
    if e.actor and e.actor.IsDead and type(e.actor.IsDead) == "function" and e.actor:IsDead() then return true end
    return get_npc_health(e) <= 0
end


local function get_short_spawn_tag(e)
    local name = tostring(e:GetName())
    local spNum = name:match("SpawnPoint(%d+)") or name:match("(%d+)$")
    if spNum then
        local prefix = name:sub(1, 3):gsub("[^%w]", "")
        return prefix .. spNum
    end
    return name:sub(-6):gsub("|", "")
end


local function get_arch_hash(archStr)
    if not archStr or archStr == "" then return "0" end
    local s = tostring(archStr)
    local sum = 0
    for i = 1, #s do
        sum = (sum * 31 + string.byte(s, i)) % 9999
    end
    return tostring(sum)
end


local function update_archetype_palette(myPos, pId)
    C.archetypePalette = C.archetypePalette or {}
    local ents = System.GetEntitiesInSphere(myPos, 600) or {}
    for _, e in pairs(ents) do
        if is_real_human(e, pId) and e.GetArchetype then
            local arch = e:GetArchetype()
            if arch then
                local h = get_arch_hash(arch)
                C.archetypePalette[h] = { arch = arch, cls = e.class }
            end
        end
    end
end


local function ensure_matching_enemy_class(npc, targetArchHash, spTag)
    if not npc or not targetArchHash or targetArchHash == "0" then return npc end
    local myArch = (npc.GetArchetype and npc:GetArchetype()) or ""
    local myHash = get_arch_hash(myArch)


    if myHash == targetArchHash then return npc end

    local targetInfo = C.archetypePalette and C.archetypePalette[targetArchHash]
    if not targetInfo then return npc end

    local pos = npc:GetWorldPos()
    local ang = npc:GetWorldAngles()
    local oldName = tostring(npc:GetName())

    local ok, newNpc = pcall(System.SpawnEntity, {
        class = targetInfo.cls,
        archetype = targetInfo.arch,
        name = "CoopSync_" .. oldName,
        position = pos,
        orientation = { x = 0, y = 1, z = 0 }
    })

    if ok and newNpc then
        newNpc:SetWorldAngles(ang)
        if newNpc.Activate then pcall(newNpc.Activate, newNpc, 1) end
        pcall(System.RemoveEntity, npc.id)
        log(string.format("Synced Enemy Class -> %s", tostring(targetInfo.arch)))
        return newNpc
    end

    return npc
end

local function find_alive_human_near(tx, ty, tz, pId, radius)
    if not tx or not ty or not tz then return nil end
    local r = radius or 25.0
    local ents = System.GetEntitiesInSphere({ x = tx, y = ty, z = tz }, r) or {}
    local bestEnt = nil
    local bestDistSq = r * r

    for _, e in pairs(ents) do
        if is_real_human(e, pId) and not is_npc_dead(e) then
            local ep = e:GetWorldPos()
            local dSq = (ep.x - tx)^2 + (ep.y - ty)^2 + (ep.z - tz)^2
            if dSq < bestDistSq then
                bestDistSq = dSq
                bestEnt = e
            end
        end
    end
    return bestEnt
end

local function execute_native_death(ent, shooter)
    if not ent or is_npc_dead(ent) then return end
    C.isSyncingDamage = true

    local pos = ent:GetWorldPos()
    local me = shooter or rawget(_G, "g_localActor")
    local gr = rawget(_G, "g_gameRules") or rawget(_G, "SinglePlayer")

    pcall(function()
        if ent.actor and ent.actor.SetHealth then
            ent.actor:SetHealth(1)
        elseif ent.SetHealth then
            ent:SetHealth(1)
        end
    end)

    if gr and type(gr.CreateHit) == "function" then
        pcall(function()
            gr:CreateHit(
                ent.id,
                me and me.id or ent.id,
                me and me.id or ent.id,
                5000, 0, "mat_head", 1, "bullet",
                { x = pos.x, y = pos.y, z = pos.z + 1.5 },
                { x = 0, y = 1, z = -0.1 },
                { x = 0, y = -1, z = 0 }
            )
        end)
    end

    if not is_npc_dead(ent) and gr and type(gr.ProcessActorDamage) == "function" then
        local hit = {
            target = ent, targetId = ent.id,
            shooter = me, shooterId = me and me.id or ent.id,
            weapon = me, weaponId = me and me.id or ent.id,
            damage = 5000, radius = 0,
            pos = { x = pos.x, y = pos.y, z = pos.z + 1.5 },
            dir = { x = 0, y = 1, z = -0.1 },
            normal = { x = 0, y = -1, z = 0 },
            type = "bullet", typeId = 1, partId = 1, material = "mat_head"
        }
        pcall(gr.ProcessActorDamage, gr, hit)
        if gr.Server and gr.Server.OnHit then pcall(gr.Server.OnHit, gr, hit) end
        if gr.Client and gr.Client.OnHit then pcall(gr.Client.OnHit, gr, hit) end
    end

    pcall(function()
        if not is_npc_dead(ent) then
            if ent.Kill then ent:Kill(true, me and me.id or ent.id, me and me.id or ent.id) end
            if ent.actor then
                if ent.actor.SetHealth then ent.actor:SetHealth(0) end
                if ent.actor.Fall then ent.actor:Fall(pos) end
                if ent.actor.Kill then ent.actor:Kill() end
            end
        end
        if ent.AwakePhysics then ent:AwakePhysics(1) end
        if ent.AddImpulse then
            ent:AddImpulse(-1, { x = pos.x, y = pos.y, z = pos.z + 1.2 }, { x = 0, y = 1, z = -0.2 }, 180, 1)
        end
    end)

    C.isSyncingDamage = false
end

local function record_local_kill(ent)
    local ep = ent:GetWorldPos()
    for _, k in ipairs(C.recentKills) do
        local dSq = (k.x - ep.x)^2 + (k.y - ep.y)^2 + (k.z - ep.z)^2
        if dSq < 2.25 then return end
    end

    C.killCounter = C.killCounter + 1
    local rolePrefix = C.isHost and "H" or "C"
    local killUid = string.format("%s%d", rolePrefix, C.killCounter)

    C.recentKills[#C.recentKills + 1] = {
        uid = killUid,
        x = ep.x, y = ep.y, z = ep.z,
        expireFrame = C.frame + 180
    }
    C.executedKills[killUid] = true
    log(string.format("Kill recorded -> %s (%.0f, %.0f)", tostring(ent:GetName()), ep.x, ep.y))
end

function C.scan_local_npcs_and_deaths(p)
    local myPos = p:GetWorldPos()
    if not C.archetypePalette or C.frame % 120 == 0 then
        update_archetype_palette(myPos, p.id)
    end

    local ents = System.GetEntitiesInSphere(myPos, 300) or {}
    local maxAlert = 0

    for _, e in pairs(ents) do
        if is_real_human(e, p.id) then
            local id = e.id
            local dead = is_npc_dead(e)
            local ep = e:GetWorldPos()
            local prev = C.knownNPCs[id]

            if not dead then
                if not prev then
                    C.knownNPCs[id] = { x = ep.x, y = ep.y, z = ep.z, wasAlive = true }
                else
                    prev.x, prev.y, prev.z = ep.x, ep.y, ep.z
                    prev.wasAlive = true
                end

                if AI and AI.GetAlertness then
                    local alr = AI.GetAlertness(id) or 0
                    if alr > maxAlert then maxAlert = alr end
                end
                local vel = (e.GetVelocity and e:GetVelocity()) or { x = 0, y = 0, z = 0 }
                if (vel.x * vel.x + vel.y * vel.y) > 8.0 and maxAlert < 1 then
                    maxAlert = 1
                end
            else
                if prev and prev.wasAlive then
                    prev.wasAlive = false
                    if not C.isSyncingDamage then
                        record_local_kill(e)
                    end
                end
            end
        end
    end

    if C.localAlertState > maxAlert then
        if C.frame % 60 == 0 then C.localAlertState = maxAlert end
    else
        C.localAlertState = maxAlert
    end
end

local function trigger_combat_alert_on_peer(alertPos, p)
    if not AI or (C.frame - C.remoteAlertCooldown < 60) then return end
    C.remoteAlertCooldown = C.frame

    local myPos = p:GetWorldPos()
    if AI.SoundEvent then
        pcall(AI.SoundEvent, alertPos, 250.0, AISOUND_WEAPON, p.id)
        pcall(AI.SoundEvent, myPos, 250.0, AISOUND_WEAPON, p.id)
    end

    local ents = System.GetEntitiesInSphere(myPos, 250) or {}
    for _, e in pairs(ents) do
        if is_real_human(e, p.id) and not is_npc_dead(e) then
            pcall(function()
                if AI.Signal then
                    AI.Signal(SIGNALFILTER_SENDER, 1, "OnBulletRain", e.id)
                    AI.Signal(SIGNALFILTER_SENDER, 1, "OnEnemySeen", e.id)
                end
                if not C.isHost and AI.SetBehaviorTreeEvaluationEnabled then
                    AI.SetBehaviorTreeEvaluationEnabled(e.id, false)
                end
            end)
        end
    end
end

function C.spawn_partner(p, customPos)
    if C.partnerId then
        local old = System.GetEntity(C.partnerId)
        if old then System.RemoveEntity(C.partnerId) end
        C.partnerId = nil
    end

    local myPos = p:GetWorldPos()
    local myAng = System.GetViewCameraAngles() or p:GetWorldAngles()
    local camDir = System.GetViewCameraDir()

    local spawnPos = customPos or {
        x = myPos.x + camDir.y * 2.2,
        y = myPos.y - camDir.x * 2.2,
        z = myPos.z + 0.1
    }

    local ents = System.GetEntitiesInSphere(myPos, 2000) or {}
    local bestArch, bestCls = nil, nil

    for _, e in pairs(ents) do
        if is_real_human(e, p.id) and e.GetArchetype then
            local arch = e:GetArchetype()
            if arch and not tostring(arch):lower():find("civilian") then
                bestArch = arch
                bestCls = e.class
                break
            end
        end
    end

    local partner = nil
    if bestArch and bestCls then
        local ok, e = pcall(System.SpawnEntity, {
            class = bestCls,
            archetype = bestArch,
            name = "Coop_Partner_Avatar",
            position = spawnPos,
            orientation = { x = 0, y = 1, z = 0 }
        })
        if ok and e then partner = e end
    end

    if not partner then
        local props = {}
        if BasicEntity and BasicEntity.Properties then
            for k, v in pairs(BasicEntity.Properties) do props[k] = v end
        end
        props.object_Model = "Objects/characters/players/jon/jon.cdf"
        local ok, e = pcall(System.SpawnEntity, {
            class = "BasicEntity",
            name = "Coop_Partner_Avatar",
            position = spawnPos,
            properties = props
        })
        if ok and e then partner = e end
    end

    if partner then
        C.partnerId = partner.id
        C.currentPos = { x = spawnPos.x, y = spawnPos.y, z = spawnPos.z }
        C.targetPos  = { x = spawnPos.x, y = spawnPos.y, z = spawnPos.z }
        C.targetAng  = { x = 0, y = 0, z = myAng.z }
        C.history = {}

        if partner.Activate then pcall(partner.Activate, partner, 1) end
        if partner.Event_Enable then pcall(partner.Event_Enable, partner) end
        if partner.actor then pcall(partner.actor.SetHealth, partner.actor, 99999) end

        if AI then
            pcall(AI.SetBehaviorTreeEvaluationEnabled, partner.id, false)
            pcall(AI.SetIgnorant, partner.id, 1)
            pcall(AI.ChangeParameter, partner.id, AIPARAM_PERCEPTIONSCALE_VISUAL, 0)
            pcall(AI.ChangeParameter, partner.id, AIPARAM_PERCEPTIONSCALE_AUDIO, 0)
            pcall(AI.ClearPotentialTargets, partner.id)
            pcall(AI.SetFactionOf, partner.id, "Players")
        end

        log(string.format("Partner spawned at (%.1f, %.1f, %.1f)", spawnPos.x, spawnPos.y, spawnPos.z))
    end
end

function C.teleport_to_partner(p)
    if not C.targetPos then
        log("No partner position yet!")
        return
    end
    local dest = { x = C.targetPos.x + 1.5, y = C.targetPos.y + 1.5, z = C.targetPos.z + 0.25 }
    p:SetWorldPos(dest)
    p:SetVelocity({ x = 0, y = 0, z = 0 })
    log("Teleported to partner!")
end


function C.send_unified_state(p)
    local myPos = p:GetWorldPos()
    local camAng = System.GetViewCameraAngles()
    local yaw = camAng and camAng.z or p:GetWorldAngles().z
    local crouch = (SGW3.IsKeyDown and SGW3.IsKeyDown(0x43)) and 1 or 0
    local tod = tonumber(System.GetCVar("e_TimeOfDay")) or 12.0

    local lines = {}
    lines[#lines + 1] = string.format("P|%.2f|%.2f|%.2f|%.2f|%d|%.2f|%d",
        myPos.x, myPos.y, myPos.z, yaw, crouch, tod, C.localAlertState)

    for i = #C.recentKills, 1, -1 do
        local k = C.recentKills[i]
        if C.frame > k.expireFrame then
            table.remove(C.recentKills, i)
        else
            lines[#lines + 1] = string.format("K|%s|%.1f|%.1f|%.1f",
                k.uid, k.x, k.y, k.z)
        end
    end

    if C.isHost then
        local ents = System.GetEntitiesInSphere(myPos, 260) or {}
        local candidates = {}

        for _, e in pairs(ents) do
            if is_real_human(e, p.id) and not is_npc_dead(e) then
                local ep = e:GetWorldPos()
                local dMy = (ep.x - myPos.x)^2 + (ep.y - myPos.y)^2
                local dPartner = C.targetPos and ((ep.x - C.targetPos.x)^2 + (ep.y - C.targetPos.y)^2) or 999999
                local minDist = math.min(dMy, dPartner)
                candidates[#candidates + 1] = { ent = e, dist = minDist, pos = ep }
            end
        end

        table.sort(candidates, function(a, b) return a.dist < b.dist end)

        local limit = math.min(#candidates, 16)
        for i = 1, limit do
            local e = candidates[i].ent
            local ep = candidates[i].pos
            local ea = e:GetWorldAngles()
            local spTag = get_short_spawn_tag(e)
            local archHash = e.GetArchetype and get_arch_hash(e:GetArchetype()) or "0"

            lines[#lines + 1] = string.format("N|%s|%s|%s|%.2f|%.2f|%.2f|%.2f",
                tostring(e.id), spTag, archHash, ep.x, ep.y, ep.z, ea.z)
        end
    end

    local f = io.open(C.posOutFile, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end
end

function C.poll_unified_state(p)
    local f = io.open(C.posInFile, "r")
    if not f then return end

    for line in f:lines() do
        local cmd = line:sub(1, 1)

        if cmd == "P" then
            local nx, ny, nz, nyaw, nst, ntod, nalr =
                line:match("^P|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?([^|]*)")
            local x, y, z = tonumber(nx), tonumber(ny), tonumber(nz)
            local yaw = tonumber(nyaw) or 0
            local remoteTod = tonumber(ntod)
            local remoteAlert = tonumber(nalr) or 0

            if not C.isHost and remoteTod then
                local myTod = tonumber(System.GetCVar("e_TimeOfDay")) or 12.0
                if math.abs(myTod - remoteTod) > 0.05 then
                    System.SetCVar("e_TimeOfDay", tostring(remoteTod))
                end
            end

            if x and y and z and (x ~= 0 or y ~= 0) then
                C.targetPos = { x = x, y = y, z = z }
                C.targetAng = { x = 0, y = 0, z = yaw }
                C.targetStance = tonumber(nst) or 0

                if not C.hasNetPos then
                    C.hasNetPos = true
                    log("Connected to partner! Press [F9] to teleport.")
                    if not C.partnerId or not System.GetEntity(C.partnerId) then
                        C.spawn_partner(p, C.targetPos)
                    else
                        C.currentPos = { x = x, y = y, z = z }
                    end
                end

                if remoteAlert > 0 then
                    trigger_combat_alert_on_peer(C.targetPos, p)
                end
            end

        elseif cmd == "K" then
            local uid, kx, ky, kz = line:match("^K|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
            if uid and not C.executedKills[uid] then
                local tx, ty, tz = tonumber(kx), tonumber(ky), tonumber(kz)
                local victim = find_alive_human_near(tx, ty, tz, p.id, 25.0)
                if victim then
                    C.executedKills[uid] = true
                    local bSlot = C.boundClientToSlot[victim.id]
                    if bSlot then C.aiTargets[bSlot] = nil end
                    C.boundClientToSlot[victim.id] = nil

                    execute_native_death(victim, p)
                    if C.knownNPCs[victim.id] then
                        C.knownNPCs[victim.id].wasAlive = false
                    end
                    log(string.format("Synced Partner Kill -> %s!", tostring(victim:GetName())))
                end
            end

        elseif cmd == "N" and not C.isHost then
            local slotId, spTag, archHash, sx, sy, sz, syaw =
                line:match("^N|([^|]+)|([^|]*)|([^|]*)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
            local ex, ey, ez = tonumber(sx), tonumber(sy), tonumber(sz)
            local eyaw = tonumber(syaw) or 0

            if slotId and ex and ey and ez then
                local rec = C.aiTargets[slotId]
                local npc = rec and rec.entId and System.GetEntity(rec.entId)

                if not npc or is_npc_dead(npc) then
                    local ents = System.GetEntitiesInSphere({ x = ex, y = ey, z = ez }, 55.0) or {}
                    local bestE, bestScore = nil, 999999

                    for _, cand in pairs(ents) do
                        if is_real_human(cand, p.id) and not is_npc_dead(cand) then
                            local existingSlot = C.boundClientToSlot[cand.id]
                            if not existingSlot or existingSlot == slotId or not C.aiTargets[existingSlot] then
                                local cp = cand:GetWorldPos()
                                local score = (cp.x - ex)^2 + (cp.y - ey)^2 + (cp.z - ez)^2

                                if spTag ~= "" and get_short_spawn_tag(cand) == spTag then
                                    score = score * 0.02
                                end
                                -- Дополнительный приоритет, если совпадает класс (архетип) врага!
                                local cArch = cand.GetArchetype and get_arch_hash(cand:GetArchetype()) or "0"
                                if archHash ~= "0" and cArch == archHash then
                                    score = score * 0.2
                                end

                                if score < bestScore then
                                    bestScore = score
                                    bestE = cand
                                end
                            end
                        end
                    end

                    npc = bestE
                    if npc then
                        npc = ensure_matching_enemy_class(npc, archHash, spTag)
                        C.boundClientToSlot[npc.id] = slotId

                        if AI and AI.SetBehaviorTreeEvaluationEnabled then
                            pcall(AI.SetBehaviorTreeEvaluationEnabled, npc.id, false)
                        end
                    end
                end

                if npc and not is_npc_dead(npc) then
                    C.aiTargets[slotId] = {
                        entId = npc.id,
                        x = ex, y = ey, z = ez,
                        yaw = eyaw,
                        lastSeen = C.frame
                    }
                end
            end
        end
    end
    f:close()
end

function C.update_client_npcs(dt)
    if C.isHost then return end

    for slotId, tgt in pairs(C.aiTargets) do
        if C.frame - (tgt.lastSeen or 0) > 60 then
            if tgt.entId then C.boundClientToSlot[tgt.entId] = nil end
            C.aiTargets[slotId] = nil
        else
            local npc = tgt.entId and System.GetEntity(tgt.entId)
            if npc and not is_npc_dead(npc) then
                local cur = npc:GetWorldPos()
                local curAng = npc:GetWorldAngles()

                local dx = tgt.x - cur.x
                local dy = tgt.y - cur.y
                local dz = tgt.z - cur.z
                local distSq = dx * dx + dy * dy + dz * dz

                if distSq > 25.0 then
                    npc:SetWorldPos({ x = tgt.x, y = tgt.y, z = tgt.z })
                    if npc.SetVelocity then
                        pcall(npc.SetVelocity, npc, { x = 0, y = 0, z = 0 })
                    end
                elseif distSq > 0.0004 then
                    local smoothFactor = math.min(1.0, dt * 12.0)
                    local nextPos = {
                        x = cur.x + dx * smoothFactor,
                        y = cur.y + dy * smoothFactor,
                        z = cur.z + dz * smoothFactor
                    }
                    npc:SetWorldPos(nextPos)

                    if npc.SetVelocity then
                        local vx = math.max(-7.0, math.min(7.0, dx * 8.0))
                        local vy = math.max(-7.0, math.min(7.0, dy * 8.0))
                        pcall(npc.SetVelocity, npc, { x = vx, y = vy, z = 0 })
                    end
                else
                    -- Бот стоит на месте
                    if npc.SetVelocity then
                        pcall(npc.SetVelocity, npc, { x = 0, y = 0, z = 0 })
                    end
                end

                local nextYaw = lerp_angle(curAng.z, tgt.yaw, dt * 14.0)
                npc:SetWorldAngles({ x = 0, y = 0, z = nextYaw })
            else
                if tgt.entId then C.boundClientToSlot[tgt.entId] = nil end
                C.aiTargets[slotId] = nil
            end
        end
    end
end

function C.install_damage_hook()
    if C.hookInstalled then return end
    local sp = rawget(_G, "SinglePlayer")
    if not sp or type(sp.ProcessActorDamage) ~= "function" then return end

    local prevHook = sp.ProcessActorDamage
    local wrapped = function(self, hit)
        local target = hit and hit.target
        local res = prevHook(self, hit)

        if not C.isSyncingDamage and target then
            local me = rawget(_G, "g_localActor")
            if me and target.id ~= me.id and target.id ~= C.partnerId and is_real_human(target, me.id) then
                if is_npc_dead(target) or (tonumber(hit.damage) or 0) >= 150 then
                    record_local_kill(target)
                end
                C.localAlertState = 2
            end
        end
        return res
    end

    sp.ProcessActorDamage = wrapped
    if TRAINER then TRAINER.padHook = wrapped end
    C.hookInstalled = true
    log("Smooth Walk & Enemy Class Sync v2.3.0 ready!")
end

function C.tick(p)
    C.frame = C.frame + 1
    C.install_damage_hook()
    if not p or not p.actor then return end

    local dt = math.min(System.GetFrameTime(), 0.1)

    if C.mode == "net" and C.frame % 30 == 0 then
        if tonumber(System.GetCVar("t_Scale")) ~= 1.0 then
            System.SetCVar("t_Scale", "1")
        end
    end

    if C.keyCooldown > 0 then C.keyCooldown = C.keyCooldown - 1 end
    if SGW3.IsKeyDown and C.keyCooldown == 0 then
        if SGW3.IsKeyDown(0x75) then -- F6
            C.keyCooldown = 30
            C.spawn_partner(p, C.hasNetPos and C.targetPos or nil)
        elseif SGW3.IsKeyDown(0x76) then -- F7
            C.keyCooldown = 30
            C.mode = (C.mode == "shadow") and "net" or "shadow"
            if C.mode == "net" then
                C.hasNetPos = false
                log("Switched to NET mode! Waiting for partner...")
            else
                log("Switched to SHADOW mode.")
            end
        elseif SGW3.IsKeyDown(0x77) then -- F8
            C.keyCooldown = 30
            C.isHost = not C.isHost
            C.aiTargets = {}
            C.boundClientToSlot = {}
            log("Role: " .. (C.isHost and "HOST (Master AI & Classes)" or "CLIENT (Smooth Walk & Class Sync)"))
        elseif SGW3.IsKeyDown(0x78) then -- F9
            C.keyCooldown = 30
            C.teleport_to_partner(p)
        end
    end

    local myPos = p:GetWorldPos()
    local camDir = System.GetViewCameraDir()
    local camAng = System.GetViewCameraAngles() or p:GetWorldAngles()

    if C.mode == "shadow" then
        local partner = C.partnerId and System.GetEntity(C.partnerId)
        if not partner then return end

        local rightX, rightY = camDir.y, -camDir.x
        local offsetPos = { x = myPos.x + rightX * 1.8, y = myPos.y + rightY * 1.8, z = myPos.z }
        C.history[#C.history + 1] = { pos = offsetPos, ang = { x = 0, y = 0, z = camAng.z } }
        if #C.history > 45 then
            local step = table.remove(C.history, 1)
            C.targetPos = step.pos
            C.targetAng = step.ang
        end
    else
        if C.frame % 3 == 0 then
            pcall(C.scan_local_npcs_and_deaths, p)
        end

        if C.frame % 2 == 0 then
            C.send_unified_state(p)
            C.poll_unified_state(p)
        end

        C.update_client_npcs(dt)
        if not C.hasNetPos then return end
    end

    local partner = C.partnerId and System.GetEntity(C.partnerId)
    if partner and C.targetPos and C.currentPos then
        local distSq = (C.targetPos.x - C.currentPos.x)^2 + (C.targetPos.y - C.currentPos.y)^2
        if distSq > 900.0 then
            C.currentPos = { x = C.targetPos.x, y = C.targetPos.y, z = C.targetPos.z }
        else
            C.currentPos = lerp_vec(C.currentPos, C.targetPos, math.min(1.0, dt * 16.0))
        end
        partner:SetWorldPos(C.currentPos)
        if C.targetAng then
            partner:SetWorldAngles({ x = 0, y = 0, z = C.targetAng.z })
        end
    end
end

SGW3.RegisterMod{ name = "SGW3 Co-op Mod", version = "2.3.0", author = "Coop Project" }
SGW3.OnTick("sgw3_coop", function(p) C.tick(p) end)
log("Co-op v2.3.0 SMOOTH WALK & CLASS SYNC loaded! [F6]=Spawn [F7]=Net [F8]=Role [F9]=Teleport")
