#!/bin/bash
# 跳板機服務器連接腳本 - 簡化共享版
# 保存為 /usr/local/bin/connect-server.sh

# 關鍵改進: 使用單一的共享配置文件，所有用戶都可讀寫
SHARED_SERVERS_FILE="/etc/bastion_servers.conf"

# 顯示標題
show_header() {
    clear
    echo "======================================="
    echo "          服務器連接系統               "
    echo "======================================="
    echo ""
}

# 確保配置文件存在並有正確權限
ensure_config_file() {
    # 如果配置文件不存在，嘗試創建它
    if [ ! -f "$SHARED_SERVERS_FILE" ]; then
        # 嘗試創建配置文件（可能需要sudo）
        if [ "$(id -u)" -eq 0 ]; then
            # 如果是root用戶，直接創建
            touch "$SHARED_SERVERS_FILE"
            # 設置權限為所有用戶可讀寫
            chmod 666 "$SHARED_SERVERS_FILE"
            echo "已創建共享服務器配置文件: $SHARED_SERVERS_FILE"
        else
            # 如果不是root用戶，使用sudo嘗試創建
            echo "服務器配置文件不存在，將嘗試創建它..."
            if sudo -n true 2>/dev/null; then
                # 如果sudo不需要密碼
                sudo touch "$SHARED_SERVERS_FILE"
                sudo chmod 666 "$SHARED_SERVERS_FILE"
                echo "已創建共享服務器配置文件: $SHARED_SERVERS_FILE"
            else
                # 如果sudo需要密碼，提示用戶
                echo "錯誤: 配置文件 $SHARED_SERVERS_FILE 不存在"
                echo "請聯繫系統管理員創建此文件並設置適當的權限"
                echo "建議: sudo touch $SHARED_SERVERS_FILE && sudo chmod 666 $SHARED_SERVERS_FILE"
                read -p "按Enter鍵繼續..." temp
            fi
        fi
    fi

    # 檢查文件權限
    if [ -f "$SHARED_SERVERS_FILE" ] && [ ! -r "$SHARED_SERVERS_FILE" ]; then
        echo "警告: 無法讀取配置文件 $SHARED_SERVERS_FILE"
        echo "請聯繫系統管理員設置適當的權限"
        echo "建議: sudo chmod 666 $SHARED_SERVERS_FILE"
        read -p "按Enter鍵繼續..." temp
    fi

    if [ -f "$SHARED_SERVERS_FILE" ] && [ ! -w "$SHARED_SERVERS_FILE" ]; then
        echo "警告: 無法寫入配置文件 $SHARED_SERVERS_FILE"
        echo "您只能查看服務器列表，但不能添加、修改或刪除服務器"
        echo "請聯繫系統管理員設置適當的權限"
        echo "建議: sudo chmod 666 $SHARED_SERVERS_FILE"
        read -p "按Enter鍵繼續..." temp
    fi
}

# 連接到服務器
connect_to_server() {
    show_header
    echo "【連接到服務器】"
    echo ""

    # 確保配置文件存在
    ensure_config_file

    # 檢查文件是否存在且可讀
    if [ ! -r "$SHARED_SERVERS_FILE" ]; then
        echo "錯誤: 無法讀取服務器配置文件"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 檢查是否有服務器配置
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "尚未配置任何服務器"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 顯示服務器列表
    echo "可用服務器列表："
    echo "----------------------------------------"
    printf "%-5s %-20s %-15s %-20s %s\n" "編號" "服務器名稱" "用戶名" "主機地址" "添加者"
    echo "----------------------------------------"
    
    counter=1
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            printf "%-5s %-20s %-15s %-20s %s\n" "$counter" "$server_name" "$server_user" "$server_host" "$added_by"
            counter=$((counter+1))
        fi
    done < "$SHARED_SERVERS_FILE"
    
    if [ $counter -eq 1 ]; then
        echo "沒有找到有效的服務器配置"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    echo "----------------------------------------"
    echo "0) 返回主選單"
    echo ""

    read -p "請輸入服務器編號: " choice

    if [ "$choice" = "0" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((counter-1)) ]; then
        echo "錯誤：無效的服務器編號"
        read -p "按Enter鍵返回..." temp
        return
    fi

    # 獲取所選服務器信息
    server_line=$(sed -n "${choice}p" "$SHARED_SERVERS_FILE")
    IFS='|' read -r server_name server_user server_host _ <<< "$server_line"

    echo ""
    echo "正在連接到 $server_name ($server_user@$server_host)"
    ssh "$server_user"@"$server_host"

    # 連接後返回主選單
    echo ""
    read -p "連接已結束。按Enter鍵返回主選單..." temp
}

# 添加服務器
add_server() {
    show_header
    echo "【添加服務器】"
    echo ""

    # 確保配置文件存在
    ensure_config_file

    # 檢查文件是否存在且可寫
    if [ ! -w "$SHARED_SERVERS_FILE" ]; then
        echo "錯誤: 無法寫入服務器配置文件"
        echo "請聯繫系統管理員設置適當的權限"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    read -p "請輸入服務器名稱 (例如: kibana, es01): " server_name
    if [ -z "$server_name" ]; then
        echo "錯誤：服務器名稱不能為空"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    read -p "請輸入用戶名 (例如: elk): " server_user
    if [ -z "$server_user" ]; then
        echo "錯誤：用戶名不能為空"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    read -p "請輸入主機地址 (例如: 192.0.2.10): " server_host
    if [ -z "$server_host" ]; then
        echo "錯誤：主機地址不能為空"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 檢查是否已存在相同服務器
    if grep -q "^$server_name|$server_user|$server_host|" "$SHARED_SERVERS_FILE"; then
        echo "錯誤：該服務器配置已存在"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 獲取當前用戶名
    current_user=$(whoami)

    # 添加到配置文件
    echo "$server_name|$server_user|$server_host|$current_user" >> "$SHARED_SERVERS_FILE"

    echo ""
    echo "服務器 $server_name ($server_user@$server_host) 已添加到共享服務器列表"
    read -p "按Enter鍵返回主選單..." temp
}

# 刪除服務器
delete_server() {
    show_header
    echo "【刪除服務器】"
    echo ""

    # 確保配置文件存在
    ensure_config_file

    # 檢查文件是否存在且可寫
    if [ ! -w "$SHARED_SERVERS_FILE" ] || [ ! -r "$SHARED_SERVERS_FILE" ]; then
        echo "錯誤: 無法讀取或寫入服務器配置文件"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 獲取當前用戶名
    current_user=$(whoami)
    is_root=0
    if [ "$(id -u)" -eq 0 ]; then
        is_root=1
    fi

    # 檢查是否有服務器配置
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "尚未配置任何服務器"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 顯示可刪除的服務器列表
    echo "可刪除的服務器列表："
    echo "----------------------------------------"
    printf "%-5s %-20s %-15s %-20s %s\n" "編號" "服務器名稱" "用戶名" "主機地址" "添加者"
    echo "----------------------------------------"
    
    counter=1
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            
            # 只顯示當前用戶添加的服務器，除非是root用戶
            if [ "$is_root" -eq 1 ] || [ "$added_by" = "$current_user" ]; then
                printf "%-5s %-20s %-15s %-20s %s\n" "$counter" "$server_name" "$server_user" "$server_host" "$added_by"
                deleted_lines[$counter]=$counter
                counter=$((counter+1))
            fi
        fi
    done < "$SHARED_SERVERS_FILE"
    
    if [ $counter -eq 1 ]; then
        echo "沒有找到您可以刪除的服務器配置"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    echo "----------------------------------------"
    echo "0) 返回主選單"
    echo ""

    read -p "請輸入要刪除的服務器編號: " choice

    if [ "$choice" = "0" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((counter-1)) ]; then
        echo "錯誤：無效的服務器編號"
        read -p "按Enter鍵返回..." temp
        return
    fi

    # 獲取所選服務器信息及行號
    counter=1
    line_num=0
    target_line=""
    while IFS= read -r line; do
        line_num=$((line_num+1))
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            
            # 只處理當前用戶添加的服務器，除非是root用戶
            if [ "$is_root" -eq 1 ] || [ "$added_by" = "$current_user" ]; then
                if [ $counter -eq $choice ]; then
                    target_line=$line
                    target_line_num=$line_num
                    target_server_name=$server_name
                    target_server_user=$server_user
                    target_server_host=$server_host
                    break
                fi
                counter=$((counter+1))
            fi
        fi
    done < "$SHARED_SERVERS_FILE"

    read -p "確認刪除服務器 $target_server_name ($target_server_user@$target_server_host)？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 刪除指定行
        sed -i "${target_line_num}d" "$SHARED_SERVERS_FILE"
        echo "服務器已從列表中刪除"
    else
        echo "操作已取消"
    fi

    read -p "按Enter鍵返回主選單..." temp
}

# 修改服務器
modify_server() {
    show_header
    echo "【修改服務器信息】"
    echo ""

    # 確保配置文件存在
    ensure_config_file

    # 檢查文件是否存在且可寫
    if [ ! -w "$SHARED_SERVERS_FILE" ] || [ ! -r "$SHARED_SERVERS_FILE" ]; then
        echo "錯誤: 無法讀取或寫入服務器配置文件"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 獲取當前用戶名
    current_user=$(whoami)
    is_root=0
    if [ "$(id -u)" -eq 0 ]; then
        is_root=1
    fi

    # 檢查是否有服務器配置
    if [ ! -s "$SHARED_SERVERS_FILE" ]; then
        echo "尚未配置任何服務器"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi

    # 顯示可修改的服務器列表
    echo "可修改的服務器列表："
    echo "----------------------------------------"
    printf "%-5s %-20s %-15s %-20s %s\n" "編號" "服務器名稱" "用戶名" "主機地址" "添加者"
    echo "----------------------------------------"
    
    counter=1
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            
            # 只顯示當前用戶添加的服務器，除非是root用戶
            if [ "$is_root" -eq 1 ] || [ "$added_by" = "$current_user" ]; then
                printf "%-5s %-20s %-15s %-20s %s\n" "$counter" "$server_name" "$server_user" "$server_host" "$added_by"
                counter=$((counter+1))
            fi
        fi
    done < "$SHARED_SERVERS_FILE"
    
    if [ $counter -eq 1 ]; then
        echo "沒有找到您可以修改的服務器配置"
        read -p "按Enter鍵返回主選單..." temp
        return
    fi
    
    echo "----------------------------------------"
    echo "0) 返回主選單"
    echo ""

    read -p "請輸入要修改的服務器編號: " choice

    if [ "$choice" = "0" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((counter-1)) ]; then
        echo "錯誤：無效的服務器編號"
        read -p "按Enter鍵返回..." temp
        return
    fi

    # 獲取所選服務器信息及行號
    counter=1
    line_num=0
    target_line=""
    while IFS= read -r line; do
        line_num=$((line_num+1))
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            IFS='|' read -r server_name server_user server_host added_by _ <<< "$line"
            if [ -z "$added_by" ]; then
                added_by="未知"
            fi
            
            # 只處理當前用戶添加的服務器，除非是root用戶
            if [ "$is_root" -eq 1 ] || [ "$added_by" = "$current_user" ]; then
                if [ $counter -eq $choice ]; then
                    target_line=$line
                    target_line_num=$line_num
                    old_server_name=$server_name
                    old_server_user=$server_user
                    old_server_host=$server_host
                    old_added_by=$added_by
                    break
                fi
                counter=$((counter+1))
            fi
        fi
    done < "$SHARED_SERVERS_FILE"

    echo ""
    echo "正在修改服務器信息："
    echo "服務器名稱: $old_server_name"
    echo "用戶名: $old_server_user"
    echo "主機地址: $old_server_host"
    echo ""
    echo "請輸入新的信息 (保持原值請直接按Enter)"

    read -p "新服務器名稱 [$old_server_name]: " new_server_name
    read -p "新用戶名 [$old_server_user]: " new_server_user
    read -p "新主機地址 [$old_server_host]: " new_server_host

    # 如果輸入為空，保持原值
    new_server_name=${new_server_name:-$old_server_name}
    new_server_user=${new_server_user:-$old_server_user}
    new_server_host=${new_server_host:-$old_server_host}

    # 確認修改
    echo ""
    echo "修改後的信息："
    echo "服務器名稱: $new_server_name"
    echo "用戶名: $new_server_user"
    echo "主機地址: $new_server_host"
    echo ""

    read -p "確認修改？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 更新服務器信息
        sed -i "${target_line_num}s/.*/$new_server_name|$new_server_user|$new_server_host|$old_added_by/" "$SHARED_SERVERS_FILE"
        echo "服務器信息已更新"
    else
        echo "操作已取消"
    fi

    read -p "按Enter鍵返回主選單..." temp
}

# 檢查文件權限
check_permissions() {
    show_header
    echo "【檢查文件權限】"
    echo ""
    
    if [ -f "$SHARED_SERVERS_FILE" ]; then
        echo "配置文件狀態:"
        echo "----------------------------------------"
        echo "文件路徑: $SHARED_SERVERS_FILE"
        
        # 獲取文件權限
        file_perms=$(ls -l "$SHARED_SERVERS_FILE" | awk '{print $1}')
        file_owner=$(ls -l "$SHARED_SERVERS_FILE" | awk '{print $3}')
        file_group=$(ls -l "$SHARED_SERVERS_FILE" | awk '{print $4}')
        
        echo "文件所有者: $file_owner"
        echo "文件組: $file_group"
        echo "文件權限: $file_perms"
        
        # 檢查權限是否正確
        if [ ! -r "$SHARED_SERVERS_FILE" ]; then
            echo "警告: 當前用戶無法讀取此文件"
        else
            echo "讀取權限: 正常"
        fi
        
        if [ ! -w "$SHARED_SERVERS_FILE" ]; then
            echo "警告: 當前用戶無法寫入此文件"
        else
            echo "寫入權限: 正常"
        fi
        
        # 檢查是否所有用戶都有讀寫權限
        if [[ ! "$file_perms" =~ "rw.rw.rw." ]]; then
            echo ""
            echo "建議更新權限設置，以允許所有用戶讀寫:"
            echo "sudo chmod 666 $SHARED_SERVERS_FILE"
        else
            echo ""
            echo "文件權限設置正確，所有用戶可讀寫。"
        fi
    else
        echo "配置文件不存在: $SHARED_SERVERS_FILE"
        echo ""
        echo "建議創建文件並設置適當權限:"
        echo "sudo touch $SHARED_SERVERS_FILE"
        echo "sudo chmod 666 $SHARED_SERVERS_FILE"
    fi
    
    echo "----------------------------------------"
    read -p "按Enter鍵返回主選單..." temp
}

# 幫助選單
show_help() {
    show_header
    echo "【幫助信息】"
    echo ""
    echo "服務器連接系統使用說明："
    echo ""
    echo "1. 基本概念:"
    echo "   - 此系統使用單一共享配置文件來存儲所有服務器信息"
    echo "   - 所有用戶可以查看所有服務器"
    echo "   - 普通用戶只能修改/刪除自己添加的服務器"
    echo "   - root用戶可以修改/刪除任何服務器"
    echo ""
    echo "2. 首次使用:"
    echo "   - 如果您是系統管理員，請確保配置文件存在且權限正確"
    echo "   - 配置文件路徑: $SHARED_SERVERS_FILE"
    echo "   - 推薦權限設置: 666 (所有用戶可讀寫)"
    echo ""
    echo "3. 故障排除:"
    echo "   - 如果遇到權限問題，請使用'檢查文件權限'功能"
    echo "   - 確保配置文件存在且權限正確:"
    echo "     sudo touch $SHARED_SERVERS_FILE"
    echo "     sudo chmod 666 $SHARED_SERVERS_FILE"
    echo ""
    read -p "按Enter鍵返回主選單..." temp
}

# 顯示主選單
show_menu() {
    show_header
    echo "請選擇操作："
    echo ""
    echo "1) 查看所有服務器並連接"
    echo "2) 添加服務器"
    echo "3) 修改服務器"
    echo "4) 刪除服務器"
    echo "5) 檢查文件權限"
    echo "6) 幫助信息"
    echo "0) 退出"
    echo ""
    read -p "請輸入選項 [0-6]: " choice

    case $choice in
        1) connect_to_server ;;
        2) add_server ;;
        3) modify_server ;;
        4) delete_server ;;
        5) check_permissions ;;
        6) show_help ;;
        0) echo "感謝使用！"; exit 0 ;;
        *)
            echo "錯誤：無效的選項"
            read -p "按Enter鍵繼續..." temp
            ;;
    esac
}

# 主程序循環
while true; do
    show_menu
done