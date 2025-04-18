-- CodeSync 客户端 - 精简版
-- 主要负责配置管理和代码注入
local VERSION = "1.0.1"
local CONFIG_FILE = "codeSync_client_config.cfg"
local CODE_INJECTOR_MARKER = "--[[ CODESYNC INJECTED CODE ]]"
local CODE_INJECTOR_END_MARKER = "--[[ CODESYNC HOOK END ]]"
local DUMMY_PROGRAM_PATH = "codeSync_dummy.lua"
local HOOK_CODE_FILE = "codeSync_hook_code.lua"

-- 初始化配置
local config = {
    computerId = os.getComputerID(),
    files = {
        -- 格式: [文件路径] = {version = 版本号, running = true/false}
    },
    serverId = nil -- 服务器计算机ID，如果已知
}

-- 加载配置
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        local content = file.readAll()
        file.close()
        local loadedConfig = textutils.unserialize(content)
        if loadedConfig then
            config = loadedConfig
        end
    end
end

-- 保存配置
local function saveConfig()
    local file = fs.open(CONFIG_FILE, "w")
    file.write(textutils.serialize(config))
    file.close()
end

-- 创建默认的dummy程序
local function createDummyProgram()
    if fs.exists(DUMMY_PROGRAM_PATH) then
        return
    end

    local file = fs.open(DUMMY_PROGRAM_PATH, "w")
    file.write([[
-- CodeSync dummy程序
-- 此程序仅在没有活跃程序时运行，用于接收更新

print("CodeSync dummy program started")

while true do
    os.pullEvent("modem_message")
end
]])
    file.close()

    print("Created dummy program: " .. DUMMY_PROGRAM_PATH)
end

-- 获取钩子代码
local function getHookCode()
    if not fs.exists(HOOK_CODE_FILE) then
        error("Hook code file not found: " .. HOOK_CODE_FILE)
    end

    -- 直接读取钩子代码文件内容
    local file = fs.open(HOOK_CODE_FILE, "r")
    local code = file.readAll()
    file.close()

    if not code or code == "" then
        error("Hook code file is empty")
    end

    return code
end

-- 检查文件是否包含特定模式
local function containsPattern(content, pattern)
    return string.find(content, pattern) ~= nil
end

-- 修改文件内容，替换os.pullEvent和os.pullEventRaw函数
local function applyPullEventHook(content, isTargetCode)
    local hookApplied = false
    local sideloadNeeded = false

    -- 如果是目标代码文件而不是钩子代码本身，则应用函数替换
    if isTargetCode then
        -- 替换os.pullEvent调用
        if containsPattern(content, "os%.pullEvent") then
            -- 将所有os.pullEvent调用替换为_cs_wrappedPullEvent(...)
            content = string.gsub(content, "os%.pullEvent%s*%(", "_cs_wrappedPullEvent(")
            hookApplied = true
        end

        -- 替换os.pullEventRaw调用
        if containsPattern(content, "os%.pullEventRaw") then
            -- 将所有os.pullEventRaw调用替换为_cs_wrappedPullEvent(...)
            content = string.gsub(content, "os%.pullEventRaw%s*%(", "_cs_wrappedPullEvent(")
            hookApplied = true
        end
    end

    -- 如果没有应用任何hook，需要修改钩子代码启用侧加载模式
    if not hookApplied and isTargetCode then
        sideloadNeeded = true
    end

    return content, sideloadNeeded
end

-- 包装目标代码为函数，以便侧加载模式下与事件监听器并行执行
local function wrapTargetCodeForSideload(targetCode)
    -- 创建包装函数
    local wrappedCode = [[
-- 侧加载模式启动代码

-- 包装目标程序为函数
local function _cs_runTargetProgram()
]]

    -- 对目标代码进行缩进处理
    local indentedCode = ""
    for line in string.gmatch(targetCode, "[^\r\n]+") do
        indentedCode = indentedCode .. "    " .. line .. "\n"
    end

    -- 添加缩进后的目标代码
    wrappedCode = wrappedCode .. indentedCode

    -- 添加并行执行逻辑
    wrappedCode = wrappedCode .. [[
end

-- 使用parallel库并行执行事件监听器和目标程序
print("[CodeSync Hook] Starting target program with parallel event listener")
parallel.waitForAny(_cs_sideloadEventListener, _cs_runTargetProgram)
]]

    return wrappedCode
end

-- 注入代码到Lua文件
local function injectCodeToFile(filePath)
    if not fs.exists(filePath) then
        return false
    end

    local file = fs.open(filePath, "r")
    local content = file.readAll()
    file.close()

    -- 检查是否已经注入了代码，包括回退逻辑
    local hasExistingHook = string.find(content, CODE_INJECTOR_MARKER) ~= nil
    local targetStartPosition = 1

    if hasExistingHook then
        -- 文件已经有了钩子，但让我们检查它是否是最新版本
        local hookCode = getHookCode()

        -- 尝试检测钩子代码的版本
        local contentVersion = string.match(content, "local CODESYNC_VERSION = \"([^\"]+)\"")
        local hookVersion = string.match(hookCode, "local CODESYNC_VERSION = \"([^\"]+)\"")

        if contentVersion and hookVersion and contentVersion == hookVersion then
            print("File already has up-to-date CodeSync hook: " .. filePath)
            return true
        else
            print("File has outdated CodeSync hook, updating: " .. filePath)

            -- 尝试移除旧的钩子代码
            local hookEndMarker = CODE_INJECTOR_END_MARKER
            local hookStart = string.find(content, CODE_INJECTOR_MARKER)
            local hookEnd = string.find(content, hookEndMarker)

            if hookStart and hookEnd then
                -- 找到了完整的钩子边界，可以安全地替换
                local beforeHook = string.sub(content, 1, hookStart - 1)
                local afterHook = string.sub(content, hookEnd + #hookEndMarker)

                -- 提取原始目标代码供后续分析和处理
                content = afterHook
                targetStartPosition = 1
            else
                -- 没有找到完整边界，做一个简单的替换
                -- 在实际代码中替换可能有风险，但我们假设钩子在文件开头
                -- 尝试查找第一个非钩子相关的代码行
                print("[CodeSync] Warn: Unable to find hook boundaries, trying to replace first non-hook line")
                local programStart = string.find(content, "\n\n",
                    string.find(content, CODE_INJECTOR_MARKER) + #CODE_INJECTOR_MARKER)

                if programStart then
                    -- 提取原始目标代码供后续分析和处理
                    content = string.sub(content, programStart + 1)
                    targetStartPosition = 1
                else
                    -- 无法安全分割代码，可能导致问题
                    print("[CodeSync] Error: Unable to safely split hook and target code")
                    -- 尝试使用字符串操作移除钩子代码
                    content = string.gsub(content, CODE_INJECTOR_MARKER .. ".-" .. CODE_INJECTOR_END_MARKER, "")
                    targetStartPosition = 1
                end
            end
        end
    end

    -- 分析目标文件
    local targetHasEventFunctions = containsPattern(content, "os%.pullEvent") or
                                        containsPattern(content, "os%.pullEventRaw")
    local needSideload = not targetHasEventFunctions

    print("Injecting CodeSync hook into: " .. filePath)

    -- 获取钩子代码
    local hookCode = getHookCode()

    -- 如果需要侧加载模式，修改钩子代码中的标志
    if needSideload then
        hookCode = string.gsub(hookCode, "local%s+_cs_sideloadPullEventFlag%s*=%s*false",
            "local _cs_sideloadPullEventFlag = true")
    end

    -- 如果目标代码使用了事件函数，应用相应的hook
    local targetContent = content
    if targetHasEventFunctions then
        targetContent, _ = applyPullEventHook(content, true)
    elseif needSideload then
        -- 如果使用侧加载模式，将目标代码包装为函数
        targetContent, _ = applyPullEventHook(content, true)
        targetContent = wrapTargetCodeForSideload(targetContent)
    end

    -- 添加钩子代码到文件开头
    local finalContent = hookCode .. "\n\n" .. targetContent

    -- 保存处理后的文件
    file = fs.open(filePath, "w")
    file.write(finalContent)
    file.close()

    if needSideload then
        print("Using sideload mode for this program")
    else
        print("Using direct function hook mode")
    end

    print("Code injection completed: " .. filePath)
    return true
end

-- 找到下一个需要运行的程序（不包括当前程序）
local function findNextProgramToRun(currentFilePath)
    -- 先尝试找到一个不同的程序
    for filePath, fileData in pairs(config.files) do
        -- 确保不是当前程序且不是dummy程序
        if fileData.running and fs.exists(filePath) and filePath ~= currentFilePath and filePath ~= DUMMY_PROGRAM_PATH then
            return filePath
        end
    end

    -- 如果没有找到下一个程序，且当前程序不是dummy程序，则返回当前程序
    if currentFilePath ~= DUMMY_PROGRAM_PATH and fs.exists(currentFilePath) then
        -- 确保当前程序在配置中
        if config.files[currentFilePath] and config.files[currentFilePath].running then
            return currentFilePath
        end
    end

    return nil
end

-- 找到需要运行的程序
local function findProgramToRun()
    -- 检查配置中标记为running的程序
    for filePath, fileData in pairs(config.files) do
        -- 确保不是dummy程序
        if fileData.running and fs.exists(filePath) and filePath ~= DUMMY_PROGRAM_PATH then
            return filePath
        end
    end

    -- 如果没有找到，使用dummy程序
    createDummyProgram()
    return DUMMY_PROGRAM_PATH
end

-- 主函数
local function main()
    print("CodeSync Client v" .. VERSION .. " starting...")

    loadConfig()
    createDummyProgram()

    print("Computer ID: " .. config.computerId)

    local currentProgram = nil

    while true do
        -- 找到并运行活跃程序
        local programToRun = currentProgram or findProgramToRun()
        if programToRun == nil then
            programToRun = DUMMY_PROGRAM_PATH
        end

        print("Starting program: " .. programToRun)

        -- 注入代码到文件
        injectCodeToFile(programToRun)

        -- 更新配置，但不更新dummy程序的配置
        if programToRun ~= DUMMY_PROGRAM_PATH then
            if not config.files[programToRun] then
                config.files[programToRun] = {}
            end
            config.files[programToRun].running = true
            saveConfig()
        end

        -- 运行程序
        shell.run(programToRun)

        print("Program ended: " .. programToRun)

        -- 重新加载配置
        loadConfig()

        -- 找下一个程序
        currentProgram = findNextProgramToRun(programToRun)

        if currentProgram then
            print("[CodeSync]Next program: " .. currentProgram)
        else
            print("[CodeSync]No next program found, will use dummy")
            currentProgram = DUMMY_PROGRAM_PATH
        end
    end
end

-- 启动主函数
main()
