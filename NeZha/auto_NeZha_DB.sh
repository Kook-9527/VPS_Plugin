#!/bin/bash

# =================配置区域=================
# 哪吒探针安装目录 (请根据实际情况修改)
NEZHA_DIR="/opt/nezha/dashboard"
# 数据库路径
DB_PATH="$NEZHA_DIR/data/sqlite.db"
# 备份存放路径
BACKUP_PATH="$NEZHA_DIR/data/sqlite.db.bak"
# 保留数据天数 (修改为 30 天)
KEEP_DAYS=30
# 脚本自身的绝对路径 (用于添加定时任务)
SCRIPT_PATH=$(readlink -f "$0")
# ==========================================

echo "开始执行哪吒探针数据库维护..."

# 1. 停止服务
docker stop nezha-dashboard
if [ $? -ne 0 ]; then
    echo "错误：无法停止 nezha-dashboard 容器，请检查容器名或权限。"
    exit 1
fi

# 2. 备份数据库
cp "$DB_PATH" "$BACKUP_PATH"
echo "数据库已备份至: $BACKUP_PATH"

# 3. 清理旧数据 (针对 history 和 transfer 表)
# 哪吒的表结构中通常使用 created_at (秒级时间戳)
CUTOFF_TIME=$(date -d "$KEEP_DAYS days ago" +%s)
echo "正在清理 $KEEP_DAYS 天前的数据..."

sqlite3 "$DB_PATH" <<EOF
DELETE FROM history WHERE created_at < $CUTOFF_TIME;
DELETE FROM transfer WHERE created_at < $CUTOFF_TIME;
REINDEX;
ANALYZE;
VACUUM;
EOF

# 4. 重新启动服务
docker start nezha-dashboard
echo "哪吒探针服务已重启"

# 5. 检查大小并输出结果
OLD_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
NEW_SIZE=$(du -h "$DB_PATH" | cut -f1)

echo "------------------------------------"
echo "维护任务完成！"
echo "原始大小: $OLD_SIZE -> 瘦身后大小: $NEW_SIZE"
echo "------------------------------------"

# === 自动添加定时任务逻辑 ===
echo "正在检查定时任务设置..."

# 检查 crontab 中是否已经存在本脚本的任务
CRON_EXIST=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH")

if [ -z "$CRON_EXIST" ]; then
    # 如果不存在，则追加一条：每周一凌晨 3:00 执行
    (crontab -l 2>/dev/null; echo "0 3 * * 1 /bin/bash $SCRIPT_PATH > /dev/null 2>&1") | crontab -
    echo "成功：已自动添加每周一凌晨 3:00 的定时清理任务。"
else
    echo "提示：定时任务已存在，无需重复添加。"
fi

echo "脚本运行完毕，你可以放心关闭窗口了。"
