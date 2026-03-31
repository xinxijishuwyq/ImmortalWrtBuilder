#!/bin/sh
# 为 auto_update_from_actions.sh 安装/更新 crontab 任务（OpenWrt busybox crond）
# 用法:
#   SCRIPT_PATH=/root/auto_update_from_actions.sh \
#   CRON_EXPR='0 */6 * * *' LOG_FILE=/tmp/auto-update.log ./setup_auto_update_cron.sh

set -eu

SCRIPT_PATH="${SCRIPT_PATH:-/root/auto_update_from_actions.sh}"
CRON_EXPR="${CRON_EXPR:-0 */6 * * *}"
LOG_FILE="${LOG_FILE:-/tmp/auto-update.log}"

if [ ! -x "$SCRIPT_PATH" ]; then
  echo "脚本不存在或不可执行: $SCRIPT_PATH" >&2
  exit 1
fi

CRON_LINE="$CRON_EXPR $SCRIPT_PATH >>$LOG_FILE 2>&1"

TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -F -v "$SCRIPT_PATH" > "$TMP_CRON" || true
printf '%s\n' "$CRON_LINE" >> "$TMP_CRON"
crontab "$TMP_CRON"
rm -f "$TMP_CRON"

/etc/init.d/cron restart >/dev/null 2>&1 || true

echo "已写入 crontab:"
echo "  $CRON_LINE"
echo "当前任务列表:"
crontab -l
