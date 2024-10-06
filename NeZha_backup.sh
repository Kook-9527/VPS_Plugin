#!/bin/bash

# 确保脚本具有执行权限
chmod +x /root/NeZha_backup.sh

# 环境变量设置
BACKUP_DIR="/opt/nezha"                                     # 哪吒探针数据目录
BACKUP_FILE="nezha_backup_$(date +'%Y-%m-%d').tar.gz"       # 备份文件名
MAX_BACKUPS=5                                               # 最多保留5份备份
GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"     # 直接写入你的 GitHub Token
GITHUB_USERNAME="填GitHub用户名"                             # 你的 GitHub 用户名
GITHUB_REPO="填GitHub仓库名"                                 # 你的 GitHub 仓库名
GITHUB_BRANCH="main"                                        # GitHub分支
LOG_FILE="/root/NeZha_backup.log"                           # 日志文件

# Git 用户名和邮箱配置
GIT_USER_NAME="填GitHub用户名"                               # Git 用户名
GIT_USER_EMAIL="GitHub用户名@users.noreply.github.com"       # Git 用户邮箱

# Telegram 推送设置
TG_BOT_TOKEN="123456:aaaaaaaaaaaaaaaa"                       # Telegram Bot Token
TG_CHAT_ID="11111111"                                        # Telegram Chat ID

CRON_CMD="/root/NeZha_backup.sh"      # 定时任务的命令
CRON_SCHEDULE="20 3 * * *"            # 定时任务时间，每天凌晨3点20分

# 检查定时任务是否存在
crontab_exists() {
  crontab -l 2>/dev/null | grep -F "$CRON_CMD" > /dev/null
}

# 添加定时任务
add_cron_job() {
  if crontab_exists; then
    echo "定时任务已存在，跳过添加。"
  else
    (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CRON_CMD") | crontab -
    echo "定时任务已添加：$CRON_SCHEDULE $CRON_CMD"
  fi
}

# 发送 Telegram 推送
send_telegram_message() {
  local message=$1
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
       -d chat_id="$TG_CHAT_ID" \
       -d text="$message" > /dev/null
}

# 配置 Git 用户名和邮箱
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# 添加定时任务
add_cron_job

# 停止哪吒探针
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 停止哪吒探针..." | tee -a $LOG_FILE
docker stop dashboard-dashboard-1 | tee -a $LOG_FILE

# 打包备份 (只打包 agent 和 dashboard 文件夹)
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始备份哪吒探针数据..." | tee -a $LOG_FILE
tar -czvf $BACKUP_DIR/$BACKUP_FILE -C $BACKUP_DIR agent dashboard | tee -a $LOG_FILE

# 保留最多5份备份
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 清理旧备份，保留最新的5份备份..." | tee -a $LOG_FILE
cd $BACKUP_DIR
ls -tp | grep 'nezha_backup_.*\.tar\.gz' | tail -n +$((MAX_BACKUPS + 1)) | xargs -I {} rm -- {}

# 初始化 Git 仓库（如果还没有）
if [ ! -d ".git" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] 初始化Git仓库..." | tee -a $LOG_FILE
  git init
fi

# 提交并推送到 GitHub
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 提交备份并推送到 GitHub..." | tee -a $LOG_FILE
git add $BACKUP_FILE
git commit -m "Auto backup on $(date +'%Y-%m-%d %H:%M:%S')" | tee -a $LOG_FILE

# 设置 GitHub 远程仓库并推送
git remote add origin "https://$GITHUB_TOKEN@github.com/$GITHUB_USERNAME/$GITHUB_REPO.git" 2>/dev/null  # 如果已存在则忽略错误
git branch -M $GITHUB_BRANCH
git push -u origin $GITHUB_BRANCH --force | tee -a $LOG_FILE

# 删除本地备份文件
if [ $? -eq 0 ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] 推送成功，删除本地备份文件..." | tee -a $LOG_FILE
  rm -f $BACKUP_DIR/$BACKUP_FILE
  send_telegram_message "哪吒探针备份成功，并已推送至GitHub仓库。备份文件名：$BACKUP_FILE"
else
  send_telegram_message "哪吒探针备份失败，请检查日志。"
fi

# 启动哪吒探针
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 启动哪吒探针..." | tee -a $LOG_FILE
docker start dashboard-dashboard-1 | tee -a $LOG_FILE

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 备份完成。" | tee -a $LOG_FILE
