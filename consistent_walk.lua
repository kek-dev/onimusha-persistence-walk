-- Consistent Walk 1.0.2
-- Onimusha: Way of the Sword / REFramework
-- Remember the walk toggle when the game resets its walk state

local NAME = "Consistent Walk"
local WALK_TYPE = "app.cPlayerActionSelector.cWalkKeepManager"
local WALK_FIELD = "<IsWalkKeep>k__BackingField"
local state = { latched = false, toggle_down = false, ready = false, error = nil }
local methods, commands = {}, {}

local function fail(message)
    state.ready = false
    if state.error == nil then
        state.error = tostring(message)
        log.error("[" .. NAME .. "] " .. state.error)
    end
end

local function type_definition(name)
    local result = sdk.find_type_definition(name)
    assert(result ~= nil, "Can't find type: " .. name)
    return result
end

local function resolve(type_name, name, result_type, parameter_types)
    local found = nil
    for _, method in ipairs(type_definition(type_name):get_methods()) do
        if method:get_name() == name and method:get_return_type():get_full_name() == result_type then
            local parameters = method:get_param_types()
            local matches = #parameters == #parameter_types
            for index, parameter in ipairs(parameters) do
                if parameter:get_full_name() ~= parameter_types[index] then matches = false end
            end
            if matches then
                assert(found == nil, "More than one matching method: " .. type_name .. "." .. name)
                found = method
            end
        end
    end
    assert(found ~= nil, "Can't find method: " .. type_name .. "." .. name)
    return found
end

local function controlling_controller()
    local manager = sdk.get_managed_singleton("app.PlayerManager")
    if manager == nil then return nil end
    local info = methods.player_info:call(manager)
    return info ~= nil and methods.controller:call(info) or nil
end

local function same_object(a, b)
    return a ~= nil and b ~= nil and a:get_address() == b:get_address()
end

local function owned_manager(manager, controller)
    if manager == nil or controller == nil then return false end
    local selector = controller:get_field("_ActionSelector")
    return selector ~= nil and same_object(selector:get_field("_WalkKeepManager"), manager)
end

local function set_walk(manager, value)
    -- Keep both flags in sync
    if manager:get_field("_CommandWalk") ~= value then manager:set_field("_CommandWalk", value) end
    -- Only write when changes
    if manager:get_field(WALK_FIELD) ~= value then manager:set_field(WALK_FIELD, value) end
end

local function sample(manager, controller)
    if not same_object(controller, controlling_controller()) or not owned_manager(manager, controller) then
        return nil
    end
    local flow = sdk.get_managed_singleton("app.GameFlowManager")
    if flow == nil or methods.stable:call(flow) ~= true then return nil end
    local result = methods.result:call(controller)
    if result == nil then return nil end

    -- WALK is the toggle; WALK_KEEP is for holding the walk key.
    local toggle = methods.command:call(result, commands.WALK) == true
    local sprint = methods.command:call(result, commands.DASH) == true
        or methods.command:call(result, commands.DASH_KEEP) == true
    -- Sprint input prio
    if sprint then
        state.latched = false
    elseif toggle and not state.toggle_down then
        state.latched = not state.latched
    end
    state.toggle_down = toggle
    return { manager = manager, controller = controller, explicit = toggle or sprint,
        moving = methods.moving:call(result) == true }
end

local function after_update(context)
    if context == nil or not same_object(context.controller, controlling_controller()) then return end
    if not owned_manager(context.manager, context.controller) then return end
    if state.latched then
        -- Remember the toggle while idle
        set_walk(context.manager, context.moving)
    elseif context.explicit then
        -- Preserve toggle
        set_walk(context.manager, false)
    end
end

local function initialize()
    local walk = type_definition(WALK_TYPE)
    local field = walk:get_field(WALK_FIELD)
    assert(field ~= nil and field:get_type():get_full_name() == "System.Boolean", "Can't find walk state")
    local toggle_field = walk:get_field("_CommandWalk")
    assert(toggle_field ~= nil and toggle_field:get_type():get_full_name() == "System.Boolean", "Can't find walk toggle")
    local enum = type_definition("app.PlayerCommand.TYPE")
    for _, name in ipairs({ "WALK", "DASH", "DASH_KEEP" }) do
        local entry = enum:get_field(name)
        assert(entry ~= nil, "Can't find command: " .. name)
        commands[name] = entry:get_data(nil)
        assert(type(commands[name]) == "number", "Bad command value: " .. name)
    end
    assert(commands.WALK ~= commands.DASH and commands.WALK ~= commands.DASH_KEEP, "Walk and sprint share a command value")
    methods.update = resolve(WALK_TYPE, "update", "System.Void", {
        "app.cPlayerCharacterEntity", "app.cPlayerDefaultInputControllerEntity" })
    methods.reset = resolve(WALK_TYPE, "reset", "System.Void", {})
    methods.player_info = resolve("app.PlayerManager", "getControllingPlayerInfo", "app.cPlayerManageInfo", {})
    methods.controller = resolve("app.cPlayerManageInfo", "get_ControllerEntity", "app.cPlayerInputControllerEntity", {})
    methods.stable = resolve("app.GameFlowManager", "get_IsIngameStable", "System.Boolean", {})
    methods.result = resolve("app.cPlayerInputControllerEntity", "get_CommandResult", "app.cPlayerCommandResult", {})
    methods.command = resolve("app.cPlayerCommandResult", "checkNormalCommand", "System.Boolean", { "System.Int32" })
    methods.moving = resolve("app.cPlayerCommandResult", "get_IsEnableInputWorldDirL", "System.Boolean", {})

    sdk.hook(methods.update, function(args)
        local storage = thread.get_hook_storage()
        storage.consistent_walk_update = nil
        if state.ready then
            local ok, context = pcall(function()
                -- Hook args: thread, manager, character, controller.
                if sdk.to_managed_object(args[3]) == nil then return nil end
                return sample(sdk.to_managed_object(args[2]), sdk.to_managed_object(args[4]))
            end)
            if ok then storage.consistent_walk_update = context else fail(context) end
        end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local storage = thread.get_hook_storage()
        local context = storage.consistent_walk_update
        storage.consistent_walk_update = nil
        if state.ready then
            local ok, err = pcall(after_update, context)
            if not ok then fail(err) end
        end
        return retval
    end)

    sdk.hook(methods.reset, function(args)
        local storage = thread.get_hook_storage()
        storage.consistent_walk_reset = nil
        if state.ready and state.latched then
            local ok, manager = pcall(function()
                local value = sdk.to_managed_object(args[2])
                if owned_manager(value, controlling_controller()) then return value end
            end)
            if ok then storage.consistent_walk_reset = manager else fail(manager) end
        end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local storage = thread.get_hook_storage()
        local manager = storage.consistent_walk_reset
        storage.consistent_walk_reset = nil
        if state.ready and state.latched and manager ~= nil then
            local ok, err = pcall(function()
                local controller = controlling_controller()
                if owned_manager(manager, controller) then
                    local flow = sdk.get_managed_singleton("app.GameFlowManager")
                    local result = methods.result:call(controller)
                    local moving = flow ~= nil and methods.stable:call(flow) == true
                        and result ~= nil and methods.moving:call(result) == true
                    set_walk(manager, moving)
                end
            end)
            if not ok then fail(err) end
        end
        return retval
    end)
    state.ready = true
    log.info("[" .. NAME .. "] Loaded 1.0.2")
end

-- Optional speed boost
local SPEED_FILE = "consistent_walk.json"
local speed_cfg = { enabled = false, multiplier = 1.0 }
do
    local loaded, saved = pcall(json.load_file, SPEED_FILE)
    if loaded and type(saved) == "table" then
        if type(saved.enabled) == "boolean" then speed_cfg.enabled = saved.enabled end
        if type(saved.multiplier) == "number" and saved.multiplier == saved.multiplier then
            speed_cfg.multiplier = math.max(1.0, math.min(3.0, saved.multiplier)) + 0.0
        end
    end
end
local function save_speed() pcall(json.dump_file, SPEED_FILE, speed_cfg) end
local walk_clips = nil
local speed_error = nil
local speed_layer, speed_entity = nil, nil
local old_speed, written_speed, old_rate, written_rate = nil, nil, nil, nil
local function near(a, b) return math.abs(a - b) < 0.001 end
local function restore_walk_speed()
    if speed_layer ~= nil then
        pcall(function()
            if near(speed_layer:call("get_Speed"), written_speed) then
                speed_layer:call("set_Speed", old_speed)
            end
        end)
    end
    if speed_entity ~= nil then
        pcall(function()
            local rate = speed_entity:call("get_ActionRootTransRate")
            if rate ~= nil and near(rate.x, written_rate.x) and near(rate.y, written_rate.y)
                and near(rate.z, written_rate.z) then
                speed_entity:call("set_ActionRootTransRate", old_rate)
            end
        end)
    end
    speed_layer, speed_entity = nil, nil
end

local function load_walk_clips()
    local clips = {}
    for _, name in ipairs({ "app.plc_BaseMove_Mot.SetID", "app.plw_KatateMove_Mot.SetID",
        "app.plw_RyoteMove_Mot.SetID", "app.plw_tree_Mot.SetID", "app.plw_SubWeapon_Mot.SetID" }) do
        local definition = sdk.find_type_definition(name)
        if definition ~= nil then
            for _, field in ipairs(definition:get_fields()) do
                local clip = field:get_name()
                local walking = clip:find("Walk", 1, true) and clip:find("Loop", 1, true)
                for _, excluded in ipairs({ "Run", "Dash", "Sprint", "Jog", "Jump", "Falling", "NPC_",
                    "Over_The_Fence", "Ladder", "Ledge", "Guard", "Issen", "Bow", "QuickShot", "Tired", "_to_" }) do
                    if clip:find(excluded, 1, true) then walking = false end
                end
                if walking then
                    local value = field:get_data(nil)
                    if type(value) == "number" then
                        local bank = math.floor(value / 4096)
                        clips[bank] = clips[bank] or {}
                        clips[bank][value % 4096] = true
                    end
                end
            end
        end
    end
    assert(next(clips) ~= nil, "Can't find walk animations")
    return clips
end

local function update_walk_speed()
    -- Undo the last speed change before reading the current animation.
    restore_walk_speed()
    if not state.ready or not speed_cfg.enabled or speed_cfg.multiplier == 1.0 or speed_error then return end
    local flow = sdk.get_managed_singleton("app.GameFlowManager")
    if flow == nil or methods.stable:call(flow) ~= true then return end
    if walk_clips == nil then walk_clips = load_walk_clips() end
    local manager = sdk.get_managed_singleton("app.PlayerManager")
    local player = manager and manager:call("getControllingPlayer") or nil
    local object = player and player:call("get_Object") or nil
    if object == nil then return end
    local motion = object:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local layer = motion and motion:call("getLayer", 0) or nil
    if layer == nil then return end
    local bank = walk_clips[layer:call("get_MotionBankID")]
    if bank == nil or not bank[layer:call("get_MotionID")] then return end
    local entity = player:call("get_CharacterEntity")
    if entity == nil then return end
    local rate = entity:call("get_ActionRootTransRate")
    local baseline = layer:call("get_Speed")
    if rate == nil or baseline == nil then return end
    local multiplier = speed_cfg.multiplier
    old_speed, written_speed = baseline + 0.0, baseline * multiplier
    old_rate = Vector3f.new(rate.x, rate.y, rate.z)
    written_rate = Vector3f.new(rate.x * multiplier, rate.y * multiplier, rate.z * multiplier)
    speed_layer, speed_entity = layer, entity
    layer:call("set_Speed", written_speed)
    entity:call("set_ActionRootTransRate", written_rate)
end

re.on_pre_application_entry("UpdateMotion", function()
    local success, message = pcall(update_walk_speed)
    if not success then
        restore_walk_speed()
        speed_error = tostring(message)
        log.error("[" .. NAME .. "] Walking speed: " .. speed_error)
    end
end)

local ok, err = pcall(initialize)
if not ok then fail(err) end

re.on_draw_ui(function()
    if imgui.tree_node(NAME) then
        imgui.text(state.ready and (state.latched and "Walk toggle on" or "Normal movement") or ("Disabled: " .. tostring(state.error)))
        local changed
        changed, speed_cfg.enabled = imgui.checkbox("Adjust walking speed", speed_cfg.enabled)
        if changed then
            restore_walk_speed()
            speed_error = nil
            save_speed()
        end
        changed, speed_cfg.multiplier = imgui.slider_float("Walking speed", speed_cfg.multiplier, 1.0, 3.0, "%.2fx")
        if changed then
            speed_cfg.multiplier = math.max(1.0, math.min(3.0, speed_cfg.multiplier)) + 0.0
            restore_walk_speed()
            save_speed()
        end
        if speed_error then imgui.text("Can't change walk speed: " .. speed_error) end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    restore_walk_speed()
    state.ready, state.latched, state.toggle_down = false, false, false
end)
