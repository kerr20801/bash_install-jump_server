#!/bin/bash
# Ubuntu 用戶管理腳本 - 建立新用戶並可選擇是否授予 sudo 權限

# 確保腳本以 root 權限運行
if [ "$(id -u)" -ne 0 ]; then
   echo "此腳本需要 root 權限運行，請使用 sudo 執行"
   exit 1
fi

# 提示輸入新用戶名稱
read -p "請輸入新用戶名稱 (例如: kibana, logstash1, logstash2): " NEW_USER

# 如果沒有輸入用戶名，則使用默認值
if [ -z "$NEW_USER" ]; then
    NEW_USER="kibana"
    echo "使用默認用戶名: $NEW_USER"
fi

# 提示輸入新密碼（或者您可以使用 keepass 生成的密碼）
read -s -p "請輸入新用戶 $NEW_USER 的密碼: " NEW_PASSWORD
echo ""
read -s -p "請再次輸入密碼確認: " PASSWORD_CONFIRM
echo ""

# 檢查兩次輸入的密碼是否一致
if [ "$NEW_PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    echo "錯誤: 兩次輸入的密碼不一致!"
    exit 1
fi

# 檢查新用戶是否已經存在
if id "$NEW_USER" &>/dev/null; then
    echo "用戶 $NEW_USER 已經存在，終止腳本執行。"
    exit 1
fi

# 建立新用戶
echo "正在建立新用戶 $NEW_USER..."
useradd -m -s /bin/bash "$NEW_USER"

# 設定密碼
echo "$NEW_USER:$NEW_PASSWORD" | chpasswd

# 詢問是否要將新用戶加入 sudo 組
read -p "是否要授予用戶 $NEW_USER sudo 權限? (y/n): " ADD_SUDO

if [ "$ADD_SUDO" = "y" ] || [ "$ADD_SUDO" = "Y" ]; then
    echo "將 $NEW_USER 加入 sudo 組..."
    usermod -aG sudo "$NEW_USER"
else
    echo "不授予 $NEW_USER sudo 權限。"
fi

# 複製 SSH 授權（如果有的話）
if [ -d "/home/ubuntu/.ssh" ]; then
    echo "複製 SSH 密鑰..."
    mkdir -p "/home/$NEW_USER/.ssh"
    cp -r /home/ubuntu/.ssh/* "/home/$NEW_USER/.ssh/"
    chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys" 2>/dev/null || true
fi

# 確認新用戶已建立成功
if id "$NEW_USER" &>/dev/null; then
    echo "用戶 $NEW_USER 已成功建立。"
    if [ "$ADD_SUDO" = "y" ] || [ "$ADD_SUDO" = "Y" ]; then
        echo "用戶 $NEW_USER 已加入 sudo 組。"
    fi

    # 提示備份重要檔案
    echo "警告: 即將刪除 ubuntu 用戶。請確保您已經備份了所有重要檔案。"
    read -p "確定要繼續嗎? (y/n): " CONFIRM

    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        # 檢查當前登入的用戶
        CURRENT_USER=$(whoami)
        if [ "$CURRENT_USER" = "ubuntu" ]; then
            echo "警告: 您當前是以 ubuntu 用戶登入的，刪除此用戶可能導致問題。"
            echo "建議您先以新用戶 $NEW_USER 登入，然後再刪除 ubuntu 用戶。"
            read -p "仍然要繼續嗎? (y/n): " FINAL_CONFIRM

            if [ "$FINAL_CONFIRM" != "y" ] && [ "$FINAL_CONFIRM" != "Y" ]; then
                echo "操作已取消。"
                exit 0
            fi
        fi

        echo "正在刪除 ubuntu 用戶..."
        pkill -u ubuntu  # 終止所有 ubuntu 用戶的進程
        deluser --remove-home ubuntu
        echo "ubuntu 用戶已刪除。"
    else
        echo "已取消刪除 ubuntu 用戶。"
    fi
else
    echo "錯誤: 用戶建立失敗！"
    exit 1
fi

echo "腳本執行完成。"