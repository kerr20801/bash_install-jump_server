#!/bin/bash
# SSH Key 自動化管理工具
# 功能：生成、分發、輪換、撤銷 SSH 密鑰

# 配置參數
JUMP_KEY_DIR="/etc/ssh/jump_keys"
USER_KEY_DIR="/home"
KEY_CONFIG="/etc/jump_server/ssh_keys.conf"
AUDIT_LOG="/var/log/jump_sessions/ssh_key_audit.log"
JUMP_GROUP="jump_users"

# SSH Key 配置
KEY_TYPE="ed25519"
KEY_SIZE="256"
KEY_LIFETIME_DAYS="90"

# 顯示標題
show_header() {
    clear
    echo "======================================="
    echo "         SSH Key 管理工具 v1.0        "
    echo "======================================="
    echo ""
}

# 審計日誌記錄
log_audit() {
    local event_type="$1"
    local username="$2"
    local details="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$event_type] User: $username, Details: $details" >> "$AUDIT_LOG"
    logger -t "ssh_key_manager" "[$event_type] User: $username, Details: $details"
}

# 檢查執行權限
check_permissions() {
    local action="$1"
    local username=$(whoami)
    
    # 檢查是否為root或在指定群組中
    if [ "$(id -u)" -eq 0 ]; then
        return 0  # root 擁有所有權限
    fi
    
    # 載入權限配置
    if [ -f "/etc/jump_server/permissions.conf" ]; then
        source "/etc/jump_server/permissions.conf"
        
        case "$action" in
            "generate_user"|"view_keys")
                # 所有 jump_users 都可以
                if groups "$username" | grep -q "$JUMP_GROUP"; then
                    return 0
                fi
                ;;
            "distribute"|"rotate"|"revoke")
                # 只有管理員可以
                if [[ " ${key_admin_users} ${key_power_users} " =~ " ${username} " ]]; then
                    return 0
                fi
                ;;
        esac
    fi
    
    echo "❌ 錯誤: 用戶 $username 沒有執行 '$action' 的權限"
    log_audit "PERMISSION_DENIED" "$username" "Action: $action"
    return 1
}

# 初始化 SSH Key 管理目錄
initialize_key_directories() {
    echo "🔧 初始化 SSH Key 管理目錄..."
    
    # 創建主目錄結構
    local dirs=(
        "$JUMP_KEY_DIR"
        "$JUMP_KEY_DIR/master"
        "$JUMP_KEY_DIR/users"
        "$JUMP_KEY_DIR/servers"
        "$JUMP_KEY_DIR/backups"
        "$(dirname "$KEY_CONFIG")"
        "$(dirname "$AUDIT_LOG")"
    )
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            if mkdir -p "$dir" 2>/dev/null; then
                echo "✅ 創建目錄: $dir"
            else
                echo "⚠️  警告: 無法創建目錄 $dir (可能需要 sudo 權限)"
            fi
        fi
    done
    
    # 設置安全權限
    if [ -d "$JUMP_KEY_DIR" ]; then
        chmod 700 "$JUMP_KEY_DIR" 2>/dev/null || true
        chmod 700 "$JUMP_KEY_DIR/master" 2>/dev/null || true
        chmod 755 "$JUMP_KEY_DIR/users" 2>/dev/null || true
        chown -R root:$JUMP_GROUP "$JUMP_KEY_DIR" 2>/dev/null || true
    fi
    
    # 創建配置文件
    if [ ! -f "$KEY_CONFIG" ]; then
        create_key_config
    fi
    
    echo "✅ SSH Key 管理目錄初始化完成"
}

# 創建 SSH Key 配置文件
create_key_config() {
    cat > "$KEY_CONFIG" << EOF
# SSH Key 管理配置
KEY_TYPE="$KEY_TYPE"
KEY_SIZE="$KEY_SIZE"
KEY_LIFETIME_DAYS="$KEY_LIFETIME_DAYS"
JUMP_KEY_DIR="$JUMP_KEY_DIR"

# 最後生成的主密鑰信息
CURRENT_MASTER_KEY=""
MASTER_KEY_DATE=""
MASTER_KEY_EXPIRES=""

# 統計信息
TOTAL_USER_KEYS=0
TOTAL_DISTRIBUTED_KEYS=0
LAST_ROTATION_DATE=""
EOF
    
    chmod 640 "$KEY_CONFIG" 2>/dev/null || true
    chown root:$JUMP_GROUP "$KEY_CONFIG" 2>/dev/null || true
}

# 為用戶生成 SSH Key
generate_user_ssh_key() {
    local target_user="$1"
    local current_user=$(whoami)
    
    if [ -z "$target_user" ]; then
        read -p "請輸入用戶名: " target_user
    fi
    
    if [ -z "$target_user" ]; then
        echo "❌ 用戶名不能為空"
        return 1
    fi
    
    # 檢查目標用戶是否存在
    if ! id "$target_user" &>/dev/null; then
        echo "❌ 用戶 '$target_user' 不存在"
        return 1
    fi
    
    local user_home="/home/$target_user"
    local ssh_dir="$user_home/.ssh"
    local key_file="$ssh_dir/id_$KEY_TYPE"
    
    echo "🔑 為用戶 '$target_user' 生成 SSH Key..."
    
    # 檢查是否已有密鑰
    if [ -f "$key_file" ]; then
        read -p "⚠️  用戶已有 SSH Key，是否覆蓋? (y/N): " overwrite
        if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
            echo "取消操作"
            return 0
        fi
        
        # 備份現有密鑰
        local backup_dir="$JUMP_KEY_DIR/backups/${target_user}_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp "$key_file"* "$backup_dir/" 2>/dev/null || true
        echo "📦 已備份現有密鑰到: $backup_dir"
    fi
    
    # 創建 .ssh 目錄
    if ! mkdir -p "$ssh_dir" 2>/dev/null; then
        echo "⚠️  無法創建 .ssh 目錄，嘗試使用 sudo..."
        sudo mkdir -p "$ssh_dir"
        sudo chown "$target_user:$target_user" "$ssh_dir"
        sudo chmod 700 "$ssh_dir"
    else
        chown "$target_user:$target_user" "$ssh_dir" 2>/dev/null || true
        chmod 700 "$ssh_dir" 2>/dev/null || true
    fi
    
    # 生成密鑰對
    local comment="$target_user@$(hostname)-$(date +%Y%m%d)"
    
    if [ "$current_user" = "$target_user" ] || [ "$(id -u)" -eq 0 ]; then
        # 直接生成
        ssh-keygen -t "$KEY_TYPE" -f "$key_file" -N "" -C "$comment"
    else
        # 使用 sudo 生成
        sudo -u "$target_user" ssh-keygen -t "$KEY_TYPE" -f "$key_file" -N "" -C "$comment"
    fi
    
    if [ $? -eq 0 ]; then
        # 設置正確權限
        chmod 600 "$key_file" 2>/dev/null || sudo chmod 600 "$key_file"
        chmod 644 "$key_file.pub" 2>/dev/null || sudo chmod 644 "$key_file.pub"
        
        # 複製公鑰到管理目錄
        cp "$key_file.pub" "$JUMP_KEY_DIR/users/${target_user}.pub" 2>/dev/null || \
            sudo cp "$key_file.pub" "$JUMP_KEY_DIR/users/${target_user}.pub"
        
        echo "✅ 用戶 '$target_user' SSH Key 生成成功"
        echo "   私鑰: $key_file"
        echo "   公鑰: $key_file.pub"
        
        # 顯示公鑰內容
        echo ""
        echo "📋 公鑰內容:"
        cat "$key_file.pub"
        
        log_audit "USER_KEY_GENERATED" "$target_user" "Key type: $KEY_TYPE"
        
        # 更新統計
        update_key_statistics
        
    else
        echo "❌ SSH Key 生成失敗"
        log_audit "USER_KEY_GENERATION_FAILED" "$target_user" "Key type: $KEY_TYPE"
        return 1
    fi
}

# 生成跳板機主密鑰
generate_jump_master_key() {
    echo "🏢 生成跳板機主密鑰..."
    
    local key_name="jump_master_$(date +%Y%m%d_%H%M%S)"
    local key_path="$JUMP_KEY_DIR/master/$key_name"
    local comment="jumpserver@$(hostname)-$(date +%Y%m%d)"
    
    # 檢查是否已有主密鑰
    if [ -f "$JUMP_KEY_DIR/master/current" ]; then
        read -p "⚠️  已存在主密鑰，是否生成新的? (y/N): " generate_new
        if [ "$generate_new" != "y" ] && [ "$generate_new" != "Y" ]; then
            echo "取消操作"
            return 0
        fi
        
        # 備份當前主密鑰
        local backup_dir="$JUMP_KEY_DIR/backups/master_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp "$JUMP_KEY_DIR/master/current"* "$backup_dir/" 2>/dev/null || true
        echo "📦 已備份當前主密鑰"
    fi
    
    # 生成新的主密鑰
    ssh-keygen -t "$KEY_TYPE" -f "$key_path" -N "" -C "$comment"
    
    if [ $? -eq 0 ]; then
        # 設置安全權限
        chmod 600 "$key_path"
        chmod 644 "$key_path.pub"
        
        # 更新當前主密鑰符號連結
        ln -sf "$key_name" "$JUMP_KEY_DIR/master/current"
        ln -sf "$key_name.pub" "$JUMP_KEY_DIR/master/current.pub"
        
        echo "✅ 跳板機主密鑰生成成功: $key_name"
        echo "   私鑰: $key_path"
        echo "   公鑰: $key_path.pub"
        
        # 更新配置
        sed -i "s/^CURRENT_MASTER_KEY=.*/CURRENT_MASTER_KEY=\"$key_name\"/" "$KEY_CONFIG"
        sed -i "s/^MASTER_KEY_DATE=.*/MASTER_KEY_DATE=\"$(date '+%Y-%m-%d %H:%M:%S')\"/" "$KEY_CONFIG"
        sed -i "s/^MASTER_KEY_EXPIRES=.*/MASTER_KEY_EXPIRES=\"$(date -d '+$KEY_LIFETIME_DAYS days' '+%Y-%m-%d')\"/" "$KEY_CONFIG"
        
        log_audit "MASTER_KEY_GENERATED" "$(whoami)" "Key: $key_name"
        
        echo ""
        echo "📋 主密鑰公鑰內容:"
        cat "$key_path.pub"
        
    else
        echo "❌ 主密鑰生成失敗"
        log_audit "MASTER_KEY_GENERATION_FAILED" "$(whoami)" "Key: $key_name"
        return 1
    fi
}

# 分發公鑰到目標服務器
distribute_key_to_server() {
    local server_info="$1"
    
    if [ -z "$server_info" ]; then
        echo "請選擇要分發密鑰的服務器:"
        select_server_for_distribution
        return $?
    fi
    
    IFS='@' read -r server_user server_host <<< "$server_info"
    
    if [ -z "$server_user" ] || [ -z "$server_host" ]; then
        echo "❌ 服務器信息格式錯誤 (應為: user@host)"
        return 1
    fi
    
    local master_key_pub="$JUMP_KEY_DIR/master/current.pub"
    
    if [ ! -f "$master_key_pub" ]; then
        echo "❌ 找不到跳板機主密鑰公鑰"
        echo "請先生成跳板機主密鑰"
        return 1
    fi
    
    echo "🚀 分發公鑰到服務器: $server_user@$server_host"
    
    # 使用 ssh-copy-id 分發公鑰
    if ssh-copy-id -i "$master_key_pub" "$server_user@$server_host" 2>/dev/null; then
        echo "✅ 公鑰分發成功"
        
        # 驗證分發結果
        if ssh -i "$JUMP_KEY_DIR/master/current" -o ConnectTimeout=5 "$server_user@$server_host" "echo 'Key access verified'" 2>/dev/null; then
            echo "✅ 密鑰驗證成功"
            log_audit "KEY_DISTRIBUTED" "$(whoami)" "Target: $server_user@$server_host"
            
            # 記錄到服務器清單
            echo "$server_user@$server_host|$(date '+%Y-%m-%d %H:%M:%S')|$(whoami)" >> "$JUMP_KEY_DIR/servers/distributed_servers.log"
            
        else
            echo "⚠️  密鑰分發成功但驗證失敗"
            log_audit "KEY_DISTRIBUTED_VERIFICATION_FAILED" "$(whoami)" "Target: $server_user@$server_host"
        fi
        
    else
        echo "❌ 公鑰分發失敗"
        echo "可能的原因:"
        echo "  - 目標服務器無法連接"
        echo "  - 認證失敗"
        echo "  - 網路問題"
        log_audit "KEY_DISTRIBUTION_FAILED" "$(whoami)" "Target: $server_user@$server_host"
        return 1
    fi
    
    # 更新統計
    update_key_statistics
}

# 選擇服務器進行密鑰分發
select_server_for_distribution() {
    local servers_file="/etc/bastion_servers.conf"
    
    if [ ! -f "$servers_file" ] || [ ! -s "$servers_file" ]; then
        echo "❌ 找不到服務器配置文件或文件為空"
        echo "請先配置服務器列表: $servers_file"
        return 1
    fi
    
    echo "可用服務器列表:"
    echo "----------------------------------------"
    
    local counter=1
    local servers=()
    
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host _ <<< "$line"
            echo "[$counter] $server_name ($server_user@$server_host)"
            servers[$counter]="$server_user@$server_host"
            counter=$((counter+1))
        fi
    done < "$servers_file"
    
    if [ ${#servers[@]} -eq 0 ]; then
        echo "❌ 沒有可用的服務器"
        return 1
    fi
    
    echo "----------------------------------------"
    read -p "請選擇服務器編號 (或按 Enter 取消): " choice
    
    if [ -z "$choice" ]; then
        echo "取消操作"
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$counter" ]; then
        echo "❌ 無效的選擇"
        return 1
    fi
    
    local selected_server="${servers[$choice]}"
    distribute_key_to_server "$selected_server"
}

# 查看 SSH Key 狀態
view_ssh_key_status() {
    show_header
    echo "【SSH Key 狀態總覽】"
    echo ""
    
    # 跳板機主密鑰狀態
    echo "🏢 跳板機主密鑰:"
    if [ -f "$JUMP_KEY_DIR/master/current" ]; then
        local master_key=$(readlink "$JUMP_KEY_DIR/master/current")
        local key_date=$(stat -c %y "$JUMP_KEY_DIR/master/current" 2>/dev/null | cut -d' ' -f1)
        echo "  ✅ 當前主密鑰: $master_key"
        echo "  📅 生成日期: $key_date"
        
        # 計算過期時間
        local expire_date=$(date -d "$key_date + $KEY_LIFETIME_DAYS days" '+%Y-%m-%d' 2>/dev/null)
        echo "  ⏰ 過期日期: $expire_date"
        
        # 檢查是否即將過期
        local days_left=$(( ($(date -d "$expire_date" +%s) - $(date +%s)) / 86400 ))
        if [ $days_left -lt 30 ]; then
            echo "  ⚠️  警告: 密鑰將在 $days_left 天後過期"
        fi
    else
        echo "  ❌ 未找到主密鑰"
    fi
    
    echo ""
    
    # 用戶密鑰統計
    echo "👥 用戶密鑰統計:"
    local user_key_count=0
    if [ -d "$JUMP_KEY_DIR/users" ]; then
        user_key_count=$(ls -1 "$JUMP_KEY_DIR/users"/*.pub 2>/dev/null | wc -l)
    fi
    echo "  📊 已生成用戶密鑰: $user_key_count 個"
    
    # 服務器分發統計
    echo ""
    echo "🖥️  服務器分發統計:"
    local distributed_count=0
    if [ -f "$JUMP_KEY_DIR/servers/distributed_servers.log" ]; then
        distributed_count=$(wc -l < "$JUMP_KEY_DIR/servers/distributed_servers.log" 2>/dev/null || echo "0")
    fi
    echo "  📊 已分發服務器: $distributed_count 個"
    
    # 顯示最近的分發記錄
    if [ $distributed_count -gt 0 ]; then
        echo ""
        echo "📋 最近分發記錄 (最多顯示5個):"
        tail -5 "$JUMP_KEY_DIR/servers/distributed_servers.log" 2>/dev/null | while IFS='|' read -r server_info date_time operator; do
            echo "  - $server_info (操作者: $operator, 時間: $date_time)"
        done
    fi
    
    echo ""
    read -p "按 Enter 鍵繼續..." temp
}

# 批量操作：分發密鑰到所有服務器
batch_distribute_keys() {
    echo "🚀 批量分發密鑰到所有配置的服務器"
    echo ""
    
    local servers_file="/etc/bastion_servers.conf"
    
    if [ ! -f "$servers_file" ] || [ ! -s "$servers_file" ]; then
        echo "❌ 找不到服務器配置文件或文件為空"
        return 1
    fi
    
    # 檢查主密鑰
    if [ ! -f "$JUMP_KEY_DIR/master/current.pub" ]; then
        echo "❌ 找不到跳板機主密鑰"
        echo "請先生成跳板機主密鑰"
        return 1
    fi
    
    # 統計服務器數量
    local total_servers=$(grep -c '^[^#]' "$servers_file" 2>/dev/null || echo "0")
    
    if [ $total_servers -eq 0 ]; then
        echo "❌ 沒有配置任何服務器"
        return 1
    fi
    
    echo "發現 $total_servers 個服務器"
    read -p "確定要批量分發密鑰嗎? (y/N): " confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消批量分發"
        return 0
    fi
    
    echo ""
    echo "開始批量分發..."
    
    local success_count=0
    local fail_count=0
    local counter=1
    
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host _ <<< "$line"
            
            echo "[$counter/$total_servers] 處理服務器: $server_name ($server_user@$server_host)"
            
            if distribute_key_to_server "$server_user@$server_host" >/dev/null 2>&1; then
                echo "  ✅ 成功"
                success_count=$((success_count + 1))
            else
                echo "  ❌ 失敗"
                fail_count=$((fail_count + 1))
            fi
            
            counter=$((counter + 1))
        fi
    done < "$servers_file"
    
    echo ""
    echo "📊 批量分發結果:"
    echo "  ✅ 成功: $success_count"
    echo "  ❌ 失敗: $fail_count"
    echo "  📊 總計: $total_servers"
    
    log_audit "BATCH_DISTRIBUTION" "$(whoami)" "Success: $success_count, Failed: $fail_count"
}

# 更新密鑰統計信息
update_key_statistics() {
    local user_key_count=0
    local distributed_count=0
    
    if [ -d "$JUMP_KEY_DIR/users" ]; then
        user_key_count=$(ls -1 "$JUMP_KEY_DIR/users"/*.pub 2>/dev/null | wc -l)
    fi
    
    if [ -f "$JUMP_KEY_DIR/servers/distributed_servers.log" ]; then
        distributed_count=$(wc -l < "$JUMP_KEY_DIR/servers/distributed_servers.log" 2>/dev/null || echo "0")
    fi
    
    # 更新配置文件中的統計
    sed -i "s/^TOTAL_USER_KEYS=.*/TOTAL_USER_KEYS=$user_key_count/" "$KEY_CONFIG" 2>/dev/null || true
    sed -i "s/^TOTAL_DISTRIBUTED_KEYS=.*/TOTAL_DISTRIBUTED_KEYS=$distributed_count/" "$KEY_CONFIG" 2>/dev/null || true
}

# 主選單
main_menu() {
    while true; do
        show_header
        echo "SSH Key 管理選項:"
        echo ""
        echo "1. 🔑 為用戶生成 SSH Key"
        echo "2. 🏢 生成跳板機主密鑰"
        echo "3. 🚀 分發密鑰到服務器"
        echo "4. 📦 批量分發密鑰"
        echo "5. 📊 查看 SSH Key 狀態"
        echo "6. 🔧 初始化管理目錄"
        echo "7. 🚪 退出"
        echo ""
        
        read -p "請選擇操作 (1-7): " choice
        
        case $choice in
            1)
                if check_permissions "generate_user"; then
                    generate_user_ssh_key
                    read -p "按 Enter 鍵繼續..." temp
                fi
                ;;
            2)
                if check_permissions "distribute"; then
                    generate_jump_master_key
                    read -p "按 Enter 鍵繼續..." temp
                fi
                ;;
            3)
                if check_permissions "distribute"; then
                    select_server_for_distribution
                    read -p "按 Enter 鍵繼續..." temp
                fi
                ;;
            4)
                if check_permissions "distribute"; then
                    batch_distribute_keys
                    read -p "按 Enter 鍵繼續..." temp
                fi
                ;;
            5)
                if check_permissions "view_keys"; then
                    view_ssh_key_status
                fi
                ;;
            6)
                if check_permissions "distribute"; then
                    initialize_key_directories
                    read -p "按 Enter 鍵繼續..." temp
                fi
                ;;
            7)
                echo "👋 再見!"
                log_audit "SSH_KEY_MANAGER_EXIT" "$(whoami)" "Normal exit"
                exit 0
                ;;
            *)
                echo "❌ 無效選擇，請重新輸入"
                sleep 1
                ;;
        esac
    done
}

# 主程序入口
main() {
    # 檢查基本依賴
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "❌ 錯誤: 未找到 ssh-keygen 命令"
        echo "請安裝 openssh-client: sudo apt-get install openssh-client"
        exit 1
    fi
    
    # 創建審計日誌目錄
    local log_dir=$(dirname "$AUDIT_LOG")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || sudo mkdir -p "$log_dir" 2>/dev/null || true
    fi
    
    # 記錄啟動
    log_audit "SSH_KEY_MANAGER_START" "$(whoami)" "Session started"
    
    # 啟動主選單
    main_menu
}

# 執行主程序
main "$@"