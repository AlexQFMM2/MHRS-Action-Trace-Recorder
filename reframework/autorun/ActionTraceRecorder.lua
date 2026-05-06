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
    onlyWhenWeaponDrawn = true,
    records = {},
    lastSignature = nil,
    lastSavedCount = 0,
    currentInfo = nil,
    outputPath = default_output_prefix .. ".json",
    lastDumpPath = nil
}

local max_reflection_field_count = 80

-- 这些字段名是“优先尝试读取”的候选项。
-- 它们并不保证所有类型都存在，但能帮助我们把常见的帧、无敌、判定相关字段尽量抓出来。
local action_field_candidates = {
    "_StartFrame",
    "_EndFrame",
    "_MutekiStartFrame",
    "_MutekiEndFrame",
    "_InvincibleStartFrame",
    "_InvincibleEndFrame",
    "_JustStartFrame",
    "_JustEndFrame",
    "_HyperArmorTimer",
    "_AngleRange"
}

local condition_field_candidates = {
    "StartFrame",
    "EndFrame",
    "CkFrame",
    "CheckFrame",
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
                    local field_type_name = field_type and field_type:get_full_name() or "UNKNOWN_FIELD_TYPE"
                    local should_read = field_type == nil
                        or field_type:is_value_type()
                        or field_type_name == "System.String"

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
        scannedFields = include_deep_fields and collect_reflection_fields(action_obj, max_reflection_field_count) or nil
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
        scannedFields = include_deep_fields and collect_reflection_fields(condition_obj, max_reflection_field_count) or nil
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
        scannedFields = include_deep_fields and collect_reflection_fields(event_obj, max_reflection_field_count) or nil
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

local function get_node_target_summary(tree, state_index, include_transition_preview)
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

    if include_transition_preview and node_data then
        local preview = {}
        local transition_conditions = node_data:get_transition_conditions()
        local transition_states = node_data:get_states()
        local size = math.min(get_collection_size(transition_conditions), get_collection_size(transition_states))

        for i = 0, size - 1 do
            local condition_index = tonumber(transition_conditions[i])
            local target_state = tonumber(transition_states[i])
            local condition_info = get_condition_info(tree, condition_index, true)

            table.insert(preview, {
                slot = i,
                conditionIndex = condition_index,
                conditionType = condition_info and condition_info.typeName or "UNKNOWN_CONDITION",
                conditionFields = condition_info and condition_info.fields or nil,
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
            targetNode = options.includeTargetNodeSummary and get_node_target_summary(tree, target_state, options.includeTargetTransitionPreview) or nil
        })
    end

    return entries
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

local function get_node_entry(tree, node)
    local node_data = node:get_data()
    local action_indices = {}
    local node_actions = node_data:get_actions()
    local action_size = get_collection_size(node_actions)

    for i = 0, action_size - 1 do
        table.insert(action_indices, tonumber(node_actions[i]))
    end

    return {
        id = node:get_id(),
        name = node:get_full_name(),
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
        table.insert(result, get_node_entry(tree, nodes[i]))
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
            includeTargetTransitionPreview = true
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
            includeTargetTransitionPreview = true
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
        nodeId = node_id,
        nodeName = node:get_full_name(),
        actions = actions,
        transitions = transitions,
        startTransitions = start_transitions,
        nodeSummary = {
            actionCount = #actions,
            transitionCount = #transitions,
            startTransitionCount = #start_transitions
        }
    }

    snapshot.signature = build_signature(snapshot)
    return snapshot
end

local function save_records()
    local payload = {
        version = 1,
        updatedAt = now_string(),
        count = #state.records,
        records = state.records
    }

    json.dump_file(state.outputPath, payload)
    state.lastSavedCount = #state.records
end

local function append_snapshot(snapshot)
    table.insert(state.records, snapshot)
    state.lastSignature = snapshot.signature
    save_records()
end

local function clear_records()
    state.records = {}
    state.lastSignature = nil
    state.lastSavedCount = 0
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
    state.lastSavedCount = #state.records

    if #state.records > 0 then
        local last_record = state.records[#state.records]
        state.lastSignature = last_record.signature
    end
end

load_existing_records()

local function begin_recording()
    state.outputPath = make_random_output_path(default_output_prefix)
    state.records = {}
    state.lastSignature = nil
    state.lastSavedCount = 0
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

re.on_frame(function()
    local snapshot = capture_snapshot()
    state.currentInfo = snapshot

    if not state.recording or snapshot == nil then
        return
    end

    if snapshot.signature ~= state.lastSignature then
        append_snapshot(snapshot)
    end
end)

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
            local snapshot = capture_snapshot()
            if snapshot ~= nil then
                append_snapshot(snapshot)
            end
        end

        imgui.same_line()
        if imgui.button("导出当前武器整棵动作树") then
            dump_current_tree()
        end

        toggle, state.onlyWhenWeaponDrawn = imgui.checkbox("只在拔刀时记录", state.onlyWhenWeaponDrawn)

        imgui.text("录制状态: " .. (state.recording and "录制中" or "未录制"))
        imgui.text("记录数量: " .. tostring(#state.records))
        imgui.text("录制文件: " .. state.outputPath)
        if state.lastDumpPath ~= nil then
            imgui.text("最近导出的整树文件: " .. state.lastDumpPath)
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
