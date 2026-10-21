#!/bin/bash
# SSL证书自动续期脚本
# 建议cron: 0 3 * * *  (每天凌晨3点检查)
# 证书剩余<30天才会实际续期

set -e

CERT_NAME="a.gzresources.com"
WEBROOT_PATH="/data/dockerapp/dify/dify/docker/nginx/html"
LOG_FILE="/var/log/letsencrypt/renew-ssl.log"
NGINX_CONTAINER="nginx_default"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_notify() {
    local msg="$1"
    # 飞书webhook通知 (替换为实际的webhook地址)
    local webhook="https://open.feishu.cn/open-apis/bot/v2/hook/xxx"
    curl -s -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"[SSL续期] $msg\"}}" 2>/dev/null || true
}

# ========== 主流程 ==========
log "=== 开始SSL证书检查 ==="

# 1. 检查证书过期时间
EXP_DATE=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem 2>/dev/null | cut -d= -f2)
DAYS_LEFT=$(($(date -d "$EXP_DATE" +%s) / 86400 - $(date +%s) / 86400))
log "证书到期: $EXP_DATE (剩余 $DAYS_LEFT 天)"

if [ "$DAYS_LEFT" -gt 30 ]; then
    log "证书剩余>30天，无需续期，退出"
    exit 0
fi

log "证书剩余≤30天，开始续期..."

# 2. 执行续期 (force-renewal跳过随机延迟)
RENEW_OUTPUT=$(certbot renew --force-renewal --cert-name "$CERT_NAME" \
    --webroot --webroot-path "$WEBROOT_PATH" \
    --no-random-sleep 2>&1) && RENEW_STATUS=0 || RENEW_STATUS=$?

log "续期输出: $RENEW_OUTPUT"

if [ $RENEW_STATUS -eq 0 ] && echo "$RENEW_OUTPUT" | grep -q "success"; then
    # 3. 验证新证书
    NEW_EXP=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem | cut -d= -f2)
    log "新证书到期: $NEW_EXP"

    # 4. 重载nginx
    if docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null; then
        log "✅ Nginx重载成功"
        send_notify "✅ SSL证书续期成功，到期: $NEW_EXP"
    else
        log "⚠️ Nginx重载失败，尝试重启容器"
        docker restart "$NGINX_CONTAINER" 2>/dev/null && log "✅ Nginx容器重启成功" || log "❌ Nginx容器重启失败"
        send_notify "⚠️ SSL续期成功但Nginx重启失败，请检查!"
    fi
else
    log "❌ 续期失败: $RENEW_OUTPUT"
    send_notify "❌ SSL证书续期失败，请检查!\n$RENEW_OUTPUT"
    exit 1
fi

log "=== SSL证书检查完成 ==="
