-- CodeSync 服务器端
-- 用于向网络中的其他计算机分发代码
local VERSION = "1.0.0"
local CONFIG_FILE = "codeSync_config.cfg"
local BROADCAST_CHANNEL = 100
local RESPONSE_CHANNEL = 101
local REQUEST_CHANNEL = 102
local MAX_CHUNK_SIZE = 8000 -- 每个分段的最大字节数

-- 初始化配置
local config = {
    targets = {
        -- 格式: [计算机ID] = {files = {文件路径列表}, autoRestart = true/false}
    },
    files = {
        -- 格式: [文件路径] = {version = 版本号, checksum = 校验和}
    },
    clients = {
        -- 格式: [计算机ID] = {label = 标签, lastSeen = 最后活动时间, status = 状态, files = 文件列表}
    }
}

-- 查找扬声器外设
local function findSpeaker()
    return peripheral.find("speaker")
end

-- 播放声音提示
local function playSound(soundType)
    local speaker = findSpeaker()
    if not speaker then
        return false
    end

    if soundType == "file_changed" then
        -- 文件变化提示音 - 使用音符盒音色
        return speaker.playNote("bell", 1.0, 10)
    elseif soundType == "file_distribute" then
        -- 文件分发提示音
        return speaker.playNote("chime", 1.0, 15)
    elseif soundType == "file_complete" then
        -- 文件分发完成提示音
        return speaker.playSound("minecraft:entity.player.levelup", 1.0, 1.0)
    elseif soundType == "error" then
        -- 错误提示音
        return speaker.playNote("bass", 1.5, 5)
    end

    return false
end

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

-- 计算文件校验和
local function calculateChecksum(filePath)
    if not fs.exists(filePath) then
        return nil
    end

    local file = fs.open(filePath, "r")
    local content = file.readAll()
    file.close()

    -- 简单的校验和算法
    local sum = 0
    for i = 1, #content do
        sum = sum + string.byte(content, i)
    end
    return sum
end

-- 获取文件内容
local function getFileContent(filePath)
    if not fs.exists(filePath) then
        return nil
    end

    local file = fs.open(filePath, "r")
    local content = file.readAll()
    file.close()
    return content
end

-- 更新文件元数据
local function updateFileMetadata(filePath)
    if fs.exists(filePath) then
        local newChecksum = calculateChecksum(filePath)

        -- 只有在文件不存在配置中或校验和发生变化时才更新版本
        if not config.files[filePath] or config.files[filePath].checksum ~= newChecksum then
            local version = os.time()

            if not config.files[filePath] then
                config.files[filePath] = {}
            end

            config.files[filePath].checksum = newChecksum
            config.files[filePath].version = version
            return true -- 文件已变化
        end
    end
    return false -- 文件未变化
end

-- 扫描所有目标文件并更新元数据
local function scanTargetFiles()
    local allFiles = {}
    local changedFiles = {}

    -- 收集所有需要监控的文件
    for computerId, data in pairs(config.targets) do
        for _, filePath in ipairs(data.files) do
            allFiles[filePath] = true
        end
    end

    -- 更新文件元数据
    for filePath, _ in pairs(allFiles) do
        if updateFileMetadata(filePath) then
            changedFiles[filePath] = true
            -- 播放文件变化提示音
            playSound("file_changed")
        end
    end

    saveConfig()
    return changedFiles
end

-- 将数据分段
local function chunkData(data, maxSize)
    local chunks = {}
    local dataLen = #data
    local numChunks = math.ceil(dataLen / maxSize)

    for i = 1, numChunks do
        local startPos = (i - 1) * maxSize + 1
        local endPos = math.min(i * maxSize, dataLen)
        table.insert(chunks, data:sub(startPos, endPos))
    end

    return chunks, numChunks
end

-- 将文件分发到指定计算机
local function distributeFile(computerId, filePath, modem)
    if not fs.exists(filePath) then
        print("File does not exist: " .. filePath)
        return false
    end

    local content = getFileContent(filePath)
    if not content then
        print("Failed to read file: " .. filePath)
        return false
    end

    local fileInfo = {
        path = filePath,
        version = config.files[filePath].version,
        checksum = config.files[filePath].checksum,
        autoRestart = config.targets[computerId].autoRestart,
        size = #content
    }

    -- 先发送更新准备信号
    print("Sending update preparation signal to computer #" .. computerId .. " for file: " .. filePath)
    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
        type = "update_prepare",
        targetId = computerId,
        filePath = filePath
    })
    -- 播放文件分发开始提示音
    playSound("file_distribute")

    -- 发送文件元数据
    print("Sending file metadata to computer #" .. computerId .. ": " .. filePath)
    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
        type = "file_metadata",
        targetId = computerId,
        fileInfo = fileInfo
    })

    -- 分段发送文件内容
    local chunks, numChunks = chunkData(content, MAX_CHUNK_SIZE)
    print("File size: " .. #content .. " bytes, sending in " .. numChunks .. " chunks")

    for i, chunk in ipairs(chunks) do
        sleep(0.1) -- 防止发送过快导致接收方丢失数据
        modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
            type = "file_chunk",
            targetId = computerId,
            filePath = filePath,
            chunkIndex = i,
            totalChunks = numChunks,
            data = chunk
        })
        print("Sending file chunk " .. i .. "/" .. numChunks)
    end

    -- 发送文件传输完成通知
    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
        type = "file_complete",
        targetId = computerId,
        filePath = filePath,
        version = fileInfo.version,
        checksum = fileInfo.checksum,
        autoRestart = fileInfo.autoRestart
    })

    print("File transfer complete: " .. filePath)
    -- 播放文件分发完成提示音
    playSound("file_complete")
    return true
end

-- 初始化调制解调器
local function initModem()
    local modem = peripheral.find("modem")
    if not modem then
        error("No modem found")
    end

    modem.open(BROADCAST_CHANNEL)
    modem.open(RESPONSE_CHANNEL)
    modem.open(REQUEST_CHANNEL)

    return modem
end

-- 添加目标计算机
local function addTarget(computerId, files, autoRestart)
    config.targets[computerId] = {
        files = files,
        autoRestart = autoRestart or true
    }
    saveConfig()

    -- 更新相关文件的元数据
    for _, filePath in ipairs(files) do
        updateFileMetadata(filePath)
    end
    saveConfig()
end

-- 发送指令到客户端
local function sendCommand(computerId, command, params, modem)
    if not computerId or not command then
        print("Invalid command parameters")
        return false
    end

    local message = {
        type = "command",
        targetId = computerId,
        command = command
    }

    -- 合并其他参数
    if params then
        for k, v in pairs(params) do
            message[k] = v
        end
    end

    print("Sending command '" .. command .. "' to computer #" .. computerId)
    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, message)
    return true
end

-- 发现网络中的客户端
local function discoverClients(modem)
    print("Discovering clients on network...")
    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
        type = "server_discovery"
    })
end

-- 更新客户端状态
local function updateClientStatus(computerId, status, details)
    if not config.clients[computerId] then
        config.clients[computerId] = {
            label = details.label or "Computer #" .. computerId,
            files = {}
        }
    end

    config.clients[computerId].lastSeen = os.time()
    config.clients[computerId].status = status

    -- 更新其他详细信息
    if details then
        for k, v in pairs(details) do
            if k ~= "timestamp" then -- 不保存时间戳
                config.clients[computerId][k] = v
            end
        end
    end

    saveConfig()
end

-- 注册客户端
local function registerClient(message)
    if not message or not message.computerId then
        return false
    end

    local computerId = message.computerId
    local label = message.label or "Computer #" .. computerId
    local clientVersion = message.version or "Unknown"
    local files = message.files or {}

    print("Client registered: " .. label .. " (ID: " .. computerId .. ", Version: " .. clientVersion .. ")")

    -- 更新客户端信息
    config.clients[computerId] = {
        label = label,
        version = clientVersion,
        lastSeen = os.time(),
        files = files,
        status = "registered"
    }

    -- 如果这个计算机已经是目标，同步所有文件
    if config.targets[computerId] then
        print("This computer is a target. Synchronizing files...")
    end

    saveConfig()
    return true
end

-- 显示帮助信息
local function showHelp()
    print("CodeSync Server v" .. VERSION)
    print("Commands:")
    print("  add <computerID> <filePath> [autoRestart=true] - Add target computer and file")
    print("  remove <computerID> - Remove target computer")
    print("  list - List all target computers and their files")
    print("  sync <computerID> [filePath] - Sync file to specified computer")
    print("  syncall - Sync all files to all computers")
    print("  scan - Scan all files and update metadata")
    print("  discover - Discover clients on network")
    print("  clients - List all known clients")
    print("  cmd <computerID> <command> [params] - Send command to client")
    print("  run <computerID> <filePath> - Run file on client")
    print("  stop <computerID> - Stop running program on client")
    print("  restart <computerID> - Restart client computer")
    print("  status <computerID> - Request status from client")
    print("  help - Show this help information")
    print("  exit - Exit program")
end

-- 解析命令
local function parseCommand(input, modem)
    local args = {}
    for arg in string.gmatch(input, "%S+") do
        table.insert(args, arg)
    end

    local cmd = args[1]
    if not cmd then
        return
    end

    if cmd == "add" then
        if #args < 3 then
            print("Usage: add <computerID> <filePath> [autoRestart=true]")
            return
        end

        local computerId = tonumber(args[2])
        local filePath = args[3]
        local autoRestart = true
        if args[4] == "false" then
            autoRestart = false
        end

        if not computerId then
            print("Invalid computer ID")
            return
        end

        if not fs.exists(filePath) then
            print("File does not exist: " .. filePath)
            return
        end

        local files = {}
        if config.targets[computerId] then
            files = config.targets[computerId].files
        end

        local found = false
        for i, path in ipairs(files) do
            if path == filePath then
                found = true
                break
            end
        end

        if not found then
            table.insert(files, filePath)
        end

        addTarget(computerId, files, autoRestart)
        print("Added computer #" .. computerId .. " and file " .. filePath)

    elseif cmd == "remove" then
        if #args < 2 then
            print("Usage: remove <computerID>")
            return
        end

        local computerId = tonumber(args[2])
        if not computerId then
            print("Invalid computer ID")
            return
        end

        if config.targets[computerId] then
            config.targets[computerId] = nil
            saveConfig()
            print("Removed computer #" .. computerId)
        else
            print("Computer #" .. computerId .. " does not exist")
        end

    elseif cmd == "list" then
        print("Target computer list:")
        for computerId, data in pairs(config.targets) do
            print("  Computer #" .. computerId .. " (AutoRestart: " .. tostring(data.autoRestart) .. ")")
            for _, filePath in ipairs(data.files) do
                local fileInfo = config.files[filePath]
                local version = fileInfo and fileInfo.version or "Unknown"
                print("    - " .. filePath .. " (Version: " .. version .. ")")
            end
        end

    elseif cmd == "sync" then
        if #args < 2 then
            print("Usage: sync <computerID> [filePath]")
            return
        end

        local computerId = tonumber(args[2])
        if not computerId or not config.targets[computerId] then
            print("Invalid computer ID or computer does not exist")
            return
        end

        local filePath = args[3]
        if filePath then
            local found = false
            for _, path in ipairs(config.targets[computerId].files) do
                if path == filePath then
                    found = true
                    break
                end
            end

            if found then
                distributeFile(computerId, filePath, modem)
            else
                print("File not associated with this computer: " .. filePath)
            end
        else
            for _, path in ipairs(config.targets[computerId].files) do
                distributeFile(computerId, path, modem)
            end
        end

    elseif cmd == "syncall" then
        for computerId, data in pairs(config.targets) do
            for _, filePath in ipairs(data.files) do
                distributeFile(computerId, filePath, modem)
            end
        end

    elseif cmd == "scan" then
        scanTargetFiles()
        print("Scanned all files and updated metadata")

    elseif cmd == "discover" then
        discoverClients(modem)

    elseif cmd == "clients" then
        print("Known clients:")
        for computerId, data in pairs(config.clients) do
            local lastSeen = data.lastSeen or 0
            local status = data.status or "unknown"
            local timeSince = os.time() - lastSeen
            local activeStatus = timeSince < 60 and "ACTIVE" or "INACTIVE"

            print(string.format("  Client #%d: %s (%s, %s)", computerId, data.label or "Unknown", status, activeStatus))

            if data.runningProgram then
                print("    Running: " .. data.runningProgram)
            end

            -- 显示文件列表
            if data.files and type(data.files) == "table" then
                print("    Files:")
                for filePath, fileData in pairs(data.files) do
                    local version = fileData.version or "Unknown"
                    local status = fileData.running and "Running" or "Stopped"
                    print("      - " .. filePath .. " (Ver: " .. version .. ", " .. status .. ")")
                end
            end
        end

    elseif cmd == "cmd" then
        if #args < 3 then
            print("Usage: cmd <computerID> <command> [params]")
            return
        end

        local computerId = tonumber(args[2])
        local command = args[3]
        local params = {}

        if #args > 3 then
            -- 额外参数
            if command == "run" and #args >= 4 then
                params.filePath = args[4]
            end
        end

        if computerId and command then
            sendCommand(computerId, command, params, modem)
        else
            print("Invalid computer ID or command")
        end

    elseif cmd == "run" then
        if #args < 3 then
            print("Usage: run <computerID> <filePath>")
            return
        end

        local computerId = tonumber(args[2])
        local filePath = args[3]

        if computerId and filePath then
            sendCommand(computerId, "run", {
                filePath = filePath
            }, modem)
        else
            print("Invalid computer ID or file path")
        end

    elseif cmd == "stop" then
        if #args < 2 then
            print("Usage: stop <computerID>")
            return
        end

        local computerId = tonumber(args[2])

        if computerId then
            sendCommand(computerId, "terminate", nil, modem)
        else
            print("Invalid computer ID")
        end

    elseif cmd == "restart" then
        if #args < 2 then
            print("Usage: restart <computerID>")
            return
        end

        local computerId = tonumber(args[2])

        if computerId then
            sendCommand(computerId, "restart", nil, modem)
        else
            print("Invalid computer ID")
        end

    elseif cmd == "status" then
        if #args < 2 then
            print("Usage: status <computerID>")
            return
        end

        local computerId = tonumber(args[2])

        if computerId then
            sendCommand(computerId, "status", nil, modem)
        else
            print("Invalid computer ID")
        end

    elseif cmd == "help" then
        showHelp()

    elseif cmd == "exit" then
        return true

    else
        print("Unknown command: " .. cmd)
        print("Type 'help' for help")
    end

    return false
end

-- 监听请求线程
local function listenThread(modem)
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

        if channel == REQUEST_CHANNEL and type(message) == "table" then
            -- 处理文件请求
            if message.type == "file_request" then
                local computerId = message.computerId
                local filePath = message.filePath

                if config.targets[computerId] then
                    local found = false
                    for _, path in ipairs(config.targets[computerId].files) do
                        if path == filePath then
                            found = true
                            break
                        end
                    end

                    if found then
                        distributeFile(computerId, filePath, modem)
                    end
                end
                -- 处理版本检查
            elseif message.type == "version_check" then
                local computerId = message.computerId
                local filePath = message.filePath
                local clientVersion = message.version

                if config.targets[computerId] and config.files[filePath] then
                    local serverVersion = config.files[filePath].version

                    if serverVersion > clientVersion then
                        distributeFile(computerId, filePath, modem)
                    end
                end
                -- 处理客户端注册
            elseif message.type == "client_register" then
                registerClient(message)
                -- 处理状态更新
            elseif message.type == "status_update" then
                local computerId = message.computerId
                local status = message.status
                local details = message.details or {}

                if computerId and status then
                    updateClientStatus(computerId, status, details)
                    print("Status update from #" .. computerId .. ": " .. status)

                    -- 如果是命令执行结果
                    if status == "command_executed" or status == "command_error" then
                        print("Command result: " .. (details.command or "unknown") .. " - " ..
                                  (details.success and "Success" or "Failed") ..
                                  (details.error and (" Error: " .. details.error) or ""))
                        -- 如果是程序终止
                    elseif status == "program_terminated" then
                        print("Program terminated on #" .. computerId .. ": " .. (details.filePath or "unknown") ..
                                  " (Ran for " .. (details.runDuration or "unknown") .. " seconds)")
                        -- 如果是文件更新完成
                    elseif status == "file_updated" then
                        print("File updated on #" .. computerId .. ": " .. (details.filePath or "unknown") ..
                                  " (Version: " .. (details.version or "unknown") .. ")")
                        -- 如果是状态报告
                    elseif status == "status_report" then
                        print("Status report from #" .. computerId .. ":")
                        print("  Running program: " .. (details.runningProgram or "None"))
                        print("  Free space: " .. (details.freeSpace or "Unknown") .. " bytes")
                    end
                end
            end
        end
    end
end

-- 文件监控线程
local function monitorThread(modem)
    while true do
        local changedFiles = scanTargetFiles()

        for computerId, data in pairs(config.targets) do
            for _, filePath in ipairs(data.files) do
                local fileInfo = config.files[filePath]
                -- 只在文件实际发生变化时才发送更新通知
                if changedFiles[filePath] and fileInfo then
                    print("File change detected, sending update notification: " .. filePath)
                    modem.transmit(BROADCAST_CHANNEL, RESPONSE_CHANNEL, {
                        type = "version_update",
                        targetId = computerId,
                        filePath = filePath,
                        version = fileInfo.version
                    })
                end
            end
        end

        sleep(5) -- 每5秒检查一次文件变化
    end
end

-- 客户端活动监控线程
local function clientMonitorThread()
    while true do
        local currentTime = os.time()

        -- 检查不活跃的客户端
        for computerId, data in pairs(config.clients) do
            local lastSeen = data.lastSeen or 0
            local timeSince = currentTime - lastSeen

            -- 如果超过1分钟没有心跳，标记为不活跃
            if timeSince > 60 then
                if data.status ~= "inactive" then
                    print("Client #" .. computerId .. " (" .. (data.label or "Unknown") .. ") is now inactive")
                    config.clients[computerId].status = "inactive"
                    saveConfig()
                end
            end
        end

        sleep(60) -- 每分钟检查一次
    end
end

-- 主函数
local function main()
    print("CodeSync Server v" .. VERSION .. " starting...")

    loadConfig()
    local modem = initModem()
    showHelp()

    -- 检查扬声器是否可用
    local speaker = findSpeaker()
    if speaker then
        print("Speaker found, sound notifications enabled")
        -- 播放启动音效
        speaker.playSound("minecraft:block.note_block.chime", 1.0, 1.0)
    else
        print("No speaker found, sound notifications disabled")
    end

    -- 启动各线程
    parallel.waitForAny(function()
        listenThread(modem)
    end, function()
        monitorThread(modem)
    end, function()
        clientMonitorThread()
    end, function()
        -- 启动后自动发现客户端
        sleep(2)
        discoverClients(modem)

        -- 命令处理线程
        while true do
            write("> ")
            local input = read()
            local shouldExit = parseCommand(input, modem)
            if shouldExit then
                break
            end
        end
    end)
end

main()
