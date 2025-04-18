--[[ CODESYNC INJECTED CODE ]] -- CodeSync钩子代码
-- 这个文件包含要注入到其他程序中的代码
-- 它不是被导入的模块，而是直接插入到活跃程序中
print("[CodeSync Hook] Initializing hook...")

-- 常量定义
local CODESYNC_VERSION = "1.0.2"
local BROADCAST_CHANNEL = 100
local RESPONSE_CHANNEL = 101
local REQUEST_CHANNEL = 102
local CONFIG_FILE = "codeSync_client_config.cfg"

-- 控制变量
local _cs_useAlternativeExit = true -- 为true时使用备用退出方案
local _cs_sideloadPullEventFlag = false -- 是否使用侧加载方式监听事件

-- 初始化配置
local _cs_config = {
    computerId = os.getComputerID(),
    files = {},
    serverId = nil
}

-- 当前运行的程序
local _cs_runningProgram = {
    path = shell.getRunningProgram()
}

-- 文件传输缓冲区
local _cs_fileTransfers = {}

-- 控制变量
local _cs_hookActive = true
local _cs_updateDetected = false
local _cs_modem = nil
local _cs_heartbeatTimer = nil

-- 终止程序的函数
local function _cs_terminateProgram(reason)
    print("[CodeSync Hook] Now Terminate: " .. (reason or "Unknown reason"))

    if _cs_useAlternativeExit then
        -- 方法1: 使用shell.exit()尝试退出(可能不会立即生效)
        if shell and shell.exit then
            shell.exit()
            -- 如果shell.exit()没有立即终止程序，继续执行
        end

        -- 方法2: 生成terminate事件并退出
        os.queueEvent("terminate")
        -- 等待片刻让事件处理
        sleep(0.1)

        -- 方法3: 使用return (只有在顶层脚本中才有效)
        print("[CodeSync Hook] Failed to terminate with alternative methods, using error")

        -- 最后方法: 回退到使用error
        error(reason, 0)
    else
        -- 直接使用error退出
        error(reason, 0)
    end
end

-- 加载配置
local function _cs_loadConfig()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        local content = file.readAll()
        file.close()
        local loadedConfig = textutils.unserialize(content)
        if loadedConfig then
            _cs_config = loadedConfig
        end
    end
end

-- 保存配置
local function _cs_saveConfig()
    local file = fs.open(CONFIG_FILE, "w")
    file.write(textutils.serialize(_cs_config))
    file.close()
end

-- 初始化调制解调器
local function _cs_initModem()
    if _cs_modem then
        return _cs_modem
    end

    _cs_modem = peripheral.find("modem")
    if not _cs_modem then
        print("[CodeSync Hook] Warning: No modem found")
        return nil
    end

    _cs_modem.open(BROADCAST_CHANNEL)
    _cs_modem.open(RESPONSE_CHANNEL)
    _cs_modem.open(REQUEST_CHANNEL)

    print("[CodeSync Hook] Modem initialized on channels " .. BROADCAST_CHANNEL .. ", " .. RESPONSE_CHANNEL .. ", " ..
              REQUEST_CHANNEL .. " successfully")
    return _cs_modem
end

-- 向服务器发送状态更新
local function _cs_sendStatusUpdate(status, details)
    local m = _cs_modem or _cs_initModem()
    if not m then
        print("[CodeSync Hook] Cannot send status update: No available modem")
        return
    end

    print("[CodeSync Hook] Sending status: " .. status)
    m.transmit(REQUEST_CHANNEL, RESPONSE_CHANNEL, {
        type = "status_update",
        computerId = _cs_config.computerId,
        status = status,
        details = details or {},
        timestamp = os.time()
    })
end

-- 发送注册信息到服务器
local function _cs_registerWithServer()
    local m = _cs_modem or _cs_initModem()
    if not m then
        print("[CodeSync Hook] Cannot register client with server: No available modem")
        return
    end

    print("[CodeSync Hook] Registering client with server...")

    m.transmit(REQUEST_CHANNEL, RESPONSE_CHANNEL, {
        type = "client_register",
        computerId = _cs_config.computerId,
        label = os.getComputerLabel() or "Unnamed Computer",
        files = _cs_config.files,
        version = CODESYNC_VERSION
    })
end

-- 设置心跳定时器
local function _cs_setupHeartbeat()
    if _cs_heartbeatTimer then
        -- 取消现有的心跳定时器
        -- 在ComputerCraft中没有直接取消定时器的方法，我们只需设置一个新的
    end

    _cs_heartbeatTimer = os.startTimer(30) -- 30秒发送一次心跳
end

-- 发送心跳
local function _cs_sendHeartbeat()
    _cs_sendStatusUpdate("heartbeat", {
        runningProgram = _cs_runningProgram.path,
        freeSpace = fs.getFreeSpace("/")
    })
    _cs_setupHeartbeat()
end

-- 接收文件元数据
local function _cs_receiveFileMetadata(message)
    if not message or not message.fileInfo or not message.fileInfo.path then
        print("[CodeSync Hook] Received invalid file metadata")
        return
    end

    local fileInfo = message.fileInfo
    local filePath = fileInfo.path

    -- 初始化文件传输
    _cs_fileTransfers[filePath] = {
        path = filePath,
        version = fileInfo.version,
        checksum = fileInfo.checksum,
        autoRestart = fileInfo.autoRestart,
        size = fileInfo.size,
        chunks = {},
        receivedChunks = 0,
        totalChunks = 0,
        complete = false
    }

    print("[CodeSync Hook] File transfer started: " .. filePath .. " (Size: " .. fileInfo.size .. " bytes)")
end

-- 接收文件分段
local function _cs_receiveFileChunk(message)
    if not message or not message.filePath or not message.data then
        print("[CodeSync Hook] Received invalid file chunk")
        return
    end

    local filePath = message.filePath
    local chunkIndex = message.chunkIndex
    local totalChunks = message.totalChunks
    local data = message.data

    if not _cs_fileTransfers[filePath] then
        print("[CodeSync Hook] Received invalid file chunk")
        return
    end

    local transfer = _cs_fileTransfers[filePath]
    transfer.chunks[chunkIndex] = data
    transfer.receivedChunks = transfer.receivedChunks + 1
    transfer.totalChunks = totalChunks

    print("[CodeSync Hook] Received file chunk: " .. chunkIndex .. "/" .. totalChunks .. " - " .. filePath)
end

-- 完成文件传输
local function _cs_completeFileTransfer(message)
    if not message or not message.filePath then
        print("[CodeSync Hook] Received invalid file completion message")
        return
    end

    local filePath = message.filePath

    if not _cs_fileTransfers[filePath] then
        print("[CodeSync Hook] Received invalid file completion message")
        return
    end

    local transfer = _cs_fileTransfers[filePath]

    -- 检查是否所有分段都已收到
    if transfer.receivedChunks < transfer.totalChunks then
        print("[CodeSync Hook] File transfer incomplete: " .. filePath .. " (" .. transfer.receivedChunks .. "/" ..
                  transfer.totalChunks .. ")")
        -- 通知服务器传输失败
        _cs_sendStatusUpdate("file_transfer_incomplete", {
            filePath = filePath,
            receivedChunks = transfer.receivedChunks,
            totalChunks = transfer.totalChunks
        })
        return false
    end

    -- 组装文件内容
    local content = ""
    for i = 1, transfer.totalChunks do
        if not transfer.chunks[i] then
            print("[CodeSync Hook] Missing file chunk: " .. i .. "/" .. transfer.totalChunks)
            return false
        end
        content = content .. transfer.chunks[i]
    end

    -- 确保目录存在
    local dir = fs.getDir(filePath)
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    -- 检查文件是否是正在运行中的程序
    local needRestart = false
    if _cs_runningProgram.path == filePath then
        print("[CodeSync Hook] Update file is currently running, restart needed")
        needRestart = true
        -- 设置更新标志，使当前程序知道需要重启
        _cs_updateDetected = true
    end

    -- 写入文件
    local file = fs.open(filePath, "w")
    if not file then
        print("[CodeSync Hook] Cannot write file: " .. filePath)
        return false
    end

    file.write(content)
    file.close()

    print("[CodeSync Hook] File transfer completed: " .. filePath .. " (Version: " .. transfer.version .. ")")

    -- 更新配置
    if not _cs_config.files[filePath] then
        _cs_config.files[filePath] = {}
    end
    _cs_config.files[filePath].version = transfer.version
    _cs_saveConfig()

    -- 通知服务器文件更新成功
    _cs_sendStatusUpdate("file_updated", {
        filePath = filePath,
        version = transfer.version
    })

    -- 如果需要自动重启且不是当前运行的程序
    if transfer.autoRestart and (not _cs_runningProgram.path or _cs_runningProgram.path ~= filePath) then
        print("[CodeSync Hook] Marking file for auto-restart after program completion")
        if not _cs_config.files[filePath] then
            _cs_config.files[filePath] = {}
        end
        _cs_config.files[filePath].running = true
        _cs_saveConfig()

        -- 发送状态更新
        _cs_sendStatusUpdate("auto_restart_flagged", {
            filePath = filePath,
            version = transfer.version
        })
    end

    -- 清理传输数据
    _cs_fileTransfers[filePath] = nil

    -- 准备关闭当前程序
    print("[CodeSync Hook] Current program has been updated, will terminate")
    print("[CodeSync Hook] terminate in 3")
    sleep(0.5)
    print("[CodeSync Hook] terminate in 2")
    sleep(0.5)
    print("[CodeSync Hook] terminate in 1")
    sleep(0.5)
    _cs_sendStatusUpdate("program_terminating", {
        reason = "update_applied",
        filePath = filePath
    })
    os.queueEvent("codeSync_update_restart")
    _cs_terminateProgram("CODESYNC_UPDATE_RESTART")

    return true
end

-- 请求文件更新
local function _cs_requestFileUpdate(filePath)
    local m = _cs_modem or _cs_initModem()
    if not m then
        print("[CodeSync Hook] No modem available to request file update: " .. filePath)
        return
    end

    print("[CodeSync Hook] Requesting file update: " .. filePath)

    m.transmit(REQUEST_CHANNEL, RESPONSE_CHANNEL, {
        type = "file_request",
        computerId = _cs_config.computerId,
        filePath = filePath
    })
end

-- 处理命令指令
local function _cs_handleCommand(message)
    if not message or not message.command then
        return
    end

    local command = message.command

    if command == "run" and message.filePath then
        local filePath = message.filePath
        if fs.exists(filePath) then
            print("[CodeSync Hook] Executing server command: Run " .. filePath)
            -- 通知客户端命令已收到
            _cs_sendStatusUpdate("command_received", {
                command = command,
                filePath = filePath
            })

            -- 标记文件为应该运行
            if not _cs_config.files[filePath] then
                _cs_config.files[filePath] = {}
            end
            _cs_config.files[filePath].running = true
            _cs_saveConfig()

            -- 触发重启当前程序
            print("[CodeSync Hook] Need to terminate current program to run requested file")
            _cs_sendStatusUpdate("program_terminating", {
                reason = "command_run",
                filePath = filePath
            })
            _cs_updateDetected = true
            _cs_terminateProgram("CODESYNC_RUN_REQUESTED")
        else
            print("[CodeSync Hook] Cannot execute server command: File does not exist " .. filePath)
            _cs_sendStatusUpdate("command_error", {
                command = command,
                filePath = filePath,
                error = "File does not exist"
            })
        end
    elseif command == "terminate" then
        print("[CodeSync Hook] Executing server command: Terminate current program")
        _cs_sendStatusUpdate("command_executed", {
            command = command,
            success = true
        })
        _cs_updateDetected = true
        _cs_terminateProgram("CODESYNC_TERMINATE_REQUESTED")
    elseif command == "restart" then
        print("[CodeSync Hook] Executing server command: Restart computer")
        _cs_sendStatusUpdate("command_executing", {
            command = command,
            success = true
        })
        os.reboot()
    elseif command == "status" then
        print("[CodeSync Hook] Executing server command: Send status report")
        _cs_sendStatusUpdate("status_report", {
            runningProgram = _cs_runningProgram.path,
            files = _cs_config.files,
            freeSpace = fs.getFreeSpace("/")
        })
    else
        print("[CodeSync Hook] Unknown server command: " .. command)
        _cs_sendStatusUpdate("command_error", {
            command = command,
            error = "Unknown command"
        })
    end
end

-- 处理modem消息
local function _cs_handleModemMessage(side, channel, replyChannel, message, distance)
    if channel == BROADCAST_CHANNEL and type(message) == "table" then
        -- 只处理发给当前计算机的消息
        if message.targetId == _cs_config.computerId then
            -- 更新准备信号
            if message.type == "update_prepare" then
                print("[CodeSync Hook] Received update prepare signal: " .. message.filePath)
                -- 由于现在的实现会将更新模块和目标程序一起打包，所以不需要再发送更新准备信号，因为 时刻准备着！

                -- 文件元数据
            elseif message.type == "file_metadata" then
                _cs_receiveFileMetadata(message)
                -- 文件分段
            elseif message.type == "file_chunk" then
                _cs_receiveFileChunk(message)
                -- 文件传输完成
            elseif message.type == "file_complete" then
                _cs_completeFileTransfer(message)
                -- 版本更新通知
            elseif message.type == "version_update" and message.filePath then
                local filePath = message.filePath
                local serverVersion = message.version

                if not _cs_config.files[filePath] or not _cs_config.files[filePath].version or
                    _cs_config.files[filePath].version < serverVersion then
                    _cs_requestFileUpdate(filePath)
                end
                -- 服务器命令
            elseif message.type == "command" then
                _cs_handleCommand(message)
            end
            -- 处理服务器发现请求
        elseif message.type == "server_discovery" then
            -- 响应服务器发现请求
            _cs_registerWithServer()
        end
    end
end

-- 包装的pullEvent事件处理函数
function _cs_wrappedPullEvent(filter)
    -- 如果已检测到更新，立即退出
    if _cs_updateDetected then
        print("[CodeSync Hook] Update detected in pullEvent, terminating...")
        print("[CodeSync Hook] terminate in 3")
        sleep(0.5)
        print("[CodeSync Hook] terminate in 2")
        sleep(0.5)
        print("[CodeSync Hook] terminate in 1")
        sleep(0.5)
        _cs_terminateProgram("CODESYNC_UPDATE_RESTART")
    end

    -- 确保modem已初始化
    _cs_initModem()

    -- 使用原始函数等待事件
    local eventData = {os.pullEvent(filter)}
    local event = eventData[1]

    -- 处理modem消息事件
    if event == "modem_message" then
        _cs_handleModemMessage(select(2, unpack(eventData)))
        -- 处理定时器事件 - 用于心跳
    elseif event == "timer" and eventData[2] == _cs_heartbeatTimer then
        _cs_sendHeartbeat()
    end

    -- 如果在处理事件过程中检测到更新，退出
    if _cs_updateDetected then
        print("[CodeSync Hook] Update detected in pullEvent, terminating...")
        print("[CodeSync Hook] terminate in 3")
        sleep(0.5)
        print("[CodeSync Hook] terminate in 2")
        sleep(0.5)
        print("[CodeSync Hook] terminate in 1")
        sleep(0.5)
        _cs_terminateProgram("CODESYNC_UPDATE_RESTART")
    end

    return unpack(eventData)
end

-- 侧加载事件监听器线程，用于在parallel中与主程序并行运行
function _cs_sideloadEventListener()
    print("[CodeSync Hook] Starting sideload event listener thread")

    while _cs_hookActive do
        -- 初始化modem (如果需要)
        _cs_initModem()

        -- 尝试获取modem消息事件
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

        -- 处理消息
        if event == "modem_message" then
            _cs_handleModemMessage(side, channel, replyChannel, message, distance)
        end

        -- 如果检测到更新，尝试终止程序
        if _cs_updateDetected then
            print("[CodeSync Hook] Update detected in sideload listener, terminating...")
            print("[CodeSync Hook] terminate in 3")
            sleep(0.5)
            print("[CodeSync Hook] terminate in 2")
            sleep(0.5)
            print("[CodeSync Hook] terminate in 1")
            sleep(0.5)
            os.queueEvent("codeSync_update_restart")
            _cs_terminateProgram("CODESYNC_UPDATE_RESTART")
            break
        end
    end
end

-- 初始化hook
local function _cs_initHook()
    print("[CodeSync Hook] Hook initialized at program: " .. _cs_runningProgram.path)

    -- 加载配置
    _cs_loadConfig()

    -- 初始化modem
    _cs_initModem()

    -- 注册客户端
    _cs_registerWithServer()

    -- 设置心跳定时器
    _cs_setupHeartbeat()
end

-- 初始化钩子
_cs_initHook()

-- CodeSync钩子初始化完成
print("[CodeSync Hook] Hook Initialized " .. CODESYNC_VERSION)

--[[ CODESYNC HOOK END ]]
