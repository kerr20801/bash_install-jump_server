#!/bin/bash
# 跳板機監控系統安裝腳本 v2.0
# 功能：登入/登出告警、會話記錄、閒置監控、異常斷線告警、多平台通知整合

# 確認執行權限
if [ "$(id -u)" -ne 0 ]; then
    echo "請使用 sudo 權限執行此腳本"
    exit 1
fi

# 設置基本參數
IDLE_TIMEOUT=1800  # 閒置超時時間（秒）- 30分鐘
SESSION_LOG_DIR="/var/log/jump_sessions"
CONFIG_DIR="/etc/jump_server"
SCRIPT_DIR="/usr/local/bin"

echo "===== 跳板機監控系統安裝 v2.0 ====="
echo "開始安裝..."

# 安裝必要的軟件
echo "安裝必要的軟件..."
apt-get update
apt-get install -y fail2ban curl jq ipset sysstat bc

# 創建目錄和配置文件
echo "創建目錄和配置文件..."
mkdir -p $CONFIG_DIR
mkdir -p $SESSION_LOG_DIR
chmod 750 $SESSION_LOG_DIR

# 創建告警配置文件
cat > $CONFIG_DIR/alert_config.conf << 'EOF'
# 告警平台設置
# 啟用的平台（可多選）：true/false
TELEGRAM_ENABLED=true
MATTERMOST_ENABLED=false
DISCORD_ENABLED=false

# Telegram 設置
TELEGRAM_TOKEN="YOUR_TELEGRAM_TOKEN"
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"

# Mattermost 設置
MATTERMOST_URL="YOUR_MATTERMOST_WEBHOOK_URL"

# Discord 設置
DISCORD_URL="YOUR_DISCORD_WEBHOOK_URL"

# 系統設置
IDLE_TIMEOUT=1800  # 閒置超時（秒）
SESSION_LOG_DIR="/var/log/jump_sessions"
HOSTNAME=$(hostname)
EOF

# 創建統一告警發送腳本
cat > $SCRIPT_DIR/send_alert.sh << 'EOF'
#!/bin/bash
# 統一告警發送腳本
# 用法: ./send_alert.sh "嚴重性" "標題" "訊息內容"
# 嚴重性: info, warning, critical

# 從配置文件加載設置
source /etc/jump_server/alert_config.conf

# 設置嚴重性級別和標題
SEVERITY=${1:-"info"}
TITLE=${2:-"系統通知"}
MESSAGE=${3:-"無訊息內容"}
HOSTNAME=$(hostname)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# 根據嚴重性設置表情符號
case $SEVERITY in
  "info")
    EMOJI="ℹ️"
    ;;
  "warning")
    EMOJI="⚠️"
    ;;
  "critical")
    EMOJI="🚨"
    ;;
  *)
    EMOJI="ℹ️"
    ;;
esac

# 格式化訊息
FORMATTED_MESSAGE="$EMOJI [$SEVERITY] $HOSTNAME - $TITLE\n$TIMESTAMP\n\n$MESSAGE"

# 發送到已啟用的平台
if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    -d text="<pre>$FORMATTED_MESSAGE</pre>" > /dev/null
fi

if [ "$MATTERMOST_ENABLED" = "true" ] && [ -n "$MATTERMOST_URL" ]; then
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"text\": \"$FORMATTED_MESSAGE\"}" \
    $MATTERMOST_URL > /dev/null
fi

if [ "$DISCORD_ENABLED" = "true" ] && [ -n "$DISCORD_URL" ]; then
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"$FORMATTED_MESSAGE\"}" \
    $DISCORD_URL > /dev/null
fi

# 記錄到系統日誌
logger -t "jump_alert" "[$SEVERITY] $TITLE: $MESSAGE"

exit 0
EOF
chmod +x $SCRIPT_DIR/send_alert.sh

# 創建會話記錄函數
cat > $SCRIPT_DIR/session_manager.sh << 'EOF'
#!/bin/bash
# 會話管理腳本
# 功能：記錄會話開始/結束，計算時間，發送告警

# 載入配置
source /etc/jump_server/alert_config.conf

# 獲取參數
ACTION=$1
USER=$2
PID=$3
SSH_IP=$4

# 會話日誌文件
SESSION_FILE="$SESSION_LOG_DIR/sessions.log"
USER_SESSION_FILE="$SESSION_LOG_DIR/${USER}_sessions.log"
ACTIVE_SESSION_FILE="$SESSION_LOG_DIR/active_sessions.json"

# 確保日誌文件存在
touch $SESSION_FILE
touch $USER_SESSION_FILE
touch $ACTIVE_SESSION_FILE

# 生成唯一會話ID
SESSION_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# 格式化時間
format_duration() {
    local seconds=$1
    local days=$((seconds/86400))
    local hours=$(( (seconds%86400)/3600 ))
    local minutes=$(( (seconds%3600)/60 ))
    local secs=$((seconds%60))
    
    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m ${secs}s"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${secs}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# 會話開始函數
session_start() {
    # 記錄開始時間
    START_TIME=$(date +%s)
    START_TIME_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 添加到活動會話文件
    jq --arg sid "$SESSION_ID" --arg uid "$USER" --arg pip "$SSH_IP" --arg pid "$PID" \
       --arg st "$START_TIME" --arg sth "$START_TIME_HUMAN" \
       '. += [{"id": $sid, "user": $uid, "ip": $pip, "pid": $pid, "start_time": $st, "start_time_human": $sth}]' \
       $ACTIVE_SESSION_FILE > ${ACTIVE_SESSION_FILE}.tmp || echo "[{\"id\": \"$SESSION_ID\", \"user\": \"$USER\", \"ip\": \"$SSH_IP\", \"pid\": \"$PID\", \"start_time\": \"$START_TIME\", \"start_time_human\": \"$START_TIME_HUMAN\"}]" > ${ACTIVE_SESSION_FILE}.tmp
    mv ${ACTIVE_SESSION_FILE}.tmp $ACTIVE_SESSION_FILE
    
    # 發送告警
    ALERT_MESSAGE="使用者: $USER\nIP位址: $SSH_IP\n進程ID: $PID\n會話ID: $SESSION_ID\n開始時間: $START_TIME_HUMAN"
    $SCRIPT_DIR/send_alert.sh "info" "跳板機登入" "$ALERT_MESSAGE"
    
    # 記錄到日誌
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] START|$SESSION_ID|$USER|$SSH_IP|$PID" >> $SESSION_FILE
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] START|$SESSION_ID|$USER|$SSH_IP|$PID" >> $USER_SESSION_FILE
}

# 會話結束函數
session_end() {
    # 獲取會話信息
    SESSION_INFO=$(jq --arg pid "$PID" '.[] | select(.pid == $pid)' $ACTIVE_SESSION_FILE)
    
    if [ -z "$SESSION_INFO" ]; then
        return 1
    fi
    
    # 提取會話數據
    SESSION_ID=$(echo $SESSION_INFO | jq -r '.id')
    START_TIME=$(echo $SESSION_INFO | jq -r '.start_time')
    START_TIME_HUMAN=$(echo $SESSION_INFO | jq -r '.start_time_human')
    
    # 計算持續時間
    END_TIME=$(date +%s)
    END_TIME_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")
    DURATION=$((END_TIME - START_TIME))
    DURATION_HUMAN=$(format_duration $DURATION)
    
    # 從活動會話中移除
    jq --arg pid "$PID" 'map(select(.pid != $pid))' $ACTIVE_SESSION_FILE > ${ACTIVE_SESSION_FILE}.tmp
    mv ${ACTIVE_SESSION_FILE}.tmp $ACTIVE_SESSION_FILE
    
    # 發送告警
    ALERT_MESSAGE="使用者: $USER\nIP位址: $SSH_IP\n進程ID: $PID\n會話ID: $SESSION_ID\n開始時間: $START_TIME_HUMAN\n結束時間: $END_TIME_HUMAN\n持續時間: $DURATION_HUMAN"
    $SCRIPT_DIR/send_alert.sh "info" "跳板機登出" "$ALERT_MESSAGE"
    
    # 記錄到日誌
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] END|$SESSION_ID|$USER|$SSH_IP|$PID|$DURATION|$DURATION_HUMAN" >> $SESSION_FILE
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] END|$SESSION_ID|$USER|$SSH_IP|$PID|$DURATION|$DURATION_HUMAN" >> $USER_SESSION_FILE
}

# 異常結束函數
session_abnormal_end() {
    # 獲取會話信息
    SESSION_INFO=$(jq --arg pid "$PID" '.[] | select(.pid == $pid)' $ACTIVE_SESSION_FILE)
    
    if [ -z "$SESSION_INFO" ]; then
        return 1
    fi
    
    # 提取會話數據
    SESSION_ID=$(echo $SESSION_INFO | jq -r '.id')
    START_TIME=$(echo $SESSION_INFO | jq -r '.start_time')
    START_TIME_HUMAN=$(echo $SESSION_INFO | jq -r '.start_time_human')
    
    # 計算持續時間
    END_TIME=$(date +%s)
    END_TIME_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")
    DURATION=$((END_TIME - START_TIME))
    DURATION_HUMAN=$(format_duration $DURATION)
    
    # 從活動會話中移除
    jq --arg pid "$PID" 'map(select(.pid != $pid))' $ACTIVE_SESSION_FILE > ${ACTIVE_SESSION_FILE}.tmp
    mv ${ACTIVE_SESSION_FILE}.tmp $ACTIVE_SESSION_FILE
    
    # 發送告警
    ALERT_MESSAGE="使用者: $USER\nIP位址: $SSH_IP\n進程ID: $PID\n會話ID: $SESSION_ID\n開始時間: $START_TIME_HUMAN\n異常結束時間: $END_TIME_HUMAN\n持續時間: $DURATION_HUMAN"
    $SCRIPT_DIR/send_alert.sh "warning" "跳板機異常斷線" "$ALERT_MESSAGE"
    
    # 記錄到日誌
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ABNORMAL|$SESSION_ID|$USER|$SSH_IP|$PID|$DURATION|$DURATION_HUMAN" >> $SESSION_FILE
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ABNORMAL|$SESSION_ID|$USER|$SSH_IP|$PID|$DURATION|$DURATION_HUMAN" >> $USER_SESSION_FILE
}

# 閒置超時檢查函數
check_idle_sessions() {
    # 獲取所有活動會話
    if [ ! -s "$ACTIVE_SESSION_FILE" ] || [ "$(cat $ACTIVE_SESSION_FILE)" = "[]" ]; then
        return 0
    fi
    
    # 獲取當前時間
    CURRENT_TIME=$(date +%s)
    
    # 讀取所有會話
    SESSIONS=$(jq -c '.[]' $ACTIVE_SESSION_FILE)
    
    # 處理每個會話
    echo "$SESSIONS" | while read -r session; do
        PID=$(echo $session | jq -r '.pid')
        USER=$(echo $session | jq -r '.user')
        IP=$(echo $session | jq -r '.ip')
        SESSION_ID=$(echo $session | jq -r '.id')
        START_TIME=$(echo $session | jq -r '.start_time')
        
        # 檢查進程是否存在
        if ! ps -p $PID > /dev/null; then
            # 進程不存在，標記為異常結束
            SESSION_PID=$PID SESSION_USER=$USER SESSION_IP=$IP $SCRIPT_DIR/session_manager.sh abnormal_end $USER $PID $IP
            continue
        fi
        
        # 檢查是否超過閒置時間
        if [ -x /usr/bin/w ]; then
            # 獲取最後活動時間
            IDLE_TIME=$(w -h | grep $PID | awk '{print $5}')
            
            # 處理格式 (w 命令可能輸出為 00:30 或 7days 等)
            if [[ $IDLE_TIME == *"days"* ]]; then
                # 提取天數
                DAYS=$(echo $IDLE_TIME | sed 's/days.*//')
                IDLE_SECONDS=$((DAYS * 86400))
            elif [[ $IDLE_TIME == *":"* ]]; then
                # 轉換 HH:MM 格式
                HOURS=$(echo $IDLE_TIME | cut -d: -f1)
                MINUTES=$(echo $IDLE_TIME | cut -d: -f2)
                IDLE_SECONDS=$((HOURS * 3600 + MINUTES * 60))
            else
                # 其他情況，假設為秒
                IDLE_SECONDS=0
            fi
            
            # 如果閒置時間超過閾值，斷開連線
            if [ $IDLE_SECONDS -gt $IDLE_TIMEOUT ]; then
                DURATION=$((CURRENT_TIME - START_TIME))
                DURATION_HUMAN=$(format_duration $DURATION)
                
                # 發送告警
                ALERT_MESSAGE="使用者: $USER\nIP位址: $IP\n進程ID: $PID\n會話ID: $SESSION_ID\n閒置時間: $(format_duration $IDLE_SECONDS)\n會話已持續: $DURATION_HUMAN"
                $SCRIPT_DIR/send_alert.sh "warning" "跳板機閒置超時" "$ALERT_MESSAGE"
                
                # 記錄到日誌
                echo "[$(date "+%Y-%m-%d %H:%M:%S")] TIMEOUT|$SESSION_ID|$USER|$IP|$PID|$DURATION|$DURATION_HUMAN|$IDLE_SECONDS" >> $SESSION_FILE
                echo "[$(date "+%Y-%m-%d %H:%M:%S")] TIMEOUT|$SESSION_ID|$USER|$IP|$PID|$DURATION|$DURATION_HUMAN|$IDLE_SECONDS" >> "$SESSION_LOG_DIR/${USER}_sessions.log"
                
                # 終止進程
                kill $PID
                
                # 從活動會話列表中移除
                jq --arg pid "$PID" 'map(select(.pid != $pid))' $ACTIVE_SESSION_FILE > ${ACTIVE_SESSION_FILE}.tmp
                mv ${ACTIVE_SESSION_FILE}.tmp $ACTIVE_SESSION_FILE
            fi
        fi
    done
}

# 根據傳入的動作執行對應函數
case "$ACTION" in
    "start")
        session_start
        ;;
    "end")
        session_end
        ;;
    "abnormal_end")
        session_abnormal_end
        ;;
    "check_idle")
        check_idle_sessions
        ;;
    *)
        echo "未知的操作: $ACTION"
        echo "可用操作: start, end, abnormal_end, check_idle"
        exit 1
        ;;
esac

exit 0
EOF
chmod +x $SCRIPT_DIR/session_manager.sh

# 創建登入和登出腳本
cat > $SCRIPT_DIR/login_monitor.sh << 'EOF'
#!/bin/bash
# 登入監控腳本

# 獲取用戶名和IP
USER=$PAM_USER
RHOST=$PAM_RHOST
PID=$$

# 記錄會話開始
/usr/local/bin/session_manager.sh start $USER $PID $RHOST

exit 0
EOF
chmod +x $SCRIPT_DIR/login_monitor.sh

cat > $SCRIPT_DIR/logout_monitor.sh << 'EOF'
#!/bin/bash
# 登出監控腳本

# 獲取用戶名和IP
USER=$PAM_USER
RHOST=$PAM_RHOST
PID=$$

# 記錄會話結束
/usr/local/bin/session_manager.sh end $USER $PID $RHOST

exit 0
EOF
chmod +x $SCRIPT_DIR/logout_monitor.sh

# 創建會話報告生成腳本
cat > $SCRIPT_DIR/generate_session_report.sh << 'EOF'
#!/bin/bash
# 生成會話報告

# 載入配置
source /etc/jump_server/alert_config.conf

# 設置時間範圍
DAYS=${1:-1}
START_DATE=$(date -d "$DAYS days ago" "+%Y-%m-%d")
END_DATE=$(date "+%Y-%m-%d")
HOSTNAME=$(hostname)

# 會話日誌文件
SESSION_FILE="$SESSION_LOG_DIR/sessions.log"

if [ ! -f $SESSION_FILE ]; then
    echo "找不到會話記錄文件"
    exit 1
fi

# 提取指定時間範圍的記錄
SESSION_RECORDS=$(grep -a "\[$START_DATE\|$END_DATE" $SESSION_FILE)

# 統計會話數據
TOTAL_SESSIONS=$(echo "$SESSION_RECORDS" | grep "START" | wc -l)
NORMAL_ENDS=$(echo "$SESSION_RECORDS" | grep "END" | wc -l)
ABNORMAL_ENDS=$(echo "$SESSION_RECORDS" | grep "ABNORMAL" | wc -l)
TIMEOUT_ENDS=$(echo "$SESSION_RECORDS" | grep "TIMEOUT" | wc -l)

# 獲取活躍用戶
ACTIVE_USERS=$(echo "$SESSION_RECORDS" | grep "START" | awk -F'|' '{print $3}' | sort | uniq -c | sort -nr)

# 獲取來源IP
SOURCE_IPS=$(echo "$SESSION_RECORDS" | grep "START" | awk -F'|' '{print $4}' | sort | uniq -c | sort -nr)

# 計算平均會話時間
TOTAL_DURATION=0
SESSION_COUNT=0

echo "$SESSION_RECORDS" | grep -E "END|ABNORMAL|TIMEOUT" | while IFS='|' read -r timestamp action session_id user ip pid duration duration_human; do
    TOTAL_DURATION=$((TOTAL_DURATION + duration))
    SESSION_COUNT=$((SESSION_COUNT + 1))
done

if [ $SESSION_COUNT -gt 0 ]; then
    AVG_DURATION=$((TOTAL_DURATION / SESSION_COUNT))
    AVG_DURATION_HUMAN=$(echo "$AVG_DURATION" | awk '{printf "%02d:%02d:%02d", ($1/3600), ($1/60)%60, $1%60}')
else
    AVG_DURATION_HUMAN="00:00:00"
fi

# 生成報告內容
REPORT="跳板機使用報告 ($START_DATE 至 $END_DATE)
主機名稱: $HOSTNAME

===== 會話統計 =====
總會話數: $TOTAL_SESSIONS
正常結束: $NORMAL_ENDS
異常斷線: $ABNORMAL_ENDS
閒置超時: $TIMEOUT_ENDS
平均會話時間: $AVG_DURATION_HUMAN

===== 活躍用戶 (前5名) =====
$ACTIVE_USERS

===== 來源IP (前5名) =====
$SOURCE_IPS

===== 當前活躍會話 =====
$(jq -r '.[] | "使用者: \(.user), IP: \(.ip), 開始於: \(.start_time_human)"' $SESSION_LOG_DIR/active_sessions.json 2>/dev/null || echo "無活躍會話")

===== 異常斷線 =====
$(echo "$SESSION_RECORDS" | grep "ABNORMAL" | awk -F'|' '{print "使用者: " $3 ", IP: " $4 ", 時間: " $1 ", 持續: " $7}')

===== 閒置超時 =====
$(echo "$SESSION_RECORDS" | grep "TIMEOUT" | awk -F'|' '{print "使用者: " $3 ", IP: " $4 ", 時間: " $1 ", 持續: " $7}')
"

# 發送報告
$SCRIPT_DIR/send_alert.sh "info" "跳板機使用報告 ($DAYS天)" "$REPORT"

# 保存報告
echo "$REPORT" > "$SESSION_LOG_DIR/report_$(date +%Y%m%d).txt"

exit 0
EOF
chmod +x $SCRIPT_DIR/generate_session_report.sh

# 創建告警配置管理工具
cat > $SCRIPT_DIR/config_alerts.sh << 'EOF'
#!/bin/bash
# 告警配置管理工具

CONFIG_FILE="/etc/jump_server/alert_config.conf"

# 顯示當前配置
show_config() {
    echo "===== 當前告警配置 ====="
    grep -v "^#" $CONFIG_FILE
    echo "======================="
}

# 設置值
set_value() {
    local key=$1
    local value=$2
    
    # 檢查鍵是否存在
    if grep -q "^${key}=" $CONFIG_FILE; then
        # 更新值
        sed -i "s|^${key}=.*|${key}=${value}|" $CONFIG_FILE
        echo "已更新: ${key}=${value}"
    else
        echo "錯誤: 找不到配置項 $key"
        return 1
    fi
}

# 啟用/禁用平台
toggle_platform() {
    local platform=$1
    local state=$2
    
    # 檢查平台是否有效
    if [ "$platform" != "telegram" ] && [ "$platform" != "mattermost" ] && [ "$platform" != "discord" ]; then
        echo "錯誤: 無效的平台 $platform"
        echo "可用平台: telegram, mattermost, discord"
        return 1
    fi
    
    # 檢查狀態是否有效
    if [ "$state" != "enable" ] && [ "$state" != "disable" ]; then
        echo "錯誤: 無效的狀態 $state"
        echo "可用狀態: enable, disable"
        return 1
    fi
    
    # 設置對應的值
    case $platform in
        "telegram")
            if [ "$state" = "enable" ]; then
                set_value "TELEGRAM_ENABLED" "true"
            else
                set_value "TELEGRAM_ENABLED" "false"
            fi
            ;;
        "mattermost")
            if [ "$state" = "enable" ]; then
                set_value "MATTERMOST_ENABLED" "true"
            else
                set_value "MATTERMOST_ENABLED" "false"
            fi
            ;;
        "discord")
            if [ "$state" = "enable" ]; then
                set_value "DISCORD_ENABLED" "true"
            else
                set_value "DISCORD_ENABLED" "false"
            fi
            ;;
    esac
}

# 測試告警
test_alert() {
    local severity=${1:-"info"}
    
    echo "發送測試告警 (嚴重性: $severity)..."
    /usr/local/bin/send_alert.sh "$severity" "測試告警" "這是一則測試告警訊息。\n時間: $(date)"
    
    echo "測試告警已發送"
}

# 幫助信息
show_help() {
    echo "告警配置管理工具"
    echo "用法: $0 [命令] [參數...]"
    echo ""
    echo "可用命令:"
    echo "  show                           - 顯示當前配置"
    echo "  set <鍵> <值>                  - 設置配置值"
    echo "  test [info|warning|critical]   - 發送測試告警"
    echo "  enable <平台>                  - 啟用平台 (telegram, mattermost, discord)"
    echo "  disable <平台>                 - 禁用平台 (telegram, mattermost, discord)"
    echo ""
    echo "範例:"
    echo "  $0 show"
    echo "  $0 set TELEGRAM_TOKEN 'your-token-here'"
    echo "  $0 set TELEGRAM_CHAT_ID 'your-chat-id'"
    echo "  $0 enable telegram"
    echo "  $0 disable mattermost"
    echo "  $0 test warning"
}

# 主函數
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    command=$1
    shift
    
    case $command in
        "show")
            show_config
            ;;
        "set")
            if [ $# -lt 2 ]; then
                echo "錯誤: 未提供足夠的參數"
                echo "用法: $0 set <鍵> <值>"
                exit 1
            fi
            set_value "$1" "$2"
            ;;
        "enable")
            if [ $# -lt 1 ]; then
                echo "錯誤: 未提供平台名稱"
                echo "用法: $0 enable <平台>"
                exit 1
            fi
            toggle_platform "$1" "enable"
            ;;
        "disable")
            if [ $# -lt 1 ]; then
                echo "錯誤: 未提供平台名稱"
                echo "用法: $0 disable <平台>"
                exit 1
            fi
            toggle_platform "$1" "disable"
            ;;
        "test")
            severity=${1:-"info"}
            test_alert "$severity"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            echo "錯誤: 未知命令 $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
EOF
chmod +x $SCRIPT_DIR/config_alerts.sh

# 配置PAM
echo "配置PAM..."
# 檢查並添加登入監控
grep -q "login_monitor.sh" /etc/pam.d/sshd || echo "session optional pam_exec.so seteuid /usr/local/bin/login_monitor.sh" >> /etc/pam.d/sshd
# 檢查並添加登出監控
grep -q "logout_monitor.sh" /etc/pam.d/sshd || echo "session optional pam_exec.so seteuid /usr/local/bin/logout_monitor.sh" >> /etc/pam.d/sshd

# 設置會話超時檢查定時任務
echo "設置定時任務..."
(crontab -l 2>/dev/null | grep -v "session_manager.sh\|generate_session_report.sh"; 
echo "*/5 * * * * $SCRIPT_DIR/session_manager.sh check_idle"
echo "0 8 * * * $SCRIPT_DIR/generate_session_report.sh 1") | crontab -

# 修改SSH配置以加強安全性
echo "修改SSH配置..."
if [ -f /etc/ssh/sshd_config ]; then
    # 備份原始配置
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)
    
    # 設置SSH閒置超時
    if grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
        sed -i "s/^ClientAliveInterval.*/ClientAliveInterval 300/" /etc/ssh/sshd_config
    else
        echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
    fi
    
    if grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
        sed -i "s/^ClientAliveCountMax.*/ClientAliveCountMax 3/" /etc/ssh/sshd_config
    else
        echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
    fi
    
    # 重啟SSH服務
    systemctl restart sshd
fi

# 創建簡單的選單腳本，供使用者選擇要連接的伺服器
cat > $SCRIPT_DIR/jump_menu.sh << 'EOF'
#!/bin/bash
# 跳板機選單腳本 - 提供使用者選擇要連接的伺服器

# 載入配置
CONFIG_DIR="/etc/jump_server"
SERVER_LIST_FILE="$CONFIG_DIR/server_list.conf"

# 檢查伺服器列表文件是否存在
if [ ! -f "$SERVER_LIST_FILE" ]; then
    echo "找不到伺服器列表文件，建立範例文件..."
    
    # 建立範例伺服器列表
    cat > $SERVER_LIST_FILE << 'SERVERS'
# 伺服器列表配置
# 格式: 名稱|IP|描述|允許的用戶(逗號分隔，ALL表示所有人)
# 範例:
Web01|192.168.1.101|Web伺服器1|admin,webadmin,ALL
DB01|192.168.1.201|資料庫伺服器1|admin,dbadmin
App01|192.168.1.102|應用伺服器1|admin,appadmin
SERVERS
    
    echo "已建立範例伺服器列表。請編輯 $SERVER_LIST_FILE 設定您的伺服器。"
    echo "格式: 名稱|IP|描述|允許的用戶(逗號分隔，ALL表示所有人)"
    exit 1
fi

# 獲取當前用戶
CURRENT_USER=$(whoami)

# 讀取並顯示伺服器列表
echo "===== 可用伺服器列表 ====="
echo ""

# 建立可訪問伺服器的陣列
declare -a ACCESSIBLE_SERVERS
declare -a SERVER_IPS
declare -a SERVER_NAMES

# 讀取伺服器列表並檢查權限
LINE_NUM=1
while IFS= read -r line; do
    # 跳過註釋和空行
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    
    # 解析行
    IFS='|' read -r name ip description allowed_users <<< "$line"
    
    # 檢查用戶是否有權訪問
    if [[ "$allowed_users" == *"ALL"* || "$allowed_users" == *"$CURRENT_USER"* ]]; then
        ACCESSIBLE_SERVERS+=("$LINE_NUM: $name - $description")
        SERVER_IPS+=("$ip")
        SERVER_NAMES+=("$name")
        ((LINE_NUM++))
    fi
done < "$SERVER_LIST_FILE"

# 顯示可訪問的伺服器
for i in "${!ACCESSIBLE_SERVERS[@]}"; do
    echo "${ACCESSIBLE_SERVERS[$i]}"
done

echo ""
echo "輸入 'q' 退出"
echo "============================="

# 請求用戶選擇
while true; do
    read -p "請選擇要連接的伺服器編號: " choice
    
    # 檢查退出請求
    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        echo "退出跳板機選單"
        exit 0
    fi
    
    # 驗證輸入
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#ACCESSIBLE_SERVERS[@]}" ]]; then
        # 選擇有效，獲取IP
        SERVER_IP="${SERVER_IPS[$((choice-1))]}"
        SERVER_NAME="${SERVER_NAMES[$((choice-1))]}"
        
        echo "連接到 $SERVER_NAME ($SERVER_IP)..."
        
        # 記錄連接信息
        logger -t "jump_menu" "用戶 $CURRENT_USER 選擇連接到 $SERVER_NAME ($SERVER_IP)"
        
        # 連接到伺服器
        ssh "$SERVER_IP"
        
        # 連接結束後重新顯示選單
        echo ""
        echo "===== 可用伺服器列表 ====="
        for i in "${!ACCESSIBLE_SERVERS[@]}"; do
            echo "${ACCESSIBLE_SERVERS[$i]}"
        done
        echo ""
        echo "輸入 'q' 退出"
        echo "============================="
    else
        echo "錯誤: 無效的選擇，請重試"
    fi
done
EOF
chmod +x $SCRIPT_DIR/jump_menu.sh

# 創建伺服器管理工具
cat > $SCRIPT_DIR/manage_servers.sh << 'EOF'
#!/bin/bash
# 伺服器管理工具 - 管理跳板機可訪問的伺服器列表

# 載入配置
CONFIG_DIR="/etc/jump_server"
SERVER_LIST_FILE="$CONFIG_DIR/server_list.conf"

# 確保伺服器列表文件存在
if [ ! -f "$SERVER_LIST_FILE" ]; then
    touch "$SERVER_LIST_FILE"
fi

# 顯示當前伺服器列表
show_servers() {
    echo "===== 當前伺服器列表 ====="
    
    if [ ! -s "$SERVER_LIST_FILE" ]; then
        echo "伺服器列表為空"
        return
    fi
    
    LINE_NUM=1
    while IFS= read -r line; do
        # 跳過註釋和空行
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        # 顯示行號和內容
        echo "$LINE_NUM: $line"
        ((LINE_NUM++))
    done < "$SERVER_LIST_FILE"
}

# 添加伺服器
add_server() {
    echo "===== 添加新伺服器 ====="
    
    # 獲取伺服器信息
    read -p "伺服器名稱: " name
    read -p "伺服器IP: " ip
    read -p "伺服器描述: " description
    read -p "允許的用戶(逗號分隔，ALL表示所有人): " allowed_users
    
    # 添加到文件
    echo "$name|$ip|$description|$allowed_users" >> "$SERVER_LIST_FILE"
    
    echo "伺服器添加成功"
}

# 刪除伺服器
delete_server() {
    show_servers
    
    if [ ! -s "$SERVER_LIST_FILE" ]; then
        return
    fi
    
    read -p "輸入要刪除的伺服器行號: " line_num
    
    # 驗證輸入
    if [[ ! "$line_num" =~ ^[0-9]+$ ]]; then
        echo "錯誤: 請輸入有效的行號"
        return
    fi
    
    # 創建臨時文件
    temp_file=$(mktemp)
    
    # 複製除了要刪除的行外的所有行
    awk -v line="$line_num" 'NR != line' "$SERVER_LIST_FILE" > "$temp_file"
    
    # 替換原文件
    mv "$temp_file" "$SERVER_LIST_FILE"
    
    echo "伺服器已刪除"
}

# 修改伺服器
edit_server() {
    show_servers
    
    if [ ! -s "$SERVER_LIST_FILE" ]; then
        return
    fi
    
    read -p "輸入要修改的伺服器行號: " line_num
    
    # 驗證輸入
    if [[ ! "$line_num" =~ ^[0-9]+$ ]]; then
        echo "錯誤: 請輸入有效的行號"
        return
    fi
    
    # 獲取當前行
    current_line=$(sed -n "${line_num}p" "$SERVER_LIST_FILE")
    
    # 解析當前值
    IFS='|' read -r current_name current_ip current_description current_allowed_users <<< "$current_line"
    
    # 獲取新值，默認使用當前值
    read -p "伺服器名稱 [$current_name]: " name
    name=${name:-$current_name}
    
    read -p "伺服器IP [$current_ip]: " ip
    ip=${ip:-$current_ip}
    
    read -p "伺服器描述 [$current_description]: " description
    description=${description:-$current_description}
    
    read -p "允許的用戶 [$current_allowed_users]: " allowed_users
    allowed_users=${allowed_users:-$current_allowed_users}
    
    # 創建臨時文件
    temp_file=$(mktemp)
    
    # 創建新行
    new_line="$name|$ip|$description|$allowed_users"
    
    # 替換指定行
    awk -v line="$line_num" -v new_text="$new_line" 'NR == line {print new_text; next} {print}' "$SERVER_LIST_FILE" > "$temp_file"
    
    # 替換原文件
    mv "$temp_file" "$SERVER_LIST_FILE"
    
    echo "伺服器已更新"
}

# 幫助信息
show_help() {
    echo "伺服器管理工具"
    echo "用法: $0 [命令]"
    echo ""
    echo "可用命令:"
    echo "  show    - 顯示當前伺服器列表"
    echo "  add     - 添加新伺服器"
    echo "  delete  - 刪除伺服器"
    echo "  edit    - 修改伺服器信息"
    echo "  help    - 顯示此幫助信息"
}

# 主函數
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    command=$1
    
    case $command in
        "show")
            show_servers
            ;;
        "add")
            add_server
            ;;
        "delete")
            delete_server
            ;;
        "edit")
            edit_server
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            echo "錯誤: 未知命令 $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
EOF
chmod +x $SCRIPT_DIR/manage_servers.sh

# 創建用戶環境配置腳本，讓用戶登入後自動顯示選單
cat > /etc/profile.d/jump_server.sh << 'EOF'
#!/bin/bash
# 跳板機環境配置

# 檢查是否通過SSH登入
if [ -n "$SSH_CONNECTION" ]; then
    # 檢查是否為shell登入（非SFTP/SCP）
    if [ -t 0 ]; then
        # 顯示系統信息
        echo "============================================"
        echo "歡迎使用跳板機系統"
        echo "主機名稱: $(hostname)"
        echo "登入時間: $(date)"
        echo "============================================"
        
        # 檢查用戶 shell
        if [[ "$SHELL" == *"bash"* ]]; then
            # 設置 PS1 提示符以區分跳板機
            PS1="\[\e[1;33m\]跳板機\[\e[0m\] \[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\\$ "
        fi
        
        # 詢問是否要顯示伺服器選單
        read -p "是否進入伺服器選單? (y/n) " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            /usr/local/bin/jump_menu.sh
        fi
    fi
fi
EOF
chmod +x /etc/profile.d/jump_server.sh

# 重啟SSH服務
echo "重啟SSH服務..."
systemctl restart sshd

echo "============================================"
echo "跳板機監控系統安裝完成！"
echo ""
echo "主要功能："
echo "- 登入/登出告警"
echo "- 會話時間記錄"
echo "- 異常斷線檢測"
echo "- 閒置超時管理（30分鐘）"
echo "- 多平台通知整合"
echo "- 伺服器選單"
echo ""
echo "配置文件："
echo "- 告警配置: $CONFIG_DIR/alert_config.conf"
echo "- 伺服器列表: $CONFIG_DIR/server_list.conf"
echo ""
echo "常用命令："
echo "- 配置告警: sudo $SCRIPT_DIR/config_alerts.sh"
echo "- 管理伺服器: sudo $SCRIPT_DIR/manage_servers.sh"
echo "- 生成報告: sudo $SCRIPT_DIR/generate_session_report.sh [天數]"
echo "- 伺服器選單: $SCRIPT_DIR/jump_menu.sh"
echo ""
echo "建議後續步驟："
echo "1. 配置您的告警設置："
echo "   sudo $SCRIPT_DIR/config_alerts.sh set TELEGRAM_TOKEN 'your-token'"
echo "   sudo $SCRIPT_DIR/config_alerts.sh set TELEGRAM_CHAT_ID 'your-chat-id'"
echo "2. 添加您的伺服器列表："
echo "   sudo $SCRIPT_DIR/manage_servers.sh add"
echo "3. 測試告警系統："
echo "   sudo $SCRIPT_DIR/config_alerts.sh test"
echo "============================================"    