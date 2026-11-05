#!/bin/bash
# 安全增強版用戶管理腳本
# 功能：建立用戶、配置SSH Key、設置權限、整合跳板機

# 配置參數
JUMP_GROUP="jump_users"
SSH_KEY_MANAGER="/usr/local/bin/ssh_key_manager.sh"
AUDIT_LOG="/var/log/jump_sessions/user_management.log"
USER_POLICY_FILE="/etc/jump_server/user_policy.conf"

# 用戶角色定義
declare -A USER_ROLES=(
    ["admin"]="管理員 - 完全權限"
    ["devops"]="DevOps - 服務器管理權限"
    ["developer"]="開發者 - 基本連接權限"
    ["readonly"]="只讀 - 查看權限"
)

# 顯示標題
show_header() {
    clear
    echo "======================================="
    echo "       安全用戶管理工具 v2.0          "
    echo "    (整合 SSH Key 和權限管理)        "
    echo "======================================="
    echo ""
}

# 審計日誌
log_audit() {
    local event_type="$1"
    local target_user="$2"
    local details="$3"
    local operator=$(whoami)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$event_type] Operator: $operator, Target: $target_user, Details: $details" >> "$AUDIT_LOG"
    logger -t "secure_useradd" "[$event_type] Operator: $operator, Target: $target_user, Details: $details"
}

# 檢查執行權限
check_permissions() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 此腳本需要 root 權限運行"
        echo "請使用: sudo $0"
        exit 1
    fi
}

# 初始化系統環境
initialize_system() {
    echo "🔧 初始化跳板機用戶管理環境..."
    
    # 創建跳板機群組
    if ! getent group "$JUMP_GROUP" > /dev/null 2>&1; then
        groupadd "$JUMP_GROUP"
        echo "✅ 創建跳板機群組: $JUMP_GROUP"
        log_audit "GROUP_CREATED" "$JUMP_GROUP" "Jump server group created"
    else
        echo "✅ 跳板機群組已存在: $JUMP_GROUP"
    fi
    
    # 創建必要目錄
    local dirs=(
        "/etc/jump_server"
        "/var/log/jump_sessions"
        "/etc/ssh/jump_keys"
    )
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            chmod 750 "$dir"
            chown root:$JUMP_GROUP "$dir"
            echo "✅ 創建目錄: $dir"
        fi
    done
    
    # 創建用戶策略文件
    create_user_policy_file
    
    echo "✅ 系統環境初始化完成"
}

# 創建用戶策略配置文件
create_user_policy_file() {
    if [ ! -f "$USER_POLICY_FILE" ]; then
        cat > "$USER_POLICY_FILE" << 'EOF'
# 跳板機用戶策略配置

# 默認設置
DEFAULT_SHELL="/bin/bash"
DEFAULT_HOME_PERMISSIONS="750"
SSH_KEY_REQUIRED="true"
PASSWORD_EXPIRY_DAYS="90"

# 角色權限映射
declare -A ROLE_PERMISSIONS=(
    ["admin"]="sudo,jump_users,adm"
    ["devops"]="jump_users,docker,systemd-journal"
    ["developer"]="jump_users"
    ["readonly"]="jump_users"
)

# 安全策略
FORCE_SSH_KEY="true"
DISABLE_PASSWORD_LOGIN="false"
REQUIRE_STRONG_PASSWORD="true"
AUTO_GENERATE_SSH_KEY="true"
EOF
        
        chmod 640 "$USER_POLICY_FILE"
        chown root:$JUMP_GROUP "$USER_POLICY_FILE"
        echo "✅ 用戶策略文件已創建: $USER_POLICY_FILE"
    fi
}

# 生成安全密碼
generate_secure_password() {
    local length=${1:-16}
    
    # 檢查是否有 pwgen
    if command -v pwgen >/dev/null 2>&1; then
        pwgen -s "$length" 1
    else
        # 備用方案：使用 openssl
        openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
    fi
}

# 驗證密碼強度
validate_password_strength() {
    local password="$1"
    local min_length=8
    
    # 檢查長度
    if [ ${#password} -lt $min_length ]; then
        echo "❌ 密碼長度至少需要 $min_length 個字符"
        return 1
    fi
    
    # 檢查複雜度
    local has_upper=$(echo "$password" | grep -q '[A-Z]' && echo "1" || echo "0")
    local has_lower=$(echo "$password" | grep -q '[a-z]' && echo "1" || echo "0")
    local has_digit=$(echo "$password" | grep -q '[0-9]' && echo "1" || echo "0")
    local has_special=$(echo "$password" | grep -q '[!@#$%^&*()_+\-=\[\]{}|;:,.<>?]' && echo "1" || echo "0")
    
    local complexity_score=$((has_upper + has_lower + has_digit + has_special))
    
    if [ $complexity_score -lt 3 ]; then
        echo "❌ 密碼需要包含至少3種類型的字符："
        echo "   - 大寫字母 (A-Z)"
        echo "   - 小寫字母 (a-z)"
        echo "   - 數字 (0-9)"
        echo "   - 特殊字符 (!@#$%^&*等)"
        return 1
    fi
    
    echo "✅ 密碼強度符合要求"
    return 0
}

# 選擇用戶角色
select_user_role() {
    echo "請選擇用戶角色："
    echo ""
    
    local counter=1
    local roles=()
    
    for role in "${!USER_ROLES[@]}"; do
        echo "[$counter] $role - ${USER_ROLES[$role]}"
        roles[$counter]="$role"
        counter=$((counter+1))
    done
    
    echo ""
    read -p "請選擇角色 (1-$((counter-1))): " role_choice
    
    if ! [[ "$role_choice" =~ ^[0-9]+$ ]] || [ "$role_choice" -lt 1 ] || [ "$role_choice" -ge "$counter" ]; then
        echo "❌ 無效選擇"
        return 1
    fi
    
    echo "${roles[$role_choice]}"
    return 0
}

# 配置用戶權限
configure_user_permissions() {
    local username="$1"
    local role="$2"
    
    echo "🔐 配置用戶權限: $username ($role)"
    
    # 載入策略配置
    source "$USER_POLICY_FILE" 2>/dev/null || true
    
    # 基本權限：加入跳板機群組
    usermod -aG "$JUMP_GROUP" "$username"
    echo "✅ 加入跳板機群組: $JUMP_GROUP"
    
    # 根據角色設置額外權限
    case "$role" in
        "admin")
            usermod -aG sudo "$username"
            usermod -aG adm "$username"
            echo "✅ 授予管理員權限"
            ;;
        "devops")
            # DevOps 權限
            if getent group docker > /dev/null 2>&1; then
                usermod -aG docker "$username"
                echo "✅ 加入 docker 群組"
            fi
            if getent group systemd-journal > /dev/null 2>&1; then
                usermod -aG systemd-journal "$username"
                echo "✅ 加入 systemd-journal 群組"
            fi
            ;;
        "developer")
            echo "✅ 設置開發者基本權限"
            ;;
        "readonly")
            echo "✅ 設置只讀權限"
            ;;
    esac
    
    # 記錄權限配置
    log_audit "PERMISSIONS_CONFIGURED" "$username" "Role: $role"
}

# 配置 SSH Key
configure_ssh_key() {
    local username="$1"
    local auto_generate="$2"
    
    echo "🔑 配置 SSH Key: $username"
    
    local user_home="/home/$username"
    local ssh_dir="$user_home/.ssh"
    
    # 創建 .ssh 目錄
    mkdir -p "$ssh_dir"
    chown "$username:$username" "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    if [ "$auto_generate" = "true" ] || [ "$auto_generate" = "y" ] || [ "$auto_generate" = "Y" ]; then
        # 自動生成 SSH Key
        echo "🔧 自動生成 SSH Key..."
        
        local key_file="$ssh_dir/id_ed25519"
        local comment="$username@$(hostname)-$(date +%Y%m%d)"
        
        # 生成密鑰對
        sudo -u "$username" ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$comment"
        
        if [ $? -eq 0 ]; then
            echo "✅ SSH Key 生成成功"
            echo "   私鑰: $key_file"
            echo "   公鑰: $key_file.pub"
            
            # 顯示公鑰供用戶保存
            echo ""
            echo "📋 用戶公鑰 (請保存此內容):"
            echo "┌$(printf '─%.0s' {1..60})┐"
            cat "$key_file.pub" | while read line; do
                echo "│ $line"
            done
            echo "└$(printf '─%.0s' {1..60})┘"
            
            # 複製到管理目錄
            if [ -d "/etc/ssh/jump_keys/users" ]; then
                cp "$key_file.pub" "/etc/ssh/jump_keys/users/${username}.pub"
                echo "✅ 公鑰已備份到管理目錄"
            fi
            
            log_audit "SSH_KEY_GENERATED" "$username" "Auto-generated ED25519 key"
            
        else
            echo "❌ SSH Key 生成失敗"
            log_audit "SSH_KEY_GENERATION_FAILED" "$username" "Auto-generation failed"
        fi
        
    else
        # 手動配置說明
        echo "📋 SSH Key 手動配置說明:"
        echo ""
        echo "1. 用戶可以使用以下命令生成 SSH Key:"
        echo "   ssh-keygen -t ed25519 -C \"$username@$(hostname)\""
        echo ""
        echo "2. 或者用戶可以上傳現有的公鑰到:"
        echo "   $ssh_dir/authorized_keys"
        echo ""
        echo "3. 管理員可以稍後使用 SSH Key 管理工具進行配置"
    fi
}

# 配置安全設置
configure_security_settings() {
    local username="$1"
    
    echo "🛡️ 配置安全設置: $username"
    
    # 設置密碼過期
    chage -M 90 "$username"
    echo "✅ 設置密碼90天過期"
    
    # 設置 home 目錄權限
    chmod 750 "/home/$username"
    echo "✅ 設置 home 目錄權限"
    
    # 創建用戶配置文件
    local user_config="/home/$username/.jump_server_config"
    cat > "$user_config" << EOF
# 跳板機用戶配置
USERNAME="$username"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
ROLE="$role"
SSH_KEY_CONFIGURED="$auto_generate_key"
LAST_LOGIN=""
LOGIN_COUNT=0
EOF
    
    chown "$username:$username" "$user_config"
    chmod 600 "$user_config"
    
    log_audit "SECURITY_CONFIGURED" "$username" "Security settings applied"
}

# 創建用戶
create_new_user() {
    show_header
    echo "【創建新用戶】"
    echo ""
    
    # 輸入用戶信息
    read -p "請輸入新用戶名稱: " new_user
    
    if [ -z "$new_user" ]; then
        echo "❌ 用戶名不能為空"
        return 1
    fi
    
    # 檢查用戶是否已存在
    if id "$new_user" &>/dev/null; then
        echo "❌ 用戶 '$new_user' 已經存在"
        return 1
    fi
    
    # 選擇用戶角色
    local role
    role=$(select_user_role)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    echo ""
    echo "👤 用戶信息確認:"
    echo "   用戶名: $new_user"
    echo "   角色: $role - ${USER_ROLES[$role]}"
    echo ""
    
    read -p "確認創建此用戶? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消創建用戶"
        return 0
    fi
    
    echo ""
    echo "🚀 開始創建用戶..."
    
    # 密碼配置
    local password_method
    echo "密碼設置選項:"
    echo "1. 自動生成安全密碼"
    echo "2. 手動輸入密碼"
    echo "3. 禁用密碼 (僅SSH Key)"
    
    read -p "請選擇 (1-3): " password_method
    
    local password=""
    case "$password_method" in
        1)
            password=$(generate_secure_password 16)
            echo "✅ 自動生成密碼: $password"
            ;;
        2)
            while true; do
                read -s -p "請輸入密碼: " password
                echo ""
                read -s -p "請再次輸入密碼確認: " password_confirm
                echo ""
                
                if [ "$password" != "$password_confirm" ]; then
                    echo "❌ 兩次輸入的密碼不一致，請重新輸入"
                    continue
                fi
                
                if validate_password_strength "$password"; then
                    break
                fi
            done
            ;;
        3)
            password="*"  # 禁用密碼登錄
            echo "⚠️  密碼將被禁用，用戶只能使用 SSH Key 登錄"
            ;;
        *)
            echo "❌ 無效選擇"
            return 1
            ;;
    esac
    
    # SSH Key 配置
    local auto_generate_key="false"
    read -p "是否自動生成 SSH Key? (Y/n): " auto_key
    if [ "$auto_key" != "n" ] && [ "$auto_key" != "N" ]; then
        auto_generate_key="true"
    fi
    
    echo ""
    echo "📋 創建用戶配置總結:"
    echo "   用戶名: $new_user"
    echo "   角色: $role"
    echo "   密碼: $([ "$password" = "*" ] && echo "禁用" || echo "已設置")"
    echo "   SSH Key: $([ "$auto_generate_key" = "true" ] && echo "自動生成" || echo "手動配置")"
    echo ""
    
    read -p "最終確認創建? (y/N): " final_confirm
    if [ "$final_confirm" != "y" ] && [ "$final_confirm" != "Y" ]; then
        echo "取消創建用戶"
        return 0
    fi
    
    # 開始創建用戶
    echo ""
    echo "🔧 正在創建用戶..."
    
    # 1. 創建系統用戶
    useradd -m -s /bin/bash "$new_user"
    if [ $? -ne 0 ]; then
        echo "❌ 用戶創建失敗"
        log_audit "USER_CREATION_FAILED" "$new_user" "System useradd failed"
        return 1
    fi
    
    echo "✅ 系統用戶創建成功"
    
    # 2. 設置密碼
    if [ "$password" != "*" ]; then
        echo "$new_user:$password" | chpasswd
        echo "✅ 密碼設置成功"
    else
        passwd -l "$new_user"  # 鎖定密碼
        echo "✅ 密碼已禁用"
    fi
    
    # 3. 配置權限
    configure_user_permissions "$new_user" "$role"
    
    # 4. 配置 SSH Key
    configure_ssh_key "$new_user" "$auto_generate_key"
    
    # 5. 配置安全設置
    configure_security_settings "$new_user"
    
    echo ""
    echo "🎉 用戶創建完成!"
    echo ""
    echo "📋 用戶信息總結:"
    echo "   用戶名: $new_user"
    echo "   角色: $role"
    echo "   Home目錄: /home/$new_user"
    if [ "$password" != "*" ]; then
        echo "   登錄密碼: $password"
    fi
    echo "   群組成員: $(groups "$new_user")"
    echo ""
    
    if [ "$auto_generate_key" = "true" ]; then
        echo "🔑 SSH Key 已自動生成，公鑰內容已顯示在上方"
        echo "   請將公鑰內容保存，並配置到客戶端"
    fi
    
    echo ""
    echo "📝 後續操作建議:"
    echo "1. 用戶首次登錄後應更改密碼"
    echo "2. 配置 SSH Key 到目標服務器"
    echo "3. 測試跳板機連接功能"
    
    log_audit "USER_CREATED" "$new_user" "Role: $role, SSH_Key: $auto_generate_key"
    
    echo ""
    read -p "按 Enter 鍵繼續..." temp
}

# 查看用戶狀態
view_user_status() {
    show_header
    echo "【用戶狀態查看】"
    echo ""
    
    # 顯示跳板機群組成員
    echo "👥 跳板機用戶列表 ($JUMP_GROUP 群組):"
    echo "----------------------------------------"
    
    if getent group "$JUMP_GROUP" > /dev/null 2>&1; then
        local jump_users=$(getent group "$JUMP_GROUP" | cut -d: -f4)
        
        if [ -n "$jump_users" ]; then
            IFS=',' read -ra users <<< "$jump_users"
            
            printf "%-15s %-20s %-15s %s\n" "用戶名" "真實姓名" "最後登錄" "SSH Key"
            echo "----------------------------------------"
            
            for user in "${users[@]}"; do
                if id "$user" &>/dev/null; then
                    local real_name=$(getent passwd "$user" | cut -d: -f5 | cut -d, -f1)
                    local last_login=$(last -1 "$user" 2>/dev/null | head -1 | awk '{print $3, $4, $5, $6}' | tr -d '\n')
                    local has_ssh_key="❌"
                    
                    if [ -f "/home/$user/.ssh/id_ed25519.pub" ] || [ -f "/home/$user/.ssh/id_rsa.pub" ]; then
                        has_ssh_key="✅"
                    fi
                    
                    printf "%-15s %-20s %-15s %s\n" "$user" "${real_name:-"未設置"}" "${last_login:-"從未登錄"}" "$has_ssh_key"
                fi
            done
        else
            echo "目前沒有跳板機用戶"
        fi
    else
        echo "⚠️  跳板機群組不存在"
    fi
    
    echo ""
    echo "📊 統計信息:"
    local total_users=$(getent group "$JUMP_GROUP" | cut -d: -f4 | tr ',' '\n' | wc -l)
    echo "   總用戶數: $total_users"
    
    local active_sessions=$(who | wc -l)
    echo "   當前活動會話: $active_sessions"
    
    echo ""
    read -p "按 Enter 鍵繼續..." temp
}

# 刪除用戶
remove_user() {
    show_header
    echo "【刪除用戶】"
    echo ""
    
    # 顯示可刪除的用戶
    echo "可刪除的跳板機用戶:"
    
    if getent group "$JUMP_GROUP" > /dev/null 2>&1; then
        local jump_users=$(getent group "$JUMP_GROUP" | cut -d: -f4)
        
        if [ -n "$jump_users" ]; then
            IFS=',' read -ra users <<< "$jump_users"
            
            local counter=1
            local user_list=()
            
            for user in "${users[@]}"; do
                if id "$user" &>/dev/null && [ "$user" != "$(whoami)" ]; then
                    echo "[$counter] $user"
                    user_list[$counter]="$user"
                    counter=$((counter+1))
                fi
            done
            
            if [ ${#user_list[@]} -eq 0 ]; then
                echo "沒有可刪除的用戶"
                read -p "按 Enter 鍵返回..." temp
                return 0
            fi
            
            echo ""
            read -p "請選擇要刪除的用戶編號 (或按 Enter 取消): " choice
            
            if [ -z "$choice" ]; then
                echo "取消刪除操作"
                return 0
            fi
            
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$counter" ]; then
                echo "❌ 無效選擇"
                read -p "按 Enter 鍵繼續..." temp
                return 1
            fi
            
            local target_user="${user_list[$choice]}"
            
            echo ""
            echo "⚠️  警告：即將刪除用戶 '$target_user'"
            echo "此操作將會："
            echo "1. 刪除用戶帳號"
            echo "2. 刪除 home 目錄"
            echo "3. 移除所有群組成員身份"
            echo "4. 清理 SSH Key"
            echo ""
            
            read -p "確定要刪除用戶 '$target_user' 嗎? (y/N): " confirm
            
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo ""
                echo "🗑️  正在刪除用戶..."
                
                # 終止用戶所有進程
                pkill -u "$target_user" 2>/dev/null || true
                sleep 2
                
                # 備份用戶數據
                local backup_dir="/var/backups/deleted_users/${target_user}_$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$backup_dir"
                
                if [ -d "/home/$target_user" ]; then
                    cp -r "/home/$target_user" "$backup_dir/" 2>/dev/null || true
                    echo "✅ 用戶數據已備份到: $backup_dir"
                fi
                
                # 清理 SSH Key
                if [ -f "/etc/ssh/jump_keys/users/${target_user}.pub" ]; then
                    mv "/etc/ssh/jump_keys/users/${target_user}.pub" "$backup_dir/" 2>/dev/null || true
                    echo "✅ SSH Key 已備份"
                fi
                
                # 刪除用戶
                userdel -r "$target_user" 2>/dev/null || {
                    echo "⚠️  無法完全刪除，嘗試強制刪除..."
                    userdel -f "$target_user" 2>/dev/null || true
                }
                
                if ! id "$target_user" &>/dev/null; then
                    echo "✅ 用戶 '$target_user' 已成功刪除"
                    log_audit "USER_DELETED" "$target_user" "User and data backed up to $backup_dir"
                else
                    echo "❌ 用戶刪除失敗"
                    log_audit "USER_DELETION_FAILED" "$target_user" "Deletion failed"
                fi
                
            else
                echo "取消刪除操作"
            fi
            
        else
            echo "沒有跳板機用戶"
        fi
    else
        echo "⚠️  跳板機群組不存在"
    fi
    
    echo ""
    read -p "按 Enter 鍵繼續..." temp
}

# 主選單
main_menu() {
    while true; do
        show_header
        echo "用戶管理選項:"
        echo ""
        echo "1. 👤 創建新用戶"
        echo "2. 👥 查看用戶狀態"
        echo "3. 🗑️  刪除用戶"
        echo "4. 🔧 初始化系統環境"
        echo "5. 🚪 退出"
        echo ""
        
        read -p "請選擇操作 (1-5): " choice
        
        case $choice in
            1)
                create_new_user
                ;;
            2)
                view_user_status
                ;;
            3)
                remove_user
                ;;
            4)
                initialize_system
                read -p "按 Enter 鍵繼續..." temp
                ;;
            5)
                echo "👋 再見!"
                log_audit "SECURE_USERADD_EXIT" "$(whoami)" "Normal exit"
                exit 0
                ;;
            *)
                echo "❌ 無效選擇，請重新輸入"
                sleep 1
                ;;
        esac
    done
}

# 主程序
main() {
    # 檢查權限
    check_permissions
    
    # 創建審計日誌目錄
    local log_dir=$(dirname "$AUDIT_LOG")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 750 "$log_dir"
        chown root:$JUMP_GROUP "$log_dir" 2>/dev/null || true
    fi
    
    # 記錄啟動
    log_audit "SECURE_USERADD_START" "$(whoami)" "Session started"
    
    # 檢查依賴
    local missing_deps=()
    for cmd in pwgen openssl ssh-keygen; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "⚠️  警告: 缺少依賴工具: ${missing_deps[*]}"
        echo "建議安裝: sudo apt-get install pwgen openssl openssh-client"
        echo ""
    fi
    
    # 啟動主選單
    main_menu
}

# 執行主程序
main "$@"