-- 这是一个独立的 REFramework 记录工具。
-- 目标是帮助我们在游戏里“实际打出某个动作”时，自动把和这个动作有关的关键信息记录下来：
-- 1. 当前武器类型
-- 2. 当前 motion id / motion bank
-- 3. 当前行为树 node id
-- 4. 当前 node 绑定的 action 列表
-- 5. 每个 action 的类型名，以及它的 _StartFrame / _EndFrame
--
-- 这样后续定位“某个 GP 动作到底对应哪个 ActionIndex”时，就不需要纯手工抄了。

local output_path = "ActionTraceRecorder.json"

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

local state = {
    recording = false,
    onlyWhenWeaponDrawn = true,
    records = {},
    lastSignature = nil,
    lastSavedCount = 0,
    currentInfo = nil
}

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

local function now_string()
    return os.date("%Y-%m-%d %H:%M:%S")
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

local function get_action_info(tree, action_index)
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
        fields = collect_existing_fields(action_obj, action_field_candidates)
    }
end

local function get_condition_info(tree, condition_index)
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
        fields = collect_existing_fields(condition_obj, condition_field_candidates)
    }
end

local function get_transition_event_info(tree, event_index)
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
        fields = collect_existing_fields(event_obj, event_field_candidates)
    }
end

local function get_event_list(tree, event_index_collection)
    local result = {}
    local size = get_collection_size(event_index_collection)

    for i = 0, size - 1 do
        local event_index = tonumber(event_index_collection[i])
        table.insert(result, get_transition_event_info(tree, event_index))
    end

    return result
end

local function get_transition_entries(tree, condition_collection, state_collection, event_collection)
    local entries = {}
    local size = math.min(get_collection_size(condition_collection), get_collection_size(state_collection))

    for i = 0, size - 1 do
        local condition_index = tonumber(condition_collection[i])
        local target_state = tonumber(state_collection[i])
        local events = nil

        if event_collection ~= nil then
            events = get_event_list(tree, event_collection[i])
        end

        table.insert(entries, {
            slot = i,
            condition = get_condition_info(tree, condition_index),
            targetState = target_state,
            events = events
        })
    end

    return entries
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
        node_data:get_transition_events()
    )
    local start_transitions = get_transition_entries(
        tree,
        node_data:get_start_transitions(),
        node_data:get_start_states(),
        nil
    )

    if node_actions then
        for i = 0, node_actions:size() - 1 do
            local action_index = tonumber(node_actions[i])
            table.insert(actions, get_action_info(tree, action_index))
        end
    end

    local snapshot = {
        recordedAt = now_string(),
        uptime = get_uptime(),
        weaponType = weapon_type,
        weaponName = weapon_names[weapon_type] or ("未知武器(" .. tostring(weapon_type) .. ")"),
        motionId = motion_id,
        motionBank = motion_bank,
        motionFrame = motion_frame,
        nodeId = node_id,
        nodeName = node:get_full_name(),
        actions = actions,
        transitions = transitions,
        startTransitions = start_transitions
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

    json.dump_file(output_path, payload)
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
    local payload = json.load_file(output_path)
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
    imgui.text("已写入文件: " .. output_path)
end

re.on_draw_ui(function()
    local toggle = false

    if imgui.tree_node("Action Trace Recorder") then
        if state.recording then
            if imgui.button("停止录制") then
                state.recording = false
            end
        else
            if imgui.button("开始录制") then
                state.recording = true
            end
        end

        imgui.same_line()
        if imgui.button("强制记录当前动作") then
            local snapshot = capture_snapshot()
            if snapshot ~= nil then
                append_snapshot(snapshot)
            end
        end

        toggle, state.onlyWhenWeaponDrawn = imgui.checkbox("只在拔刀时记录", state.onlyWhenWeaponDrawn)

        imgui.text("录制状态: " .. (state.recording and "录制中" or "未录制"))
        imgui.text("记录数量: " .. tostring(#state.records))
        imgui.text("输出文件: " .. output_path)

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

        imgui.tree_pop()
    end
end)
