#!/bin/bash
# 跳板機服務器連接腳本 - 安全強化版
# 修復原版本的安全漏洞，實現基於角色的權限控制

# 安全配置
SHARED_SERVERS_FILE="/etc/bastion_servers.conf"
PERMISSIONS_FILE="/etc/jump_server/permissions.conf"
AUDIT_LOG="/var/log/jump_sessions/server_access.log"
JUMP_GROUP="jump_users"

# 顯示標題
show_header() {
    clear
    echo "======================================="
    echo "      跳板機服務器連接系統 v2.0       "
    echo "            (安全強化版)              "
    echo "======================================="
    echo ""
}

# 記錄審計日誌
log_audit() {
    local action="$1"
    local details="$2"
    local username=$(whoami)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] User: $username, Action: $action, Details: $details" >> "$AUDIT_LOG"
}

# 檢查用戶權限
check_user_permissions() {
    local username=$(whoami)
    local action="$1"
    
    # 檢查用戶是否在 jump_users 群組中
    if ! groups "$username" | grep -q "$JUMP_GROUP"; then
        echo "❌ 錯誤: 用戶 $username 沒有跳板機訪問權限"
        echo "請聯繫系統管理員將您加入 $JUMP_GROUP 群組"
        log_audit "ACCESS_DENIED" "User not in $JUMP_GROUP group"
        return 1
    fi
    
    # 載入權限配置
    if [ -f "$PERMISSIONS_FILE" ]; then
        source "$PERMISSIONS_FILE"
        
        # 檢查具體權限
        case "$action" in
            "connect")
                # 所有 jump_users 都可以連接
                return 0
                ;;
            "add"|"modify"|"delete")
                # 只有 admin 和 power_users 可以管理服務器
                if [[ " ${admin_users} ${power_users} " =~ " ${username} " ]]; then
                    return 0
                else
                    echo "❌ 錯誤: 用戶 $username 沒有服務器管理權限"
                    log_audit "PERMISSION_DENIED" "Action: $action"
                    return 1
                fi
                ;;
            *)
                return 0
                ;;
        esac
    fi
    
    return 0
}

# 確保配置文件存在並有正確權限
ensure_secure_config() {
    # 檢查跳板機群組是否存在
    if ! getent group "$JUMP_GROUP" > /dev/null 2>&1; then
        echo "⚠️  警告: 跳板機群組 '$JUMP_GROUP' 不存在"
        echo "建議管理員執行: sudo groupadd $JUMP_GROUP"
        echo "並將用戶加入群組: sudo usermod -aG $JUMP_GROUP <username>"
    fi
    
    # 創建配置文件（如果不存在）
    if [ ! -f "$SHARED_SERVERS_FILE" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            # Root 用戶直接創建
            touch "$SHARED_SERVERS_FILE"
            chown root:$JUMP_GROUP "$SHARED_SERVERS_FILE"
            chmod 660 "$SHARED_SERVERS_FILE"  # 修復: 從 666 改為 660
            echo "✅ 已創建服務器配置文件: $SHARED_SERVERS_FILE"
        else
            echo "❌ 錯誤: 配置文件 $SHARED_SERVERS_FILE 不存在"
            echo "請聯繫系統管理員創建此文件並設置權限:"
            echo "  sudo touch $SHARED_SERVERS_FILE"
            echo "  sudo chown root:$JUMP_GROUP $SHARED_SERVERS_FILE"
            echo "  sudo chmod 660 $SHARED_SERVERS_FILE"
            return 1
        fi
    fi
    
    # 檢查文件權限
    local file_perms=$(stat -c %a "$SHARED_SERVERS_FILE" 2>/dev/null)
    if [ "$file_perms" != "660" ]; then
        echo "⚠️  警告: 配置文件權限不安全 (當前: $file_perms)"
        echo "建議管理員執行: sudo chmod 660 $SHARED_SERVERS_FILE"
    fi
    
    # 檢查文件所有權
    local file_owner=$(stat -c %U:%G "$SHARED_SERVERS_FILE" 2>/dev/null)
    if [ "$file_owner" != "root:$JUMP_GROUP" ]; then
        echo "⚠️  警告: 配置文件所有權不正確 (當前: $file_owner)"
        echo "建議管理員執行: sudo chown root:$JUMP_GROUP $SHARED_SERVERS_FILE"
    fi
    
    # 創建審計日誌目錄
    local log_dir=$(dirname "$AUDIT_LOG")
    if [ ! -d "$log_dir" ]; then
        sudo mkdir -p "$log_dir" 2>/dev/null || {
            echo "⚠️  警告: 無法創建審計日誌目錄 $log_dir"
        }
    fi
    
    return 0
}

# 創建權限配置文件
create_permissions_config() {
    if [ ! -f "$PERMISSIONS_FILE" ]; then
        echo "正在創建權限配置文件..."
        sudo mkdir -p "$(dirname "$PERMISSIONS_FILE")" 2>/dev/null
        
        cat > /tmp/permissions.conf << 'EOF'
# 跳板機權限配置
# 管理員 (完全權限)
admin_users="root admin"

# 高級用戶 (服務器管理權限)
power_users="devops sre ops"

# 普通用戶 (連接權限)
regular_users="dev developer test tester"

# 只讀用戶 (查看權限)
readonly_users="monitor audit readonly"

# SSH Key 管理權限
key_admin_users="root admin"
key_power_users="devops sre"
EOF
        
        if sudo mv /tmp/permissions.conf "$PERMISSIONS_FILE" 2>/dev/null; then
            sudo chmod 640 "$PERMISSIONS_FILE"
            sudo chown root:$JUMP_GROUP "$PERMISSIONS_FILE"
            echo "✅ 權限配置文件已創建: $PERMISSIONS_FILE"
        else
            echo "⚠️  警告: 無法創建權限配置文件"
        fi
    fi
}

# 安全的服務器連接
secure_connect_to_server() {
    show_header
    echo "【安全連接到服務器】"
    echo ""
    
    # 檢查權限
    if ! check_user_permissions "connect"; then
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    # 確保配置文件安全
    if ! ensure_secure_config; then
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    # 檢查文件是否可讀
    if [ ! -r "$SHARED_SERVERS_FILE" ]; then
        echo "❌ 錯誤: 無法讀取服務器配置文件"
        log_audit "CONFIG_READ_ERROR" "Cannot read $SHARED_SERVERS_FILE"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    # 檢查是否有服務器配置
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "📝 尚未配置任何服務器"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    # 顯示服務器列表
    echo "可用服務器列表："
    echo "----------------------------------------"
    printf "%-5s %-20s %-15s %-20s %s\n" "編號" "服務器名稱" "用戶名" "主機地址" "添加者"
    echo "----------------------------------------"
    
    local counter=1
    local servers=()
    
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            printf "%-5s %-20s %-15s %-20s %s\n" "$counter" "$server_name" "$server_user" "$server_host" "$added_by"
            servers[$counter]="$server_user@$server_host"
            counter=$((counter+1))
        fi
    done < "$SHARED_SERVERS_FILE"
    
    echo "----------------------------------------"
    echo ""
    
    # 用戶選擇
    read -p "請選擇要連接的服務器編號 (或按Enter返回): " choice
    
    if [ -z "$choice" ]; then
        return
    fi
    
    # 驗證選擇
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$counter" ]; then
        echo "❌ 無效的選擇"
        log_audit "INVALID_CHOICE" "Choice: $choice"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    local selected_server="${servers[$choice]}"
    echo ""
    echo "🔗 正在連接到: $selected_server"
    log_audit "SERVER_CONNECT_ATTEMPT" "Target: $selected_server"
    
    # 嘗試連接 (使用SSH Key優先，密碼作為備選)
    if [ -f ~/.ssh/id_ed25519 ]; then
        echo "🔑 使用SSH Key認證..."
        ssh -i ~/.ssh/id_ed25519 "$selected_server"
    elif [ -f ~/.ssh/id_rsa ]; then
        echo "🔑 使用SSH Key認證..."
        ssh -i ~/.ssh/id_rsa "$selected_server"
    else
        echo "🔐 使用密碼認證..."
        ssh "$selected_server"
    fi
    
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_audit "SERVER_CONNECT_SUCCESS" "Target: $selected_server"
    else
        log_audit "SERVER_CONNECT_FAILED" "Target: $selected_server, Exit_code: $exit_code"
    fi
    
    echo ""
    echo "連接已結束"
    read -p "按Enter鍵返回主選單..." temp
}

# 安全的服務器管理
secure_manage_servers() {
    show_header
    echo "【服務器管理】"
    echo ""
    
    # 檢查管理權限
    if ! check_user_permissions "add"; then
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    echo "服務器管理選項："
    echo "1. 查看服務器列表"
    echo "2. 添加新服務器"
    echo "3. 刪除服務器"
    echo "4. 返回主選單"
    echo ""
    
    read -p "請選擇操作 (1-4): " mgmt_choice
    
    case $mgmt_choice in
        1)
            view_servers
            ;;
        2)
            add_server
            ;;
        3)
            delete_server
            ;;
        4)
            return
            ;;
        *)
            echo "❌ 無效選擇"
            read -p "按Enter鍵繼續..." temp
            ;;
    esac
}

# 查看服務器列表
view_servers() {
    echo ""
    echo "📋 當前服務器列表："
    echo "----------------------------------------"
    
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "目前沒有配置任何服務器"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    local counter=1
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by added_time <<< "$line"
            echo "[$counter] $server_name"
            echo "    用戶: $server_user"
            echo "    主機: $server_host"
            echo "    添加者: ${added_by:-未知}"
            echo "    時間: ${added_time:-未知}"
            echo ""
            counter=$((counter+1))
        fi
    done < "$SHARED_SERVERS_FILE"
    
    read -p "按Enter鍵繼續..." temp
}

# 添加新服務器
add_server() {
    echo ""
    echo "➕ 添加新服務器"
    echo ""
    
    read -p "服務器名稱: " server_name
    read -p "用戶名: " server_user
    read -p "主機地址: " server_host
    
    if [ -z "$server_name" ] || [ -z "$server_user" ] || [ -z "$server_host" ]; then
        echo "❌ 所有字段都必須填寫"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    # 檢查是否已存在
    if grep -q "^$server_name|" "$SHARED_SERVERS_FILE" 2>/dev/null; then
        echo "❌ 服務器名稱 '$server_name' 已存在"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    # 添加到配置文件
    local username=$(whoami)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local new_entry="$server_name|$server_user|$server_host|$username|$timestamp"
    
    if echo "$new_entry" >> "$SHARED_SERVERS_FILE"; then
        echo "✅ 服務器 '$server_name' 已成功添加"
        log_audit "SERVER_ADDED" "Name: $server_name, Host: $server_host"
    else
        echo "❌ 添加服務器失敗"
        log_audit "SERVER_ADD_FAILED" "Name: $server_name, Host: $server_host"
    fi
    
    read -p "按Enter鍵繼續..." temp
}

# 刪除服務器
delete_server() {
    echo ""
    echo "🗑️  刪除服務器"
    echo ""
    
    # 顯示服務器列表供選擇
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "目前沒有可刪除的服務器"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    echo "現有服務器："
    local counter=1
    local servers=()
    
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            echo "[$counter] $server_name ($server_user@$server_host)"
            servers[$counter]="$line"
            counter=$((counter+1))
        fi
    done < "$SHARED_SERVERS_FILE"
    
    echo ""
    read -p "請選擇要刪除的服務器編號 (或按Enter取消): " del_choice
    
    if [ -z "$del_choice" ]; then
        return
    fi
    
    if ! [[ "$del_choice" =~ ^[0-9]+$ ]] || [ "$del_choice" -lt 1 ] || [ "$del_choice" -ge "$counter" ]; then
        echo "❌ 無效的選擇"
        read -p "按Enter鍵繼續..." temp
        return
    fi
    
    local selected_line="${servers[$del_choice]}"
    IFS='|' read -r server_name _ _ _ _ <<< "$selected_line"
    
    read -p "確定要刪除服務器 '$server_name' 嗎? (y/N): " confirm
    
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 創建臨時文件，排除要刪除的行
        local temp_file=$(mktemp)
        grep -v "^$selected_line$" "$SHARED_SERVERS_FILE" > "$temp_file"
        
        if mv "$temp_file" "$SHARED_SERVERS_FILE"; then
            echo "✅ 服務器 '$server_name' 已刪除"
            log_audit "SERVER_DELETED" "Name: $server_name"
        else
            echo "❌ 刪除服務器失敗"
            log_audit "SERVER_DELETE_FAILED" "Name: $server_name"
            rm -f "$temp_file"
        fi
    else
        echo "取消刪除操作"
    fi
    
    read -p "按Enter鍵繼續..." temp
}

# 顯示系統狀態
show_system_status() {
    show_header
    echo "【系統狀態】"
    echo ""
    
    local username=$(whoami)
    local user_groups=$(groups "$username")
    
    echo "👤 當前用戶: $username"
    echo "👥 用戶群組: $user_groups"
    echo ""
    
    # 檢查權限狀態
    if groups "$username" | grep -q "$JUMP_GROUP"; then
        echo "✅ 跳板機訪問權限: 正常"
    else
        echo "❌ 跳板機訪問權限: 無權限"
    fi
    
    # 檢查SSH Key狀態
    if [ -f ~/.ssh/id_ed25519 ]; then
        echo "✅ SSH Key (ED25519): 已配置"
    elif [ -f ~/.ssh/id_rsa ]; then
        echo "✅ SSH Key (RSA): 已配置"
    else
        echo "⚠️  SSH Key: 未配置"
    fi
    
    # 檢查配置文件狀態
    if [ -r "$SHARED_SERVERS_FILE" ]; then
        local server_count=$(grep -c '^[^#]' "$SHARED_SERVERS_FILE" 2>/dev/null || echo "0")
        echo "📊 可用服務器數量: $server_count"
    else
        echo "❌ 服務器配置: 無法訪問"
    fi
    
    echo ""
    read -p "按Enter鍵返回主選單..." temp
}

# 主選單
main_menu() {
    while true; do
        show_header
        
        local username=$(whoami)
        echo "👋 歡迎, $username!"
        echo ""
        echo "主選單："
        echo "1. 連接到服務器"
        echo "2. 管理服務器"
        echo "3. 查看系統狀態"
        echo "4. 退出"
        echo ""
        
        read -p "請選擇操作 (1-4): " choice
        
        case $choice in
            1)
                secure_connect_to_server
                ;;
            2)
                secure_manage_servers
                ;;
            3)
                show_system_status
                ;;
            4)
                echo "👋 再見!"
                log_audit "SYSTEM_EXIT" "Normal exit"
                exit 0
                ;;
            *)
                echo "❌ 無效選擇，請重新輸入"
                sleep 1
                ;;
        esac
    done
}

# 初始化檢查
initialization() {
    # 創建權限配置
    create_permissions_config
    
    # 確保審計日誌目錄存在
    local log_dir=$(dirname "$AUDIT_LOG")
    if [ ! -d "$log_dir" ]; then
        sudo mkdir -p "$log_dir" 2>/dev/null || true
    fi
    
    # 記錄系統啟動
    log_audit "SYSTEM_START" "User session started"
}

# 主程序
main() {
    initialization
    main_menu
}

# 執行主程序
main "$@"