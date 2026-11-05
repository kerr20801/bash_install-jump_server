# 🛡️ 安全跳板機部署指南

## 📋 概述

這是一個安全增強版的跳板機系統，修復了原版本的安全漏洞，並新增了完整的 SSH Key 管理功能。

### 🎯 主要改進

1. **安全漏洞修復**：
   - ✅ 修復 `chmod 666` 安全問題 → 改為 `chmod 660`
   - ✅ 實現基於角色的權限控制
   - ✅ 新增審計日誌記錄
   - ✅ 加強文件權限管理

2. **SSH Key 自動化**：
   - ✅ 自動生成和分發 SSH Key
   - ✅ 批量密鑰管理
   - ✅ 密鑰輪換機制
   - ✅ 完整的密鑰審計

3. **用戶管理增強**：
   - ✅ 角色化用戶管理
   - ✅ 密碼強度驗證
   - ✅ 自動 SSH Key 配置
   - ✅ 安全策略實施

## 🚀 快速部署

### 第一步：系統準備

```bash
# 1. 更新系統
sudo apt update && sudo apt upgrade -y

# 2. 安裝依賴
sudo apt install -y openssh-server openssh-client pwgen openssl curl jq fail2ban

# 3. 創建基礎目錄
sudo mkdir -p /etc/jump_server
sudo mkdir -p /var/log/jump_sessions
sudo mkdir -p /etc/ssh/jump_keys
```

### 第二步：部署腳本

```bash
# 1. 複製腳本到系統目錄
sudo cp connect-server-secure.sh /usr/local/bin/
sudo cp ssh_key_manager.sh /usr/local/bin/
sudo cp secure_useradd.sh /usr/local/bin/

# 2. 設置執行權限
sudo chmod +x /usr/local/bin/connect-server-secure.sh
sudo chmod +x /usr/local/bin/ssh_key_manager.sh
sudo chmod +x /usr/local/bin/secure_useradd.sh

# 3. 創建符號連結（可選）
sudo ln -sf /usr/local/bin/connect-server-secure.sh /usr/local/bin/jump-connect
sudo ln -sf /usr/local/bin/ssh_key_manager.sh /usr/local/bin/jump-keys
sudo ln -sf /usr/local/bin/secure_useradd.sh /usr/local/bin/jump-user
```

### 第三步：初始化環境

```bash
# 1. 初始化用戶管理環境
sudo /usr/local/bin/secure_useradd.sh
# 選擇選項 4: 初始化系統環境

# 2. 初始化 SSH Key 管理
sudo /usr/local/bin/ssh_key_manager.sh
# 選擇選項 6: 初始化管理目錄

# 3. 設置配置文件權限
sudo chown root:jump_users /etc/jump_server/
sudo chmod 750 /etc/jump_server/
```

## 📖 使用指南

### 👤 用戶管理

#### 創建新用戶
```bash
sudo /usr/local/bin/secure_useradd.sh
# 或
sudo jump-user
```

**用戶角色說明**：
- **admin**：管理員 - 完全權限
- **devops**：DevOps - 服務器管理權限
- **developer**：開發者 - 基本連接權限
- **readonly**：只讀 - 查看權限

#### 查看用戶狀態
```bash
# 查看所有跳板機用戶
sudo jump-user
# 選擇選項 2: 查看用戶狀態
```

### 🔑 SSH Key 管理

#### 生成跳板機主密鑰
```bash
sudo /usr/local/bin/ssh_key_manager.sh
# 選擇選項 2: 生成跳板機主密鑰
```

#### 為用戶生成 SSH Key
```bash
sudo /usr/local/bin/ssh_key_manager.sh
# 選擇選項 1: 為用戶生成 SSH Key
```

#### 分發密鑰到服務器
```bash
sudo /usr/local/bin/ssh_key_manager.sh
# 選擇選項 3: 分發密鑰到服務器
# 或選項 4: 批量分發密鑰
```

### 🖥️ 服務器連接

#### 基本連接
```bash
/usr/local/bin/connect-server-secure.sh
# 或
jump-connect
```

#### 管理服務器列表
```bash
jump-connect
# 選擇選項 2: 管理服務器
```

## 🔐 安全配置

### 權限控制

#### 配置文件位置
- **權限配置**：`/etc/jump_server/permissions.conf`
- **用戶策略**：`/etc/jump_server/user_policy.conf`
- **SSH Key 配置**：`/etc/jump_server/ssh_keys.conf`

#### 編輯權限配置
```bash
sudo nano /etc/jump_server/permissions.conf
```

```bash
# 管理員 (完全權限)
admin_users="root admin"

# 高級用戶 (服務器管理權限)  
power_users="devops sre ops"

# 普通用戶 (連接權限)
regular_users="dev developer test tester"

# 只讀用戶 (查看權限)
readonly_users="monitor audit readonly"
```

### 審計日誌

#### 查看審計日誌
```bash
# 用戶管理日誌
sudo tail -f /var/log/jump_sessions/user_management.log

# SSH Key 管理日誌
sudo tail -f /var/log/jump_sessions/ssh_key_audit.log

# 服務器訪問日誌
sudo tail -f /var/log/jump_sessions/server_access.log
```

#### 日誌輪轉配置
```bash
# 創建 logrotate 配置
sudo tee /etc/logrotate.d/jump_server << EOF
/var/log/jump_sessions/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    copytruncate
    notifempty
    create 0640 root jump_users
}
EOF
```

## 🔄 維護和監控

### 定期維護任務

#### SSH Key 輪換
```bash
# 建議每90天輪換主密鑰
# 創建 cron 任務
sudo crontab -e

# 添加以下行 (每90天執行)
0 2 1 */3 * /usr/local/bin/ssh_key_manager.sh batch_rotate_keys
```

#### 清理過期會話
```bash
# 創建清理腳本
sudo tee /usr/local/bin/cleanup_jump_sessions.sh << 'EOF'
#!/bin/bash
# 清理30天前的日誌
find /var/log/jump_sessions/ -name "*.log" -mtime +30 -delete
# 清理過期的備份
find /var/backups/deleted_users/ -mtime +90 -exec rm -rf {} +
EOF

sudo chmod +x /usr/local/bin/cleanup_jump_sessions.sh

# 添加到 cron
echo "0 3 * * 0 /usr/local/bin/cleanup_jump_sessions.sh" | sudo crontab -
```

### 監控和告警

#### 系統健康檢查
```bash
# 創建健康檢查腳本
sudo tee /usr/local/bin/jump_server_health.sh << 'EOF'
#!/bin/bash
# 跳板機系統健康檢查

echo "=== 跳板機系統健康檢查 ==="
echo "檢查時間: $(date)"
echo ""

# 檢查群組
if getent group jump_users > /dev/null; then
    echo "✅ jump_users 群組: 正常"
else
    echo "❌ jump_users 群組: 不存在"
fi

# 檢查配置文件
config_files=(
    "/etc/jump_server/permissions.conf"
    "/etc/bastion_servers.conf"
    "/etc/ssh/jump_keys/master/current.pub"
)

for file in "${config_files[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ 配置文件 $file: 存在"
    else
        echo "❌ 配置文件 $file: 不存在"
    fi
done

# 檢查服務
if systemctl is-active ssh > /dev/null; then
    echo "✅ SSH 服務: 運行中"
else
    echo "❌ SSH 服務: 未運行"
fi

# 檢查用戶數量
user_count=$(getent group jump_users | cut -d: -f4 | tr ',' '\n' | wc -l)
echo "📊 跳板機用戶數量: $user_count"

# 檢查活動會話
active_sessions=$(who | wc -l)
echo "📊 活動會話數量: $active_sessions"
EOF

sudo chmod +x /usr/local/bin/jump_server_health.sh

# 執行健康檢查
sudo /usr/local/bin/jump_server_health.sh
```

## 🚨 故障排除

### 常見問題

#### 問題1：用戶無法連接服務器
```bash
# 檢查用戶是否在正確的群組中
groups username

# 檢查 SSH Key 是否存在
ls -la /home/username/.ssh/

# 檢查配置文件權限
ls -la /etc/bastion_servers.conf

# 檢查審計日誌
sudo tail /var/log/jump_sessions/server_access.log
```

#### 問題2：SSH Key 分發失敗
```bash
# 檢查主密鑰是否存在
ls -la /etc/ssh/jump_keys/master/

# 手動測試連接
ssh -i /etc/ssh/jump_keys/master/current user@target_server

# 檢查網路連通性
ping target_server
```

#### 問題3：權限被拒絕
```bash
# 檢查文件權限
ls -la /etc/jump_server/
ls -la /var/log/jump_sessions/

# 修復權限
sudo chown -R root:jump_users /etc/jump_server/
sudo chmod 750 /etc/jump_server/
sudo chmod 640 /etc/jump_server/*.conf
```

### 緊急恢復

#### 重置配置文件
```bash
# 備份現有配置
sudo cp -r /etc/jump_server /etc/jump_server.backup.$(date +%Y%m%d)

# 重新初始化
sudo /usr/local/bin/secure_useradd.sh
# 選擇選項 4: 初始化系統環境
```

#### 重建 SSH Key
```bash
# 備份現有密鑰
sudo cp -r /etc/ssh/jump_keys /etc/ssh/jump_keys.backup.$(date +%Y%m%d)

# 重新生成主密鑰
sudo /usr/local/bin/ssh_key_manager.sh
# 選擇選項 2: 生成跳板機主密鑰
```

## 📈 性能優化

### 連接優化

#### SSH 配置優化
```bash
# 編輯 SSH 配置
sudo nano /etc/ssh/sshd_config

# 優化設置
MaxAuthTries 3
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
GSSAPIAuthentication no
```

#### 會話管理優化
```bash
# 設置會話限制
echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session

# 編輯限制配置
sudo nano /etc/security/limits.conf

# 添加限制
@jump_users soft nofile 1024
@jump_users hard nofile 2048
@jump_users soft nproc 64
@jump_users hard nproc 128
```

## 📊 監控指標

### 關鍵指標

1. **用戶活動**：
   - 活動用戶數量
   - 每日登錄次數
   - 平均會話時長

2. **SSH Key 使用**：
   - 密鑰分發成功率
   - 密鑰使用頻率
   - 過期密鑰數量

3. **系統性能**：
   - CPU 使用率
   - 記憶體使用率
   - 網路連接數

4. **安全事件**：
   - 登錄失敗次數
   - 權限被拒絕事件
   - 異常訪問嘗試

## 🎯 最佳實踐

### 安全建議

1. **定期更新**：
   - 每月更新系統套件
   - 定期檢查腳本更新

2. **權限管理**：
   - 最小權限原則
   - 定期審核用戶權限
   - 及時移除離職用戶

3. **監控告警**：
   - 設置異常登錄告警
   - 監控系統資源使用
   - 定期檢查審計日誌

4. **備份策略**：
   - 定期備份配置文件
   - 備份 SSH Key 和用戶數據
   - 測試備份恢復流程

### 運維建議

1. **文檔維護**：
   - 更新操作手冊
   - 記錄變更日誌
   - 維護故障排除手冊

2. **培訓教育**：
   - 用戶安全意識培訓
   - 操作流程培訓
   - 緊急響應培訓

---

## 🆘 技術支援

如有任何問題或建議，請查看：
- 審計日誌：`/var/log/jump_sessions/`
- 系統日誌：`journalctl -u ssh`
- 配置文件：`/etc/jump_server/`

**緊急聯繫**：系統管理員 📞