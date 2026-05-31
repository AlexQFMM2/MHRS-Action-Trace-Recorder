-- 这是一个独立的 REFramework 记录工具。
-- 目标是帮助我们在游戏里“实际打出某个动作”时，自动把和这个动作有关的关键信息记录下来：
-- 1. 当前武器类型
-- 2. 当前 motion id / motion bank
-- 3. 当前行为树 node id
-- 4. 当前 node 绑定的 action 列表
-- 5. 每个 action 的类型名，以及它的 _StartFrame / _EndFrame
--
-- 这样后续定位“某个 GP 动作到底对应哪个 ActionIndex”时，就不需要纯手工抄了。

local default_output_prefix = "ActionTraceRecorder"

-- 直接沿用已验证可用的东亚文字字形范围和字体映射。
-- 这些字体文件需要和 REFramework 脚本一起位于游戏可读取的位置。
local Glyph_ranges = {
    0x0020, 0x00FF,
    0x2000, 0x206F,
    0x3000, 0x30FF,
    0x31F0, 0x31FF,
    0x4e00, 0x9FFF,
    0xFF00, 0xFFEF,
    0,
}

local language_font = {}
language_font[0] = "NotoSansJP-Regular.otf"
language_font[11] = "NotoSansKR-Regular.otf"
language_font[12] = "NotoSansTC-Regular.otf"
language_font[13] = "NotoSansSC-Regular.otf"

for language, font_name in pairs(language_font) do
    language_font[language] = imgui.load_font(font_name, 19, Glyph_ranges)
end

local weapon_names = {
    [0] = "大剑",
    [1] = "斩斧",
    [2] = "太刀",
    [3] = "轻弩",
    [4] = "重弩",
    [5] = "大锤",
    [6] = "铳枪",
    [7] = "长枪",
    [8] = "片手剑",
    [9] = "双刀",
    [10] = "狩猎笛",
    [11] = "盾斧",
    [12] = "操虫棍",
    [13] = "弓"
}

local weapon_names_en = {
    [0] = "GreatSword",
    [1] = "SwitchAxe",
    [2] = "LongSword",
    [3] = "LightBowgun",
    [4] = "HeavyBowgun",
    [5] = "Hammer",
    [6] = "Gunlance",
    [7] = "Lance",
    [8] = "SwordAndShield",
    [9] = "DualBlades",
    [10] = "HuntingHorn",
    [11] = "ChargeBlade",
    [12] = "InsectGlaive",
    [13] = "Bow"
}

local state = {
    recording = false,
    weaponActionTraceEnabled = true,
    onlyWhenWeaponDrawn = true,
    records = {},
    lastSignature = nil,
    lastSavedCount = 0,
    currentInfo = nil,
    outputPath = default_output_prefix .. ".json",
    lastDumpPath = nil,
    lastHarvestMoonDumpPath = nil,
    lastMonsterTargetDumpPath = nil,
    harvestMoonTraceEnabled = true,
    harvestMoonEvents = {},
    nextHarvestMoonEventId = 1,
    monsterTargetTraceEnabled = true,
    monsterTargetSamples = {},
    nextMonsterTargetSampleId = 1,
    lastMonsterTargetSampleAt = nil,
    recentMotionIds = {},
    recentHitEvents = {},
    lastHitEvent = nil,
    nextHitEventId = 1
}

local save_records = nil

local max_reflection_field_count = 80
local max_reflection_property_count = 80
local max_member_catalog_count = 120
local focused_condition_indices = {
    [6944] = true,
    [6981] = true,
    [7026] = true,
    [7068] = true,
    [7069] = true,
    [7087] = true,
    [7088] = true
}
local focused_condition_type_names = {
    ["snow.player.fsm.PlayerFsm2ConditionQuestBaseSeeThrough"] = true,
    ["snow.player.fsm.PlayerFsm2ConditionQuestBaseDamage"] = true,
    ["snow.player.fsm.PlayerFsm2ConditionLongSwordIaiAutoCounter"] = true,
    ["snow.player.fsm.PlayerFsm2ConditionLongSwordIaiCounterDerived"] = true
}
local focused_action_indices = {
    [9250] = true,
    [9388] = true,
    [9393] = true,
    [9460] = true,
    [9529] = true,
    [9530] = true,
    [9531] = true
}
local focused_action_type_names = {
    ["snow.player.fsm.PlayerFsm2ActionSeeThroughAttack"] = true,
    ["snow.player.fsm.PlayerFsm2ActionEscape"] = true,
    ["snow.player.fsm.PlayerFsm2EscapeMutekiTimer"] = true,
    ["snow.player.fsm.PlayerFsm2MutekiTimer"] = true,
    ["snow.player.fsm.PlayerFsm2ActionLongSwordEscapeMutekiTimerIaiCounterStep"] = true,
    ["snow.player.fsm.PlayerFsm2ActionEscapeDamageCheck"] = true,
    ["snow.player.fsm.PlayerFsm2ActionLongSwordSuccessIaiCounter"] = true,
    ["snow.player.fsm.PlayerFsm2ActionLongSwordCreateSpacingShell"] = true,
    ["snow.player.fsm.PlayerFsm2ActionSetEffect"] = true,
    ["snow.player.fsm.PlayerFsm2ActionSetEffectAndScale"] = true
}
local focused_motion_ids = {
    [147] = true,
    [154] = true,
    [155] = true,
    [156] = true,
    [161] = true
}
local focused_node_name_markers = {
    "atk.atk_147",
    "atk.atk151",
    "atk.atk_161_MR",
    "atk.WireReplaceF_MR"
}
local method_catalog_keywords = {
    "frame",
    "damage",
    "guard",
    "muteki",
    "invincible",
    "just",
    "see",
    "through",
    "condition",
    "success",
    "counter",
    "iai",
    "evade",
    "escape",
    "auto",
    "derived",
    "armor",
    "timer",
    "spacing",
    "shell",
    "destroy",
    "disable",
    "active",
    "outside",
    "create",
    "target",
    "hate",
    "player",
    "enemy",
    "boss",
    "unique",
    "rank",
    "point",
    "lock",
    "aim"
}

local harvest_moon_node_id = 3736120076
local harvest_moon_action_indices = {
    9526,
    9527,
    9528,
    9529,
    9530,
    9531,
    9532,
    9533,
    9534,
    9535
}
local harvest_moon_type_names = {
    "snow.player.LongSword",
    "snow.shell.LongSwordShell010",
    "snow.shell.LongSwordShellManager",
    "snow.PlayerNetwork.LongSwordDestroySpacingShellPacket"
}

local monster_target_type_names = {
    "snow.enemy.EnemyManager",
    "snow.enemy.EnemyCharacterBase",
    "snow.enemy.EmBossCharacterBase",
    "snow.enemy.EnemyTargetInfo",
    "snow.enemy.EnemyTargetParam",
    "snow.enemy.EnemyTargetParam.EnemyHyakuryuHateSortInfo",
    "snow.enemy.aifsm.EnemyUpdateTarget",
    "snow.enemy.aifsm.EnemyPredatorUpdateTarget",
    "snow.enemy.aifsm.Ems091_05EnemyUpdateTarget",
    "snow.telemetry.kpi.Hate.HateCore",
    "snow.sensor.PerceptionCombatStateData",
    "snow.sensor.SensorLastDamage",
    "snow.sensor.SensorLastHit"
}

local monster_target_sample_interval = 0.50
local max_monster_target_samples = 80
local max_monster_target_objects = 12
local max_monster_target_values = 80

local monster_target_keywords = {
    "target",
    "hate",
    "player",
    "enemy",
    "boss",
    "unique",
    "rank",
    "point",
    "lock",
    "aim",
    "index",
    "type",
    "id"
}

local observed_monster_target_objects = {}
local observed_monster_target_seen = {}

-- 这些字段名是“优先尝试读取”的候选项。
-- 它们并不保证所有类型都存在，但能帮助我们把常见的帧、无敌、判定相关字段尽量抓出来。
local action_field_candidates = {
    "_StartFrame",
    "_EndFrame",
    "_Frame",
    "_frame",
    "Type",
    "_Type",
    "_EscapeType",
    "_ElementDebuffReduceFrame",
    "_AddFrame",
    "_AddTime",
    "_MutekiStartFrame",
    "_MutekiEndFrame",
    "_InvincibleStartFrame",
    "_InvincibleEndFrame",
    "_JustStartFrame",
    "_JustEndFrame",
    "_HyperArmorTimer",
    "_AngleRange",
    "_BaseScale",
    "_CurrentScale",
    "_ShellUniqueId",
    "_IsOutSide",
    "_lifeTime",
    "_Range",
    "_RangeY",
    "_WarningRange"
}

local condition_field_candidates = {
    "StartFrame",
    "EndFrame",
    "CkFrame",
    "CheckFrame",
    "Type",
    "_Type",
    "_StartFrame",
    "_EndFrame",
    "_CkFrame",
    "_CheckFrame",
    "_MutekiStartFrame",
    "_MutekiEndFrame"
}

local event_field_candidates = {
    "StartFrame",
    "EndFrame",
    "Type",
    "_Type",
    "_StartFrame",
    "_EndFrame"
}

math.randomseed(os.time())

local function now_string()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function now_file_string()
    return os.date("%Y%m%d_%H%M%S")
end

local function make_random_output_path(prefix)
    local random_part = math.random(1000, 9999)
    return prefix .. "_" .. now_file_string() .. "_" .. tostring(random_part) .. ".json"
end

local function get_uptime()
    local app = sdk.find_type_definition("via.Application")
    if not app then
        return 0
    end

    local method = app:get_method("get_UpTimeSecond")
    if not method then
        return 0
    end

    return method:call(nil)
end

local function clone_array(source)
    local result = {}

    for _, value in ipairs(source or {}) do
        table.insert(result, value)
    end

    return result
end

local function get_display_language()
    local option_manager = sdk.get_managed_singleton("snow.gui.OptionManager")
    if not option_manager then
        return nil
    end

    return option_manager:call("getDisplayLanguage()")
end

local function get_master_player()
    local player_manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not player_manager then
        return nil
    end

    return player_manager:call("findMasterPlayer")
end

local function get_type_name(obj)
    if not obj then
        return "NIL_OBJECT"
    end

    local ok, name = pcall(function()
        return obj:get_type_definition():get_full_name()
    end)

    if ok and name then
        return name
    end

    return "UNKNOWN_TYPE"
end

local function safe_get_field(obj, field_name)
    if not obj then
        return nil
    end

    local ok, value = pcall(function()
        return obj:get_field(field_name)
    end)

    if ok then
        return value
    end

    return nil
end

local function safe_call(fn)
    local ok, value = pcall(fn)
    if ok then
        return value
    end

    return nil
end

local function get_master_player_index()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    return safe_call(function()
        return master_player:call("getPlayerIndex")
    end)
end

local function get_master_player_object_hash()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    return safe_call(function()
        return master_player:call("get_GameObject"):call("GetHashCode")
    end)
end

local function push_recent_motion_id(motion_id)
    if motion_id == nil then
        return
    end

    table.insert(state.recentMotionIds, 1, tonumber(motion_id))

    while #state.recentMotionIds > 6 do
        table.remove(state.recentMotionIds)
    end
end

local function remember_hit_event(hit_event)
    state.lastHitEvent = hit_event
    table.insert(state.recentHitEvents, 1, hit_event)

    while #state.recentHitEvents > 12 do
        table.remove(state.recentHitEvents)
    end
end

local function serialize_simple_value(value)
    local value_type = type(value)

    if value_type == "nil" or value_type == "number" or value_type == "string" or value_type == "boolean" then
        return value
    end

    local text = safe_call(function()
        return tostring(value)
    end)

    if text ~= nil then
        return text
    end

    return "<UNSERIALIZABLE>"
end

local function is_simple_type_definition(type_definition)
    if type_definition == nil then
        return true
    end

    local type_name = safe_call(function()
        return type_definition:get_full_name()
    end) or "UNKNOWN_TYPE"

    return type_definition:is_value_type() or type_name == "System.String"
end

local function get_type_definition_name(type_definition)
    if type_definition == nil then
        return "UNKNOWN_TYPE"
    end

    return safe_call(function()
        return type_definition:get_full_name()
    end) or "UNKNOWN_TYPE"
end

local function collect_existing_fields(obj, candidates)
    local out = {}

    for _, field_name in ipairs(candidates) do
        local value = safe_get_field(obj, field_name)
        if value ~= nil then
            out[field_name] = value
        end
    end

    if next(out) == nil then
        return nil
    end

    return out
end

-- 这里用反射把对象上“当前能直接读到的简单字段”尽量扫出来。
-- 只抓值类型和字符串，避免把复杂对象整坨塞进 json 导致内容失控。
local function collect_reflection_fields(obj, max_count)
    if not obj then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local fields = safe_call(function()
            return current_type:get_fields()
        end)

        if fields then
            for _, field_desc in ipairs(fields) do
                if count >= max_count then
                    break
                end

                local field_name = safe_call(function()
                    return field_desc:get_name()
                end)

                if field_name ~= nil and not seen[field_name] then
                    seen[field_name] = true

                    local field_type = safe_call(function()
                        return field_desc:get_type()
                    end)
                    local field_type_name = get_type_definition_name(field_type)
                    local should_read = is_simple_type_definition(field_type)

                    if should_read then
                        local raw_value = safe_call(function()
                            return field_desc:get_data(obj)
                        end)

                        if raw_value ~= nil then
                            result[field_name] = {
                                typeName = field_type_name,
                                value = serialize_simple_value(raw_value)
                            }
                            count = count + 1
                        end
                    end
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if next(result) == nil then
        return nil
    end

    return result
end

-- 一些判定类对象的关键数据不一定挂在 field 上，也可能藏在零参数 getter 里。
-- 这里额外扫一遍“像属性一样的 getter”，专门补足 SeeThrough / Damage 一类对象的信息盲区。
local function collect_reflection_properties(obj, max_count)
    if not obj then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local methods = safe_call(function()
            return current_type:get_methods()
        end)

        if methods then
            for _, method in ipairs(methods) do
                if count >= max_count then
                    break
                end

                local method_name = safe_call(function()
                    return method:get_name()
                end)
                local param_count = safe_call(function()
                    return method:get_num_params()
                end)

                if method_name ~= nil and param_count == 0 then
                    local property_name = nil

                    if method_name:find("^get_") then
                        property_name = method_name:sub(5)
                    elseif method_name:find("^get") then
                        property_name = method_name:sub(4)
                    end

                    if property_name ~= nil and property_name ~= "" and not seen[property_name] then
                        seen[property_name] = true

                        local return_type = safe_call(function()
                            return method:get_return_type()
                        end)
                        local return_type_name = get_type_definition_name(return_type)

                        if is_simple_type_definition(return_type) then
                            local value = safe_call(function()
                                return method:call(obj)
                            end)

                            if value ~= nil then
                                result[property_name] = {
                                    getter = method_name,
                                    typeName = return_type_name,
                                    value = serialize_simple_value(value)
                                }
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if next(result) == nil then
        return nil
    end

    return result
end

local function collect_type_hierarchy(obj)
    if not obj then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if not type_definition then
        return nil
    end

    local result = {}
    local current_type = type_definition

    while current_type ~= nil do
        table.insert(result, get_type_definition_name(current_type))
        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if #result == 0 then
        return nil
    end

    return result
end

local function matches_method_keyword(name)
    if not name then
        return false
    end

    local lower = name:lower()
    for _, keyword in ipairs(method_catalog_keywords) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end

    return false
end

local function collect_field_catalog(obj, max_count)
    if not obj then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local fields = safe_call(function()
            return current_type:get_fields()
        end)

        if fields then
            for _, field_desc in ipairs(fields) do
                if count >= max_count then
                    break
                end

                local field_name = safe_call(function()
                    return field_desc:get_name()
                end)

                if field_name ~= nil and not seen[field_name] then
                    seen[field_name] = true
                    local field_type = safe_call(function()
                        return field_desc:get_type()
                    end)

                    table.insert(result, {
                        name = field_name,
                        typeName = get_type_definition_name(field_type),
                        declaringType = declaring_type,
                        readableSimpleValue = is_simple_type_definition(field_type)
                    })
                    count = count + 1
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if #result == 0 then
        return nil
    end

    return result
end

local function collect_method_catalog(obj, max_count)
    if not obj then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local methods = safe_call(function()
            return current_type:get_methods()
        end)

        if methods then
            for _, method in ipairs(methods) do
                if count >= max_count then
                    break
                end

                local method_name = safe_call(function()
                    return method:get_name()
                end)
                local param_count = safe_call(function()
                    return method:get_num_params()
                end)
                local return_type = safe_call(function()
                    return method:get_return_type()
                end)
                local signature_key = table.concat({
                    tostring(method_name),
                    tostring(param_count),
                    get_type_definition_name(return_type)
                }, "|")

                local getter_like = method_name ~= nil and (method_name:find("^get_") or method_name:find("^get"))
                local should_keep = getter_like or matches_method_keyword(method_name)

                if should_keep and not seen[signature_key] then
                    seen[signature_key] = true
                    table.insert(result, {
                        name = method_name,
                        declaringType = declaring_type,
                        paramCount = param_count,
                        returnType = get_type_definition_name(return_type),
                        getterLike = getter_like and true or false,
                        readableSimpleValue = is_simple_type_definition(return_type)
                    })
                    count = count + 1
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if #result == 0 then
        return nil
    end

    return result
end

local function collect_type_field_catalog(type_definition, max_count)
    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local fields = safe_call(function()
            return current_type:get_fields()
        end)

        if fields then
            for _, field_desc in ipairs(fields) do
                if count >= max_count then
                    break
                end

                local field_name = safe_call(function()
                    return field_desc:get_name()
                end)

                if field_name ~= nil and not seen[field_name] then
                    seen[field_name] = true
                    local field_type = safe_call(function()
                        return field_desc:get_type()
                    end)

                    table.insert(result, {
                        name = field_name,
                        typeName = get_type_definition_name(field_type),
                        declaringType = declaring_type,
                        readableSimpleValue = is_simple_type_definition(field_type)
                    })
                    count = count + 1
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if #result == 0 then
        return nil
    end

    return result
end

local function collect_type_method_catalog(type_definition, max_count)
    if not type_definition then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local methods = safe_call(function()
            return current_type:get_methods()
        end)

        if methods then
            for _, method in ipairs(methods) do
                if count >= max_count then
                    break
                end

                local method_name = safe_call(function()
                    return method:get_name()
                end)
                local param_count = safe_call(function()
                    return method:get_num_params()
                end)
                local return_type = safe_call(function()
                    return method:get_return_type()
                end)
                local signature_key = table.concat({
                    tostring(method_name),
                    tostring(param_count),
                    get_type_definition_name(return_type),
                    declaring_type
                }, "|")

                local getter_like = method_name ~= nil and (method_name:find("^get_") or method_name:find("^get"))
                local should_keep = getter_like or matches_method_keyword(method_name)

                if should_keep and not seen[signature_key] then
                    seen[signature_key] = true
                    table.insert(result, {
                        name = method_name,
                        declaringType = declaring_type,
                        paramCount = param_count,
                        returnType = get_type_definition_name(return_type),
                        getterLike = getter_like and true or false,
                        readableSimpleValue = is_simple_type_definition(return_type)
                    })
                    count = count + 1
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if #result == 0 then
        return nil
    end

    return result
end

local function build_type_definition_catalog(type_name)
    local type_definition = sdk.find_type_definition(type_name)
    if not type_definition then
        return {
            typeName = type_name,
            found = false
        }
    end

    local hierarchy = {}
    local current_type = type_definition
    while current_type ~= nil do
        table.insert(hierarchy, get_type_definition_name(current_type))
        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    return {
        typeName = type_name,
        found = true,
        hierarchy = hierarchy,
        fields = collect_type_field_catalog(type_definition, max_member_catalog_count),
        methods = collect_type_method_catalog(type_definition, max_member_catalog_count)
    }
end

local function get_object_address(obj)
    if not obj then
        return nil
    end

    local memory_view = safe_call(function()
        return obj:as_memoryview()
    end)

    if not memory_view then
        return nil
    end

    return safe_call(function()
        return tostring(memory_view:get_address())
    end)
end

local function is_focused_condition(condition_info)
    if not condition_info then
        return false
    end

    if focused_condition_indices[tonumber(condition_info.index)] then
        return true
    end

    return focused_condition_type_names[tostring(condition_info.typeName)] == true
end

local function is_focused_action(action_info)
    if not action_info then
        return false
    end

    if focused_action_indices[tonumber(action_info.index)] then
        return true
    end

    return focused_action_type_names[tostring(action_info.typeName)] == true
end

local function is_focused_node_name(node_name)
    if not node_name then
        return false
    end

    for _, marker in ipairs(focused_node_name_markers) do
        if node_name:find(marker, 1, true) then
            return true
        end
    end

    return false
end

local function should_build_focused_probe(motion_id, node_name, focus_conditions, actions)
    if focused_motion_ids[tonumber(motion_id)] then
        return true
    end

    if is_focused_node_name(node_name) then
        return true
    end

    for _, action_info in ipairs(actions or {}) do
        if is_focused_action(action_info) then
            return true
        end
    end

    return focus_conditions ~= nil and #focus_conditions > 0
end

local function build_global_probe_map(tree, index_map, probe_builder)
    local result = {}

    for index, _ in pairs(index_map or {}) do
        result[tostring(index)] = probe_builder(tree, index)
    end

    return result
end

local function get_collection_size(collection)
    if not collection then
        return 0
    end

    local ok, value = pcall(function()
        return collection:size()
    end)

    if ok and value ~= nil then
        return value
    end

    ok, value = pcall(function()
        return collection:get_size()
    end)

    if ok and value ~= nil then
        return value
    end

    return 0
end

local function get_player_game_object(master_player)
    if not master_player then
        return nil
    end

    return master_player:call("get_GameObject")
end

local function get_behavior_tree(player_game_object)
    if not player_game_object then
        return nil
    end

    return player_game_object:call("getComponent(System.Type)", sdk.typeof("via.behaviortree.BehaviorTree"))
end

local function get_tree_object(player_game_object)
    if not player_game_object then
        return nil
    end

    local motion_fsm2 = player_game_object:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
    if not motion_fsm2 then
        return nil
    end

    local layer = motion_fsm2:call("getLayer", 0)
    if not layer then
        return nil
    end

    return layer:get_tree_object()
end

local function get_action_object(tree, action_index)
    if not tree then
        return nil
    end

    local actions = tree:get_actions()
    if not actions or action_index == nil or action_index < 0 or action_index >= actions:size() then
        return nil
    end

    return actions[action_index]
end

local function get_condition_object(tree, condition_index)
    if not tree then
        return nil
    end

    local conditions = tree:get_conditions()
    if not conditions or condition_index == nil or condition_index < 0 or condition_index >= conditions:size() then
        return nil
    end

    return conditions[condition_index]
end

local function get_event_object(tree, event_index)
    if not tree then
        return nil
    end

    local events = tree:get_transitions()
    if not events or event_index == nil or event_index < 0 or event_index >= events:size() then
        return nil
    end

    return events[event_index]
end

local function get_action_info(tree, action_index, include_deep_fields)
    if not tree then
        return nil
    end

    local actions = tree:get_actions()
    if not actions or action_index < 0 or action_index >= actions:size() then
        return {
            index = action_index,
            typeName = "INVALID_ACTION_INDEX"
        }
    end

    local action_obj = actions[action_index]
    if not action_obj then
        return {
            index = action_index,
            typeName = "NIL_ACTION_OBJECT"
        }
    end

    return {
        index = action_index,
        typeName = get_type_name(action_obj),
        startFrame = action_obj:get_field("_StartFrame"),
        endFrame = action_obj:get_field("_EndFrame"),
        fields = collect_existing_fields(action_obj, action_field_candidates),
        scannedFields = include_deep_fields and collect_reflection_fields(action_obj, max_reflection_field_count) or nil,
        scannedProperties = include_deep_fields and collect_reflection_properties(action_obj, max_reflection_property_count) or nil,
        typeHierarchy = include_deep_fields and collect_type_hierarchy(action_obj) or nil
    }
end

local function get_condition_info(tree, condition_index, include_deep_fields)
    if not tree then
        return nil
    end

    local conditions = tree:get_conditions()
    if not conditions or condition_index < 0 or condition_index >= conditions:size() then
        return {
            index = condition_index,
            typeName = "INVALID_CONDITION_INDEX"
        }
    end

    local condition_obj = conditions[condition_index]
    if not condition_obj then
        return {
            index = condition_index,
            typeName = "NIL_CONDITION_OBJECT"
        }
    end

    return {
        index = condition_index,
        typeName = get_type_name(condition_obj),
        fields = collect_existing_fields(condition_obj, condition_field_candidates),
        scannedFields = include_deep_fields and collect_reflection_fields(condition_obj, max_reflection_field_count) or nil,
        scannedProperties = include_deep_fields and collect_reflection_properties(condition_obj, max_reflection_property_count) or nil,
        typeHierarchy = include_deep_fields and collect_type_hierarchy(condition_obj) or nil
    }
end

local function get_transition_event_info(tree, event_index, include_deep_fields)
    if not tree then
        return nil
    end

    local events = tree:get_transitions()
    if not events or event_index < 0 or event_index >= events:size() then
        return {
            index = event_index,
            typeName = "INVALID_EVENT_INDEX"
        }
    end

    local event_obj = events[event_index]
    if not event_obj then
        return {
            index = event_index,
            typeName = "NIL_EVENT_OBJECT"
        }
    end

    return {
        index = event_index,
        typeName = get_type_name(event_obj),
        fields = collect_existing_fields(event_obj, event_field_candidates),
        scannedFields = include_deep_fields and collect_reflection_fields(event_obj, max_reflection_field_count) or nil,
        scannedProperties = include_deep_fields and collect_reflection_properties(event_obj, max_reflection_property_count) or nil,
        typeHierarchy = include_deep_fields and collect_type_hierarchy(event_obj) or nil
    }
end

local function get_event_list(tree, event_index_collection, include_deep_fields)
    local result = {}
    local size = get_collection_size(event_index_collection)

    for i = 0, size - 1 do
        local event_index = tonumber(event_index_collection[i])
        table.insert(result, get_transition_event_info(tree, event_index, include_deep_fields))
    end

    return result
end

local function get_action_probe(tree, action_index)
    local info = get_action_info(tree, action_index, true)
    local action_obj = get_action_object(tree, action_index)

    if not info then
        return nil
    end

    info.objectAddress = get_object_address(action_obj)
    info.fieldCatalog = collect_field_catalog(action_obj, max_member_catalog_count)
    info.methodCatalog = collect_method_catalog(action_obj, max_member_catalog_count)
    return info
end

local function collect_matched_action_probes(tree, actions)
    local result = {}

    for _, action_info in ipairs(actions or {}) do
        if is_focused_action(action_info) then
            table.insert(result, get_action_probe(tree, action_info.index))
        end
    end

    return result
end

local function get_condition_probe(tree, condition_index)
    local info = get_condition_info(tree, condition_index, true)
    local condition_obj = get_condition_object(tree, condition_index)

    if not info then
        return nil
    end

    info.objectAddress = get_object_address(condition_obj)
    info.fieldCatalog = collect_field_catalog(condition_obj, max_member_catalog_count)
    info.methodCatalog = collect_method_catalog(condition_obj, max_member_catalog_count)
    return info
end

local function get_event_probe(tree, event_index)
    local info = get_transition_event_info(tree, event_index, true)
    local event_obj = get_event_object(tree, event_index)

    if not info then
        return nil
    end

    info.objectAddress = get_object_address(event_obj)
    info.fieldCatalog = collect_field_catalog(event_obj, max_member_catalog_count)
    info.methodCatalog = collect_method_catalog(event_obj, max_member_catalog_count)
    return info
end

local function get_node_parent_summary(node)
    local parent = safe_call(function()
        return node:get_parent()
    end)

    if not parent then
        return nil
    end

    return {
        id = safe_call(function()
            return parent:get_id()
        end),
        name = safe_call(function()
            return parent:get_full_name()
        end)
    }
end

local function get_node_target_summary(tree, state_index, options)
    options = options or {}
    local nodes = tree and tree:get_nodes()
    if not nodes or state_index == nil or state_index < 0 or state_index >= get_collection_size(nodes) then
        return {
            stateIndex = state_index,
            nodeId = nil,
            nodeName = "INVALID_STATE_INDEX"
        }
    end

    local node = nodes[state_index]
    if not node then
        return {
            stateIndex = state_index,
            nodeId = nil,
            nodeName = "NIL_STATE_NODE"
        }
    end

    local node_data = node:get_data()
    local action_indices = {}
    local action_types = {}
    local actions = node_data and node_data:get_actions()

    for i = 0, get_collection_size(actions) - 1 do
        local action_index = tonumber(actions[i])
        local action_info = get_action_info(tree, action_index, false)
        table.insert(action_indices, action_index)
        table.insert(action_types, action_info and action_info.typeName or "UNKNOWN_ACTION")
    end

    local summary = {
        stateIndex = state_index,
        nodeId = node:get_id(),
        nodeName = node:get_full_name(),
        actionIndices = action_indices,
        actionTypes = action_types,
        transitionCount = get_collection_size(node_data and node_data:get_transition_conditions()),
        startTransitionCount = get_collection_size(node_data and node_data:get_start_transitions())
    }

    if options.includeTransitionPreview and node_data then
        local preview = {}
        local transition_conditions = node_data:get_transition_conditions()
        local transition_states = node_data:get_states()
        local size = math.min(get_collection_size(transition_conditions), get_collection_size(transition_states))

        for i = 0, size - 1 do
            local condition_index = tonumber(transition_conditions[i])
            local target_state = tonumber(transition_states[i])
            local condition_info = get_condition_info(tree, condition_index, false)
            local focused_condition_info = nil

            if options.includeFocusConditionDetails and is_focused_condition(condition_info) then
                focused_condition_info = get_condition_info(tree, condition_index, true)
            end

            table.insert(preview, {
                slot = i,
                conditionIndex = condition_index,
                conditionType = condition_info and condition_info.typeName or "UNKNOWN_CONDITION",
                conditionFields = condition_info and condition_info.fields or nil,
                conditionScannedFields = focused_condition_info and focused_condition_info.scannedFields or nil,
                conditionScannedProperties = focused_condition_info and focused_condition_info.scannedProperties or nil,
                conditionTypeHierarchy = focused_condition_info and focused_condition_info.typeHierarchy or nil,
                targetState = target_state
            })
        end

        summary.transitionPreview = preview
    end

    return summary
end

local function get_transition_entries(tree, condition_collection, state_collection, event_collection, options)
    options = options or {}
    local entries = {}
    local size = math.min(get_collection_size(condition_collection), get_collection_size(state_collection))

    for i = 0, size - 1 do
        local condition_index = tonumber(condition_collection[i])
        local target_state = tonumber(state_collection[i])
        local events = nil

        if event_collection ~= nil then
            events = get_event_list(tree, event_collection[i], options.includeDeepEventFields)
        end

        table.insert(entries, {
            slot = i,
            condition = get_condition_info(tree, condition_index, options.includeDeepConditionFields),
            targetState = target_state,
            events = events,
            targetNode = options.includeTargetNodeSummary and get_node_target_summary(tree, target_state, {
                includeTransitionPreview = options.includeTargetTransitionPreview,
                includeFocusConditionDetails = options.includeFocusConditionDetails
            }) or nil
        })
    end

    return entries
end

local function append_focus_condition_entry(result, dedupe, entry)
    local key = table.concat({
        tostring(entry.sourceKind),
        tostring(entry.sourceNodeId),
        tostring(entry.sourceSlot),
        tostring(entry.parentTransitionSlot),
        tostring(entry.condition and entry.condition.index),
        tostring(entry.targetState)
    }, "|")

    if dedupe[key] then
        return
    end

    dedupe[key] = true
    table.insert(result, entry)
end

local function collect_focus_conditions_from_transitions(result, dedupe, source_kind, source_node_id, source_node_name, transitions)
    for _, transition in ipairs(transitions or {}) do
        local condition_info = transition.condition
        if is_focused_condition(condition_info) then
            append_focus_condition_entry(result, dedupe, {
                sourceKind = source_kind,
                sourceNodeId = source_node_id,
                sourceNodeName = source_node_name,
                sourceSlot = transition.slot,
                condition = condition_info,
                targetState = transition.targetState,
                targetNode = transition.targetNode
            })
        end

        local target_node = transition.targetNode or {}
        for _, preview in ipairs(target_node.transitionPreview or {}) do
            local preview_condition = {
                index = preview.conditionIndex,
                typeName = preview.conditionType,
                fields = preview.conditionFields,
                scannedFields = preview.conditionScannedFields,
                scannedProperties = preview.conditionScannedProperties,
                typeHierarchy = preview.conditionTypeHierarchy
            }

            if is_focused_condition(preview_condition) then
                append_focus_condition_entry(result, dedupe, {
                    sourceKind = source_kind .. ".targetPreview",
                    sourceNodeId = target_node.nodeId,
                    sourceNodeName = target_node.nodeName,
                    sourceSlot = preview.slot,
                    parentTransitionSlot = transition.slot,
                    parentTargetState = transition.targetState,
                    parentTargetNodeName = target_node.nodeName,
                    condition = preview_condition,
                    targetState = preview.targetState,
                    targetNode = nil
                })
            end
        end
    end
end

local function build_focus_condition_report(node_id, node_name, transitions, start_transitions)
    local result = {}
    local dedupe = {}

    collect_focus_conditions_from_transitions(result, dedupe, "transition", node_id, node_name, transitions)
    collect_focus_conditions_from_transitions(result, dedupe, "startTransition", node_id, node_name, start_transitions)

    return result
end

local function build_node_probe(tree, node)
    if not tree or not node then
        return nil
    end

    local node_data = node:get_data()
    if not node_data then
        return nil
    end

    local action_probes = {}
    local node_actions = node_data:get_actions()
    for i = 0, get_collection_size(node_actions) - 1 do
        local action_index = tonumber(node_actions[i])
        table.insert(action_probes, get_action_probe(tree, action_index))
    end

    local transitions = get_transition_entries(
        tree,
        node_data:get_transition_conditions(),
        node_data:get_states(),
        node_data:get_transition_events(),
        {
            includeDeepConditionFields = true,
            includeDeepEventFields = true,
            includeTargetNodeSummary = true,
            includeTargetTransitionPreview = true,
            includeFocusConditionDetails = true
        }
    )

    local start_transitions = get_transition_entries(
        tree,
        node_data:get_start_transitions(),
        node_data:get_start_states(),
        nil,
        {
            includeDeepConditionFields = true,
            includeTargetNodeSummary = true,
            includeTargetTransitionPreview = true,
            includeFocusConditionDetails = true
        }
    )

    return {
        id = node:get_id(),
        name = node:get_full_name(),
        parent = get_node_parent_summary(node),
        actions = action_probes,
        transitions = transitions,
        startTransitions = start_transitions,
        focusConditions = build_focus_condition_report(node:get_id(), node:get_full_name(), transitions, start_transitions)
    }
end

local function get_node_probe_by_state(tree, state_index)
    local nodes = tree and tree:get_nodes()
    if not nodes or state_index == nil or state_index < 0 or state_index >= get_collection_size(nodes) then
        return nil
    end

    return build_node_probe(tree, nodes[state_index])
end

local function build_focused_probe(tree, node, motion_id, focus_conditions)
    if not tree or not node then
        return nil
    end

    local focus_condition_probes = {}
    local related_state_seen = {}
    local related_node_probes = {}

    local function add_related_state(state_index)
        if state_index == nil or related_state_seen[state_index] then
            return
        end

        related_state_seen[state_index] = true
        local node_probe = get_node_probe_by_state(tree, state_index)
        if node_probe ~= nil then
            table.insert(related_node_probes, node_probe)
        end
    end

    for _, item in ipairs(focus_conditions or {}) do
        local cond_index = item.condition and item.condition.index or nil
        local probe = {
            sourceKind = item.sourceKind,
            sourceNodeId = item.sourceNodeId,
            sourceNodeName = item.sourceNodeName,
            sourceSlot = item.sourceSlot,
            parentTransitionSlot = item.parentTransitionSlot,
            parentTargetState = item.parentTargetState,
            parentTargetNodeName = item.parentTargetNodeName,
            targetState = item.targetState,
            condition = cond_index ~= nil and get_condition_probe(tree, cond_index) or item.condition,
            targetNode = item.targetNode,
            resolvedTargetNode = get_node_probe_by_state(tree, item.targetState)
        }

        table.insert(focus_condition_probes, probe)
        add_related_state(item.targetState)
    end

    local source_node_probe = build_node_probe(tree, node)

    return {
        motionId = motion_id,
        nodeId = node:get_id(),
        nodeName = node:get_full_name(),
        sourceNode = source_node_probe,
        sourceMatchedActions = collect_matched_action_probes(tree, source_node_probe and source_node_probe.actions or nil),
        focusConditionProbes = focus_condition_probes,
        globalFocusedActions = build_global_probe_map(tree, focused_action_indices, get_action_probe),
        globalFocusedConditions = build_global_probe_map(tree, focused_condition_indices, get_condition_probe),
        relatedNodes = related_node_probes
    }
end

local function get_all_actions(tree)
    local result = {}
    if not tree then
        return result
    end

    local actions = tree:get_actions()
    local size = get_collection_size(actions)

    for i = 0, size - 1 do
        table.insert(result, get_action_info(tree, i, false))
    end

    return result
end

local function get_all_conditions(tree)
    local result = {}
    if not tree then
        return result
    end

    local conditions = tree:get_conditions()
    local size = get_collection_size(conditions)

    for i = 0, size - 1 do
        table.insert(result, get_condition_info(tree, i))
    end

    return result
end

local function get_all_events(tree)
    local result = {}
    if not tree then
        return result
    end

    local events = tree:get_transitions()
    local size = get_collection_size(events)

    for i = 0, size - 1 do
        table.insert(result, get_transition_event_info(tree, i))
    end

    return result
end

local function get_node_entry(tree, node, state_index)
    local node_data = node:get_data()
    local action_indices = {}
    local node_actions = node_data:get_actions()
    local action_size = get_collection_size(node_actions)

    for i = 0, action_size - 1 do
        table.insert(action_indices, tonumber(node_actions[i]))
    end

    return {
        stateIndex = state_index,
        id = node:get_id(),
        name = node:get_full_name(),
        parent = get_node_parent_summary(node),
        actions = action_indices,
        transitions = get_transition_entries(
            tree,
            node_data:get_transition_conditions(),
            node_data:get_states(),
            node_data:get_transition_events(),
            nil
        ),
        startTransitions = get_transition_entries(
            tree,
            node_data:get_start_transitions(),
            node_data:get_start_states(),
            nil,
            nil
        )
    }
end

local function get_all_nodes(tree)
    local result = {}
    if not tree then
        return result
    end

    local nodes = tree:get_nodes()
    local size = get_collection_size(nodes)

    for i = 0, size - 1 do
        table.insert(result, get_node_entry(tree, nodes[i], i))
    end

    return result
end

local function build_tree_dump()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    local player_game_object = get_player_game_object(master_player)
    local behavior_tree = get_behavior_tree(player_game_object)
    local tree = get_tree_object(player_game_object)
    if not behavior_tree or not tree then
        return nil
    end

    local weapon_type = master_player:get_field("_playerWeaponType")

    return {
        version = 1,
        dumpedAt = now_string(),
        uptime = get_uptime(),
        weaponType = weapon_type,
        weaponName = weapon_names[weapon_type] or ("未知武器(" .. tostring(weapon_type) .. ")"),
        weaponNameEn = weapon_names_en[weapon_type] or ("WeaponType" .. tostring(weapon_type)),
        currentNodeId = behavior_tree:call("getCurrentNodeID", 0),
        counts = {
            actions = get_collection_size(tree:get_actions()),
            conditions = get_collection_size(tree:get_conditions()),
            events = get_collection_size(tree:get_transitions()),
            nodes = get_collection_size(tree:get_nodes())
        },
        actions = get_all_actions(tree),
        conditions = get_all_conditions(tree),
        events = get_all_events(tree),
        nodes = get_all_nodes(tree)
    }
end

local function build_harvest_moon_dump()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    local player_game_object = get_player_game_object(master_player)
    local behavior_tree = get_behavior_tree(player_game_object)
    local tree = get_tree_object(player_game_object)
    if not behavior_tree or not tree then
        return nil
    end

    local weapon_type = master_player:get_field("_playerWeaponType")
    local target_node = tree:get_node_by_id(harvest_moon_node_id)
    local action_probes = {}
    local type_catalogs = {}

    for _, action_index in ipairs(harvest_moon_action_indices) do
        table.insert(action_probes, get_action_probe(tree, action_index))
    end

    for _, type_name in ipairs(harvest_moon_type_names) do
        table.insert(type_catalogs, build_type_definition_catalog(type_name))
    end

    return {
        version = 1,
        dumpedAt = now_string(),
        uptime = get_uptime(),
        weaponType = weapon_type,
        weaponName = weapon_names[weapon_type] or ("未知武器(" .. tostring(weapon_type) .. ")"),
        weaponNameEn = weapon_names_en[weapon_type] or ("WeaponType" .. tostring(weapon_type)),
        currentNodeId = behavior_tree:call("getCurrentNodeID", 0),
        harvestMoonNodeId = harvest_moon_node_id,
        harvestMoonNode = target_node and build_node_probe(tree, target_node) or nil,
        harvestMoonActions = action_probes,
        relatedTypes = type_catalogs,
        recordedHarvestMoonEvents = clone_array(state.harvestMoonEvents)
    }
end

local function matches_monster_target_keyword(name)
    if not name then
        return false
    end

    local lower = tostring(name):lower()
    for _, keyword in ipairs(monster_target_keywords) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end

    return false
end

local function is_probable_runtime_object(value)
    if value == nil then
        return false
    end

    local value_type = type(value)
    if value_type == "number" or value_type == "string" or value_type == "boolean" then
        return false
    end

    return safe_call(function()
        return value:get_type_definition() ~= nil
    end) == true
end

local function get_runtime_collection_size(collection)
    if collection == nil then
        return 0
    end

    local size = get_collection_size(collection)
    if size > 0 then
        return size
    end

    local getter_names = {
        "get_Count",
        "get_Length",
        "get_Size",
        "get_count",
        "get_length"
    }

    for _, getter_name in ipairs(getter_names) do
        local value = safe_call(function()
            return collection:call(getter_name)
        end)

        if value ~= nil then
            return tonumber(value) or 0
        end
    end

    return 0
end

local function get_runtime_collection_item(collection, index)
    if collection == nil then
        return nil
    end

    local item = safe_call(function()
        return collection[index]
    end)

    if item ~= nil then
        return item
    end

    local getter_names = {
        "get_Item(System.Int32)",
        "get_Item",
        "get(System.Int32)",
        "get",
        "at(System.Int32)",
        "at"
    }

    for _, getter_name in ipairs(getter_names) do
        item = safe_call(function()
            return collection:call(getter_name, index)
        end)

        if item ~= nil then
            return item
        end
    end

    return nil
end

local function collect_monster_target_fields(obj, max_count)
    if obj == nil then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if type_definition == nil then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local fields = safe_call(function()
            return current_type:get_fields()
        end)

        if fields then
            for _, field_desc in ipairs(fields) do
                if count >= max_count then
                    break
                end

                local field_name = safe_call(function()
                    return field_desc:get_name()
                end)

                if field_name ~= nil and not seen[field_name] and matches_monster_target_keyword(field_name) then
                    seen[field_name] = true

                    local field_type = safe_call(function()
                        return field_desc:get_type()
                    end)

                    if is_simple_type_definition(field_type) then
                        local value = safe_call(function()
                            return field_desc:get_data(obj)
                        end)

                        if value ~= nil then
                            result[field_name] = {
                                typeName = get_type_definition_name(field_type),
                                declaringType = declaring_type,
                                value = serialize_simple_value(value)
                            }
                            count = count + 1
                        end
                    end
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if next(result) == nil then
        return nil
    end

    return result
end

local function collect_monster_target_getters(obj, max_count)
    if obj == nil then
        return nil
    end

    local type_definition = safe_call(function()
        return obj:get_type_definition()
    end)

    if type_definition == nil then
        return nil
    end

    local result = {}
    local seen = {}
    local count = 0
    local current_type = type_definition

    while current_type ~= nil do
        local declaring_type = get_type_definition_name(current_type)
        local methods = safe_call(function()
            return current_type:get_methods()
        end)

        if methods then
            for _, method in ipairs(methods) do
                if count >= max_count then
                    break
                end

                local method_name = safe_call(function()
                    return method:get_name()
                end)
                local param_count = safe_call(function()
                    return method:get_num_params()
                end)

                local getter_like = method_name ~= nil and (
                    method_name:find("^get_") or
                    method_name:find("^get") or
                    method_name:find("^is") or
                    method_name:find("^has")
                )

                if method_name ~= nil and param_count == 0 and getter_like and matches_monster_target_keyword(method_name) and not seen[method_name] then
                    seen[method_name] = true

                    local return_type = safe_call(function()
                        return method:get_return_type()
                    end)

                    if is_simple_type_definition(return_type) then
                        local value = safe_call(function()
                            return method:call(obj)
                        end)

                        if value ~= nil then
                            result[method_name] = {
                                typeName = get_type_definition_name(return_type),
                                declaringType = declaring_type,
                                value = serialize_simple_value(value)
                            }
                            count = count + 1
                        end
                    end
                end
            end
        end

        if count >= max_count then
            break
        end

        current_type = safe_call(function()
            return current_type:get_parent_type()
        end)
    end

    if next(result) == nil then
        return nil
    end

    return result
end

local function build_monster_target_object_probe(obj, include_catalog)
    if obj == nil then
        return nil
    end

    return {
        typeName = get_type_name(obj),
        address = get_object_address(obj),
        typeHierarchy = collect_type_hierarchy(obj),
        candidateFields = collect_monster_target_fields(obj, max_monster_target_values),
        candidateGetters = collect_monster_target_getters(obj, max_monster_target_values),
        fieldCatalog = include_catalog and collect_field_catalog(obj, max_monster_target_values) or nil,
        methodCatalog = include_catalog and collect_method_catalog(obj, max_monster_target_values) or nil
    }
end

local function add_unique_monster_object(objects, seen, obj)
    if obj == nil or not is_probable_runtime_object(obj) then
        return
    end

    local address = get_object_address(obj) or tostring(obj)
    if seen[address] then
        return
    end

    seen[address] = true
    table.insert(objects, obj)
end

local function remember_monster_target_object(obj)
    if obj == nil or not is_probable_runtime_object(obj) then
        return
    end

    local address = get_object_address(obj) or tostring(obj)
    if observed_monster_target_seen[address] then
        return
    end

    observed_monster_target_seen[address] = true
    table.insert(observed_monster_target_objects, obj)

    while #observed_monster_target_objects > max_monster_target_objects do
        local removed = table.remove(observed_monster_target_objects, 1)
        local removed_address = get_object_address(removed) or tostring(removed)
        observed_monster_target_seen[removed_address] = nil
    end
end

local function append_collection_monster_objects(objects, seen, collection, source_name)
    if collection == nil then
        return
    end

    local size = get_runtime_collection_size(collection)
    if size <= 0 then
        return
    end

    for i = 0, size - 1 do
        if #objects >= max_monster_target_objects then
            return
        end

        local item = get_runtime_collection_item(collection, i)
        add_unique_monster_object(objects, seen, item)
    end
end

local function collect_enemy_manager_runtime()
    local manager = sdk.get_managed_singleton("snow.enemy.EnemyManager")
    if manager == nil then
        return nil
    end

    local objects = {}
    local seen = {}
    local collection_getters = {
        "get_EnemyList",
        "get_EnemyCharacterList",
        "get_BossList",
        "get_BossEnemyList",
        "get_EmList",
        "get_EnemyArray",
        "get_EnemyData",
        "get_EnemyCharacters",
        "get_BossEnemy",
        "get_BossEnemyList()",
        "getEmList",
        "getEnemyList",
        "findEnemyList"
    }

    for _, getter_name in ipairs(collection_getters) do
        if #objects >= max_monster_target_objects then
            break
        end

        local collection = safe_call(function()
            return manager:call(getter_name)
        end)

        append_collection_monster_objects(objects, seen, collection, getter_name)
    end

    local method_catalog = collect_method_catalog(manager, max_monster_target_values)
    for _, method_info in ipairs(method_catalog or {}) do
        if #objects >= max_monster_target_objects then
            break
        end

        if method_info.paramCount == 0 and method_info.getterLike and matches_monster_target_keyword(method_info.name) then
            local value = safe_call(function()
                return manager:call(method_info.name)
            end)

            if is_probable_runtime_object(value) then
                append_collection_monster_objects(objects, seen, value, method_info.name)
                add_unique_monster_object(objects, seen, value)
            end
        end
    end

    for _, observed_obj in ipairs(observed_monster_target_objects) do
        if #objects >= max_monster_target_objects then
            break
        end

        add_unique_monster_object(objects, seen, observed_obj)
    end

    local enemies = {}
    for index, obj in ipairs(objects) do
        table.insert(enemies, {
            sourceIndex = index,
            probe = build_monster_target_object_probe(obj, true)
        })
    end

    return {
        manager = build_monster_target_object_probe(manager, true),
        discoveredEnemyCount = #enemies,
        enemies = enemies
    }
end

local function capture_monster_target_sample(reason)
    return {
        sampleId = state.nextMonsterTargetSampleId,
        recordedAt = now_string(),
        uptime = get_uptime(),
        reason = reason or "manual",
        masterPlayerIndex = get_master_player_index(),
        enemyRuntime = collect_enemy_manager_runtime()
    }
end

local function append_monster_target_sample(reason, force)
    if not force and (not state.recording or not state.monsterTargetTraceEnabled) then
        return nil
    end

    local sample = capture_monster_target_sample(reason)
    state.nextMonsterTargetSampleId = state.nextMonsterTargetSampleId + 1
    state.lastMonsterTargetSampleAt = sample.uptime
    table.insert(state.monsterTargetSamples, sample)

    while #state.monsterTargetSamples > max_monster_target_samples do
        table.remove(state.monsterTargetSamples, 1)
    end

    save_records()
    return sample
end

local function build_monster_target_dump()
    return {
        version = 1,
        dumpedAt = now_string(),
        uptime = get_uptime(),
        masterPlayerIndex = get_master_player_index(),
        enemyRuntime = collect_enemy_manager_runtime(),
        relatedTypes = (function()
            local type_catalogs = {}
            for _, type_name in ipairs(monster_target_type_names) do
                table.insert(type_catalogs, build_type_definition_catalog(type_name))
            end
            return type_catalogs
        end)(),
        recordedMonsterTargetSamples = clone_array(state.monsterTargetSamples)
    }
end

local function build_signature(snapshot)
    local action_indices = {}

    for _, action in ipairs(snapshot.actions) do
        table.insert(action_indices, tostring(action.index))
    end

    return table.concat({
        tostring(snapshot.weaponType),
        tostring(snapshot.motionBank),
        tostring(snapshot.motionId),
        tostring(snapshot.nodeId),
        table.concat(action_indices, ",")
    }, "|")
end

local function capture_snapshot()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    if state.onlyWhenWeaponDrawn and not master_player:isWeaponOn() then
        return nil
    end

    local player_game_object = get_player_game_object(master_player)
    local behavior_tree = get_behavior_tree(player_game_object)
    local tree = get_tree_object(player_game_object)
    if not behavior_tree or not tree then
        return nil
    end

    local weapon_type = master_player:get_field("_playerWeaponType")
    local motion_id = master_player:call("getMotionID_Layer(System.Int32)", 0)
    local motion_bank = master_player:call("getMotionBankID_Layer(System.Int32)", 0)
    local motion_frame = math.floor(master_player:call("getMotionNowFrame_Layer(System.Int32)", 0))
    local node_id = behavior_tree:call("getCurrentNodeID", 0)

    local node = tree:get_node_by_id(node_id)
    if not node then
        return nil
    end

    local node_data = node:get_data()
    local node_actions = node_data:get_actions()
    local actions = {}
    local transitions = get_transition_entries(
        tree,
        node_data:get_transition_conditions(),
        node_data:get_states(),
        node_data:get_transition_events(),
        {
            includeDeepConditionFields = true,
            includeDeepEventFields = true,
            includeTargetNodeSummary = true,
            includeTargetTransitionPreview = true,
            includeFocusConditionDetails = true
        }
    )
    local start_transitions = get_transition_entries(
        tree,
        node_data:get_start_transitions(),
        node_data:get_start_states(),
        nil,
        {
            includeDeepConditionFields = true,
            includeTargetNodeSummary = true,
            includeTargetTransitionPreview = true,
            includeFocusConditionDetails = true
        }
    )

    if node_actions then
        for i = 0, node_actions:size() - 1 do
            local action_index = tonumber(node_actions[i])
            table.insert(actions, get_action_info(tree, action_index, true))
        end
    end

    local snapshot = {
        recordedAt = now_string(),
        uptime = get_uptime(),
        weaponType = weapon_type,
        weaponName = weapon_names[weapon_type] or ("未知武器(" .. tostring(weapon_type) .. ")"),
        weaponNameEn = weapon_names_en[weapon_type] or ("WeaponType" .. tostring(weapon_type)),
        motionId = motion_id,
        motionBank = motion_bank,
        motionFrame = motion_frame,
        recentMotionIds = clone_array(state.recentMotionIds),
        nodeId = node_id,
        nodeName = node:get_full_name(),
        actions = actions,
        transitions = transitions,
        startTransitions = start_transitions,
        focusConditions = build_focus_condition_report(node_id, node:get_full_name(), transitions, start_transitions),
        lastHitEvent = state.lastHitEvent,
        nodeSummary = {
            actionCount = #actions,
            transitionCount = #transitions,
            startTransitionCount = #start_transitions
        }
    }

    if should_build_focused_probe(motion_id, snapshot.nodeName, snapshot.focusConditions, snapshot.actions) then
        snapshot.focusedProbe = build_focused_probe(tree, node, motion_id, snapshot.focusConditions)
    end

    snapshot.signature = build_signature(snapshot)
    return snapshot
end

local function capture_context_summary()
    local master_player = get_master_player()
    if not master_player then
        return nil
    end

    local player_game_object = get_player_game_object(master_player)
    local behavior_tree = get_behavior_tree(player_game_object)
    local tree = get_tree_object(player_game_object)
    local node_id = safe_call(function()
        return behavior_tree and behavior_tree:call("getCurrentNodeID", 0)
    end)
    local node_name = nil

    if tree ~= nil and node_id ~= nil then
        node_name = safe_call(function()
            local node = tree:get_node_by_id(node_id)
            return node and node:get_full_name() or nil
        end)
    end

    return {
        uptime = get_uptime(),
        weaponType = safe_get_field(master_player, "_playerWeaponType"),
        weaponName = weapon_names[safe_get_field(master_player, "_playerWeaponType")] or nil,
        motionId = safe_call(function()
            return master_player:call("getMotionID_Layer(System.Int32)", 0)
        end),
        motionBank = safe_call(function()
            return master_player:call("getMotionBankID_Layer(System.Int32)", 0)
        end),
        motionFrame = safe_call(function()
            return math.floor(master_player:call("getMotionNowFrame_Layer(System.Int32)", 0))
        end),
        nodeId = node_id,
        nodeName = node_name
    }
end

function save_records()
    local payload = {
        version = 1,
        updatedAt = now_string(),
        count = #state.records,
        records = state.records,
        harvestMoonEvents = state.harvestMoonEvents,
        monsterTargetSamples = state.monsterTargetSamples
    }

    json.dump_file(state.outputPath, payload)
    state.lastSavedCount = #state.records
end

local function append_snapshot(snapshot)
    table.insert(state.records, snapshot)
    state.lastSignature = snapshot.signature
    save_records()
end

local function append_hit_snapshot(hit_event)
    local snapshot = capture_snapshot()
    if snapshot == nil then
        return
    end

    snapshot.recordTrigger = "hit"
    snapshot.hitEvent = hit_event
    snapshot.signature = snapshot.signature .. "|hit|" .. tostring(hit_event.hitEventId or 0)
    table.insert(state.records, snapshot)
    save_records()
end

local function append_harvest_moon_event(event_kind, obj, extra)
    if not state.recording or not state.harvestMoonTraceEnabled then
        return
    end

    local event = {
        eventId = state.nextHarvestMoonEventId,
        eventKind = event_kind,
        recordedAt = now_string(),
        context = capture_context_summary(),
        object = obj ~= nil and {
            typeName = get_type_name(obj),
            address = get_object_address(obj),
            fields = collect_reflection_fields(obj, max_reflection_field_count),
            scannedProperties = collect_reflection_properties(obj, max_reflection_property_count),
            typeHierarchy = collect_type_hierarchy(obj)
        } or nil,
        extra = extra
    }

    state.nextHarvestMoonEventId = state.nextHarvestMoonEventId + 1
    table.insert(state.harvestMoonEvents, event)

    while #state.harvestMoonEvents > 80 do
        table.remove(state.harvestMoonEvents, 1)
    end

    save_records()
end

local function clear_records()
    state.records = {}
    state.harvestMoonEvents = {}
    state.monsterTargetSamples = {}
    state.lastSignature = nil
    state.lastSavedCount = 0
    state.nextHarvestMoonEventId = 1
    state.nextMonsterTargetSampleId = 1
    state.lastMonsterTargetSampleAt = nil
    save_records()
end

local function load_existing_records()
    local payload = safe_call(function()
        return json.load_file(state.outputPath)
    end)
    if type(payload) ~= "table" or type(payload.records) ~= "table" then
        return
    end

    state.records = payload.records
    state.harvestMoonEvents = type(payload.harvestMoonEvents) == "table" and payload.harvestMoonEvents or {}
    state.monsterTargetSamples = type(payload.monsterTargetSamples) == "table" and payload.monsterTargetSamples or {}
    state.lastSavedCount = #state.records
    state.nextHarvestMoonEventId = #state.harvestMoonEvents + 1
    state.nextMonsterTargetSampleId = #state.monsterTargetSamples + 1

    if #state.records > 0 then
        local last_record = state.records[#state.records]
        state.lastSignature = last_record.signature
    end
end

load_existing_records()

local function begin_recording()
    state.outputPath = make_random_output_path(default_output_prefix)
    state.records = {}
    state.harvestMoonEvents = {}
    state.monsterTargetSamples = {}
    state.lastSignature = nil
    state.lastSavedCount = 0
    state.nextHarvestMoonEventId = 1
    state.nextMonsterTargetSampleId = 1
    state.lastMonsterTargetSampleAt = nil
    state.recording = true
    save_records()
end

local function stop_recording()
    state.recording = false
    save_records()
end

local function dump_current_tree()
    local payload = build_tree_dump()
    if payload == nil then
        return nil
    end

    local weapon_name = payload.weaponNameEn or ("WeaponType" .. tostring(payload.weaponType))
    local output_path = "ActionTreeDump_" .. weapon_name .. ".json"
    json.dump_file(output_path, payload)
    state.lastDumpPath = output_path
    return output_path
end

local function dump_harvest_moon()
    local payload = build_harvest_moon_dump()
    if payload == nil then
        return nil
    end

    local output_path = "HarvestMoonDump_" .. now_file_string() .. ".json"
    json.dump_file(output_path, payload)
    state.lastHarvestMoonDumpPath = output_path
    return output_path
end

local function dump_monster_target()
    local payload = build_monster_target_dump()
    if payload == nil then
        return nil
    end

    local output_path = "MonsterTargetTrace_" .. now_file_string() .. ".json"
    json.dump_file(output_path, payload)
    state.lastMonsterTargetDumpPath = output_path
    return output_path
end

re.on_frame(function()
    local snapshot = capture_snapshot()
    state.currentInfo = snapshot

    if state.recording and state.monsterTargetTraceEnabled then
        local uptime = get_uptime()
        if state.lastMonsterTargetSampleAt == nil or uptime - state.lastMonsterTargetSampleAt >= monster_target_sample_interval then
            append_monster_target_sample("interval")
        end
    end

    if not state.recording or not state.weaponActionTraceEnabled or snapshot == nil then
        return
    end

    if snapshot.signature ~= state.lastSignature then
        append_snapshot(snapshot)
    end
end)

sdk.hook(
    sdk.find_type_definition("snow.PlayerPlayMotion2"):get_method("playerWeaponMotion"),
    function(args)
        local manager = sdk.to_managed_object(args[2])
        local arg = sdk.to_managed_object(args[3])
        if not manager or not arg then
            return
        end

        local owner_hash = safe_call(function()
            return arg:call("get_OwnerGameObject"):call("GetHashCode")
        end)

        if owner_hash == nil or owner_hash ~= get_master_player_object_hash() then
            return
        end

        push_recent_motion_id(safe_call(function()
            return manager:call("get_MotionID")
        end))
    end
)

sdk.hook(
    sdk.find_type_definition("snow.enemy.EnemyCharacterBase"):get_method("afterCalcDamage_DamageSide"),
    function(args)
        remember_monster_target_object(sdk.to_managed_object(args[2]))

        local damage_info = sdk.to_managed_object(args[3])
        local hit_info = sdk.to_managed_object(args[4])
        if not damage_info or not hit_info then
            return
        end

        local master_player = get_master_player()
        if not master_player then
            return
        end

        local master_player_index = get_master_player_index()
        if master_player_index == nil or damage_info:call("get_AttackerID") ~= master_player_index then
            return
        end

        local weapon_type = master_player:get_field("_playerWeaponType")
        local attack_data = safe_call(function()
            return hit_info:call("get_AttackData")
        end)
        local damage_data = safe_call(function()
            return hit_info:get_DamageData()
        end)

        local hit_event = {
            hitEventId = state.nextHitEventId,
            recordedAt = now_string(),
            uptime = get_uptime(),
            weaponType = weapon_type,
            weaponName = weapon_names[weapon_type] or ("未知武器(" .. tostring(weapon_type) .. ")"),
            weaponNameEn = weapon_names_en[weapon_type] or ("WeaponType" .. tostring(weapon_type)),
            motionId = safe_call(function()
                return master_player:call("getMotionID_Layer(System.Int32)", 0)
            end),
            motionBank = safe_call(function()
                return master_player:call("getMotionBankID_Layer(System.Int32)", 0)
            end),
            motionFrame = safe_call(function()
                return math.floor(master_player:call("getMotionNowFrame_Layer(System.Int32)", 0))
            end),
            recentMotionIds = clone_array(state.recentMotionIds),
            attackDataName = safe_call(function()
                return attack_data:call("ToString")
            end),
            damageDataName = safe_call(function()
                return damage_data:get_Name()
            end),
            damageType = safe_call(function()
                return damage_info:call("get_DamageType")
            end),
            damageAttackerType = safe_call(function()
                return damage_info:call("get_DamageAttackerType")
            end),
            totalDamage = safe_call(function()
                return damage_info:call("get_TotalDamage")
            end),
            physicalDamage = safe_call(function()
                return damage_info:call("get_PhysicalDamage")
            end),
            elementDamage = safe_call(function()
                return damage_info:call("get_ElementDamage")
            end),
            criticalResult = safe_call(function()
                return damage_info:call("get_CriticalResult")
            end)
        }

        state.nextHitEventId = state.nextHitEventId + 1
        remember_hit_event(hit_event)

        if state.recording and state.weaponActionTraceEnabled then
            append_hit_snapshot(hit_event)
        end
    end
)

local function install_harvest_moon_event_hooks()
    local longsword_type = sdk.find_type_definition("snow.player.LongSword")
    local create_spacing_shell_method = longsword_type and longsword_type:get_method("createSpacingShell") or nil
    if create_spacing_shell_method ~= nil then
        safe_call(function()
            sdk.hook(
                create_spacing_shell_method,
                function(args)
                    local this = sdk.to_managed_object(args[2])
                    append_harvest_moon_event("LongSword.createSpacingShell.pre", this)
                end,
                function(retval)
                    append_harvest_moon_event("LongSword.createSpacingShell.post", nil)
                    return retval
                end
            )
            return true
        end)
    end

    local shell_type = sdk.find_type_definition("snow.shell.LongSwordShell010")
    local shell_method_names = {
        "start",
        "activate",
        "setup",
        "initialize",
        "onStart",
        "destroy",
        "onDestroy",
        "onDisable",
        "deactivate",
        "end",
        "onEnd",
        "onDeactivate",
        "destroySelf",
        "requestDestroy",
        "forceDestroy"
    }

    if shell_type ~= nil then
        for _, method_name in ipairs(shell_method_names) do
            local method = shell_type:get_method(method_name)
            if method ~= nil then
                safe_call(function()
                    sdk.hook(
                        method,
                        function(args)
                            local this = sdk.to_managed_object(args[2])
                            append_harvest_moon_event("LongSwordShell010." .. method_name, this)
                        end,
                        function(retval)
                            return retval
                        end
                    )
                    return true
                end)
            end
        end
    end

    local packet_type = sdk.find_type_definition("snow.PlayerNetwork.LongSwordDestroySpacingShellPacket")
    local packet_method_names = {
        "setup",
        "initialize",
        "init",
        "set",
        "clear",
        "read",
        "write",
        "serialize",
        "deserialize",
        "onSerialize",
        "onDeserialize",
        "pack",
        "unpack",
        "send",
        "receive",
        "execute",
        "apply",
        "copy",
        "clone"
    }

    if packet_type ~= nil then
        for _, method_name in ipairs(packet_method_names) do
            local method = packet_type:get_method(method_name)
            if method ~= nil then
                safe_call(function()
                    sdk.hook(
                        method,
                        function(args)
                            local this = sdk.to_managed_object(args[2])
                            append_harvest_moon_event(
                                "LongSwordDestroySpacingShellPacket." .. method_name,
                                this,
                                {
                                    shellUniqueId = safe_get_field(this, "_ShellUniqueId"),
                                    isOutSide = safe_get_field(this, "_IsOutSide")
                                }
                            )
                        end,
                        function(retval)
                            return retval
                        end
                    )
                    return true
                end)
            end
        end
    end
end

install_harvest_moon_event_hooks()

local function draw_current_info()
    local info = state.currentInfo
    if not info then
        imgui.text("当前没有可读取的动作信息。")
        return
    end

    imgui.text("当前武器: " .. info.weaponName)
    imgui.text("Motion Bank / ID / Frame: " .. tostring(info.motionBank) .. " / " .. tostring(info.motionId) .. " / " .. tostring(info.motionFrame))
    imgui.text("Node: " .. tostring(info.nodeId))
    imgui.text("Node Name: " .. tostring(info.nodeName))
    imgui.text("重点 Conditions: " .. tostring(#info.focusConditions or 0))
    imgui.text("重型深挖: " .. (info.focusedProbe ~= nil and "已命中" or "未命中"))
    imgui.text("最近 Motion 历史: " .. table.concat(info.recentMotionIds or {}, ", "))

    if info.lastHitEvent ~= nil then
        imgui.text("最近命中招式: " .. tostring(info.lastHitEvent.attackDataName or "UNKNOWN"))
    else
        imgui.text("最近命中招式: 暂无")
    end

    if imgui.tree_node("当前节点 Actions [" .. tostring(#info.actions) .. "]") then
        for _, action in ipairs(info.actions) do
            local line = tostring(action.index) .. " | " .. tostring(action.typeName)
            if action.startFrame ~= nil or action.endFrame ~= nil then
                line = line .. " | Start=" .. tostring(action.startFrame) .. " End=" .. tostring(action.endFrame)
            end

            imgui.text(line)
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("当前节点 Transitions [" .. tostring(#info.transitions or 0) .. "]") then
        for _, transition in ipairs(info.transitions or {}) do
            local condition_name = "UNKNOWN_CONDITION"
            local condition_index = "?"

            if transition.condition then
                condition_name = tostring(transition.condition.typeName)
                condition_index = tostring(transition.condition.index)
            end

            imgui.text(
                "slot=" .. tostring(transition.slot) ..
                " | cond=" .. condition_index ..
                " | state=" .. tostring(transition.targetState) ..
                " | " .. condition_name
            )
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("重点 Condition 线索 [" .. tostring(#info.focusConditions or 0) .. "]") then
        for _, item in ipairs(info.focusConditions or {}) do
            imgui.text(
                tostring(item.sourceKind) ..
                " | slot=" .. tostring(item.sourceSlot) ..
                " | cond=" .. tostring(item.condition and item.condition.index or "?") ..
                " | " .. tostring(item.condition and item.condition.typeName or "UNKNOWN") ..
                " | state=" .. tostring(item.targetState)
            )
        end
        imgui.tree_pop()
    end
end

local function draw_last_record()
    if #state.records == 0 then
        imgui.text("还没有记录。")
        return
    end

    local last_record = state.records[#state.records]
    imgui.text("最后一条记录: " .. tostring(last_record.recordedAt))
    imgui.text("武器: " .. tostring(last_record.weaponName))
    imgui.text("Motion Bank / ID: " .. tostring(last_record.motionBank) .. " / " .. tostring(last_record.motionId))
    imgui.text("Node: " .. tostring(last_record.nodeId))
    if last_record.hitEvent ~= nil then
        imgui.text("命中招式: " .. tostring(last_record.hitEvent.attackDataName or "UNKNOWN"))
    end
    imgui.text("已写入文件: " .. state.outputPath)
end

re.on_draw_ui(function()
    local toggle = false

    if imgui.tree_node("Action Trace Recorder") then
        local language = get_display_language()
        local has_custom_font = language ~= nil and language_font[language] ~= nil

        if has_custom_font then
            imgui.push_font(language_font[language])
        end

        if state.recording then
            if imgui.button("停止录制") then
                stop_recording()
            end
        else
            if imgui.button("开始录制") then
                begin_recording()
            end
        end

        imgui.same_line()
        if imgui.button("强制记录当前动作") then
            if state.weaponActionTraceEnabled then
                local snapshot = capture_snapshot()
                if snapshot ~= nil then
                    append_snapshot(snapshot)
                end
            end
        end

        imgui.same_line()
        if imgui.button("导出当前武器整棵动作树") then
            dump_current_tree()
        end

        imgui.same_line()
        if imgui.button("导出圆月专项 Dump") then
            dump_harvest_moon()
        end

        imgui.same_line()
        if imgui.button("导出怪物目标专项 Dump") then
            dump_monster_target()
        end

        toggle, state.weaponActionTraceEnabled = imgui.checkbox("记录武器动作", state.weaponActionTraceEnabled)
        if toggle then
            state.lastSignature = nil
        end

        toggle, state.onlyWhenWeaponDrawn = imgui.checkbox("只在拔刀时记录", state.onlyWhenWeaponDrawn)
        toggle, state.harvestMoonTraceEnabled = imgui.checkbox("记录圆月生命周期", state.harvestMoonTraceEnabled)
        toggle, state.monsterTargetTraceEnabled = imgui.checkbox("记录怪物目标采样", state.monsterTargetTraceEnabled)

        if not state.weaponActionTraceEnabled then
            imgui.text("武器动作记录已关闭，records 不会追加动作或命中快照。")
        end

        if imgui.button("强制记录怪物目标") then
            append_monster_target_sample("manual", true)
        end

        imgui.text("录制状态: " .. (state.recording and "录制中" or "未录制"))
        imgui.text("记录数量: " .. tostring(#state.records))
        imgui.text("圆月事件数量: " .. tostring(#state.harvestMoonEvents))
        imgui.text("怪物目标采样数量: " .. tostring(#state.monsterTargetSamples))
        imgui.text("录制文件: " .. state.outputPath)
        if state.lastDumpPath ~= nil then
            imgui.text("最近导出的整树文件: " .. state.lastDumpPath)
        end
        if state.lastHarvestMoonDumpPath ~= nil then
            imgui.text("最近导出的圆月文件: " .. state.lastHarvestMoonDumpPath)
        end
        if state.lastMonsterTargetDumpPath ~= nil then
            imgui.text("最近导出的怪物目标文件: " .. state.lastMonsterTargetDumpPath)
        end

        if imgui.tree_node("当前动作信息") then
            draw_current_info()
            imgui.tree_pop()
        end

        if imgui.tree_node("最后一条记录") then
            draw_last_record()
            imgui.tree_pop()
        end

        if imgui.button("手动保存") then
            save_records()
        end

        imgui.same_line()
        if imgui.button("清空记录") then
            clear_records()
        end

        if has_custom_font then
            imgui.pop_font()
        end

        imgui.tree_pop()
    end
end)
