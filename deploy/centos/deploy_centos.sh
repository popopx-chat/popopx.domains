#!/usr/bin/env bash
#
# POPOPX · domains.popopx.chat — CentOS / RHEL 一键部署
#
#   sudo ./deploy/centos/deploy_centos.sh --email ops@example.com --yes
#
# 行为：按白名单暂存静态文件 → 预检 → 安装 nginx/rsync/certbot → 同步到 Web 根
# → 申请/复用 Let's Encrypt 证书 → 下发严格 CSP 的 HTTPS vhost → SELinux/firewalld。
#
# 默认值：
#   域名      domains.popopx.chat
#   Web 根    /var/www/domains.popopx.chat
#   配置      /etc/nginx/conf.d/domains.popopx.chat.conf
#
set -Eeuo pipefail
umask 022

SITE_HOST="domains.popopx.chat"
WEB_ROOT=""
NGINX_CONF=""
SOURCE_DIR=""
CERT_EMAIL=""
ASSUME_YES=0
CHECK_ONLY=0
DRY_RUN=0
NO_CERTBOT=0
KEEP_STAGE=0
FAILURES=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '  %sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { printf '%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法: deploy_centos.sh [选项]

  --email <addr>     Let's Encrypt 账户与到期通知邮箱（首次签发必需）
  -y, --yes          非交互确认
  --check            只读检查系统、工具、源码、DNS、端口与已有证书
  --dry-run          构建暂存目录并打印 nginx 配置，不改动系统
  --source <dir>     站点源码目录（默认：本脚本所在仓库根目录）
  --host <name>      站点域名（默认：domains.popopx.chat）
  --web-root <dir>   Web 根目录（默认：/var/www/<host>）
  --no-certbot       跳过证书签发/续期；无可用证书时仅配置 HTTP 站点
  -h, --help         显示本帮助

示例:
  sudo ./deploy/centos/deploy_centos.sh --check
  sudo ./deploy/centos/deploy_centos.sh --email ops@popopx.chat --yes

发布白名单：index.html favicon.ico apple-touch-icon.png robots.txt
            assets/ img/ fonts/Manrope/
README.md、deploy/ 与 fonts/GT-Walsheim/ 不会进入 Web 根目录。
USAGE
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --email)
      (($# >= 2)) || die "--email 需要一个参数"
      CERT_EMAIL="$2"
      shift 2
      ;;
    --email=*)
      CERT_EMAIL="${1#*=}"
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      KEEP_STAGE=1
      shift
      ;;
    --source)
      (($# >= 2)) || die "--source 需要一个参数"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --host)
      (($# >= 2)) || die "--host 需要一个参数"
      SITE_HOST="$2"
      shift 2
      ;;
    --web-root)
      (($# >= 2)) || die "--web-root 需要一个参数"
      WEB_ROOT="$2"
      shift 2
      ;;
    --no-certbot)
      NO_CERTBOT=1
      shift
      ;;
    *)
      die "未知参数: $1（--help 查看用法）"
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$SOURCE_DIR" ]]; then
  SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
else
  [[ -d "$SOURCE_DIR" ]] || die "--source 目录不存在: $SOURCE_DIR"
  SOURCE_DIR="$(cd -- "$SOURCE_DIR" && pwd -P)"
fi
if [[ -z "$WEB_ROOT" ]]; then
  WEB_ROOT="/var/www/${SITE_HOST}"
fi
if [[ -z "$NGINX_CONF" ]]; then
  NGINX_CONF="/etc/nginx/conf.d/${SITE_HOST}.conf"
fi
LE_LIVE="/etc/letsencrypt/live/${SITE_HOST}"

[[ "$SITE_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
  || die "域名格式无效: $SITE_HOST"
[[ "$WEB_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || die "Web 根目录必须是绝对路径且只含 [A-Za-z0-9._/-]: $WEB_ROOT"
case "$WEB_ROOT" in
  *..*) die "Web 根目录不得包含 ..: $WEB_ROOT" ;;
esac
if [[ -n "$CERT_EMAIL" && ! "$CERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  die "邮箱格式无效: $CERT_EMAIL"
fi

PUBLISH_PATHS=(
  "index.html"
  "favicon.ico"
  "apple-touch-icon.png"
  "robots.txt"
  "assets"
  "img"
  "fonts/Manrope"
)

STAGE=""
WORK_DIR=""
BACKUP_CONF=""
cleanup() {
  if [[ -n "$BACKUP_CONF" && -f "$BACKUP_CONF" ]]; then
    rm -f -- "$BACKUP_CONF"
  fi
  if ((KEEP_STAGE == 0)) && [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

stage_site() {
  local p dest
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/popopx-domains.XXXXXX")"
  STAGE="${WORK_DIR}/site"
  mkdir -p -- "$STAGE"
  for p in "${PUBLISH_PATHS[@]}"; do
    [[ -e "${SOURCE_DIR}/${p}" ]] || die "源码缺少: ${p}"
    dest="${STAGE}/${p}"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -R -- "${SOURCE_DIR}/${p}" "$dest"
  done
}

scan_stage() {
  local hits

  hits="$(grep -RIlEi 'simplex|wefunder|list-manage|mailchimp' "$STAGE" --binary-files=without-match || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "暂存目录中发现上游品牌字符串"
  fi
  ok "无上游品牌字符串"

  hits="$(grep -REn "<(script|img|iframe|source|video|audio|track|embed|object)[^>]+src=[\"']?(https?:)?//" --include='*.html' "$STAGE" || true)"
  hits+="$(grep -REn "<link[^>]*stylesheet[^>]*href=[\"']?https?://" --include='*.html' "$STAGE" || true)"
  hits+="$(grep -REn "<link[^>]*rel=[\"']?(preconnect|dns-prefetch|preload|prefetch)" --include='*.html' "$STAGE" || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "页面存在外部资源引用"
  fi
  hits="$(grep -REn "url\\([\"']?(https?:)?//|@import" --include='*.css' "$STAGE" || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "样式表存在外部资源引用或 @import"
  fi
  ok "无外部资源引用"

  if grep -REn '<style' --include='*.html' "$STAGE" >/dev/null; then
    die "发现内联 <style>，与 default-src 'self' CSP 冲突"
  fi
  if grep -RInE '<script([[:space:]][^>]*)?>' --include='*.html' "$STAGE" | grep -vE '<script[^>]+src=' >/dev/null; then
    die "发现内联 <script>，与 CSP 冲突"
  fi
  if grep -REn "[[:space:]]style=" --include='*.html' --include='*.svg' "$STAGE" >/dev/null; then
    die "发现 style= 属性，与 CSP 冲突"
  fi
  if grep -REn 'javascript:' --include='*.html' "$STAGE" >/dev/null; then
    die "发现 javascript: URL"
  fi
  ok "无内联脚本/样式/style= 属性"
}

# ---------------------------------------------------------------------------
# nginx 配置模板
# ---------------------------------------------------------------------------

IPV6_LISTEN_HTTP=""
IPV6_LISTEN_HTTPS=""
if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] \
  && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "0" ]]; then
  IPV6_LISTEN_HTTP="    listen [::]:80;"
  IPV6_LISTEN_HTTPS="    listen [::]:443 ssl http2;"
fi
CACHE_ZONE="SSL_${SITE_HOST//./_}"

render_http_conf() {
  sed -e "s|__SITE_HOST__|${SITE_HOST}|g" \
      -e "s|__WEB_ROOT__|${WEB_ROOT}|g" \
      -e "s|__IPV6_LISTEN__|${IPV6_LISTEN_HTTP}|g" <<'NGINX'
# Managed by popopx.domains deploy/centos/deploy_centos.sh
# phase: http (ACME bootstrap + plain site)

server {
    listen 80;
__IPV6_LISTEN__
    server_name __SITE_HOST__;

    root __WEB_ROOT__;
    index index.html;
    charset utf-8;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
}

render_https_conf() {
  sed -e "s|__SITE_HOST__|${SITE_HOST}|g" \
      -e "s|__WEB_ROOT__|${WEB_ROOT}|g" \
      -e "s|__LE_LIVE__|${LE_LIVE}|g" \
      -e "s|__CACHE_ZONE__|${CACHE_ZONE}|g" \
      -e "s|__IPV6_80__|${IPV6_LISTEN_HTTP}|g" \
      -e "s|__IPV6_443__|${IPV6_LISTEN_HTTPS}|g" <<'NGINX'
# Managed by popopx.domains deploy/centos/deploy_centos.sh
# Host: __SITE_HOST__

map $sent_http_content_type $popopx_cache_control {
    default                   "no-cache";
    ~*^text/css               "public, max-age=604800";
    ~*^application/javascript "public, max-age=604800";
    ~*^text/javascript        "public, max-age=604800";
    ~*^font/                  "public, max-age=2592000";
    ~*^image/                 "public, max-age=2592000";
}

server {
    listen 80;
__IPV6_80__
    server_name __SITE_HOST__;

    root __WEB_ROOT__;
    charset utf-8;

    location /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files $uri =404;
    }

    location / {
        return 301 https://__SITE_HOST__$request_uri;
    }
}

server {
    listen 443 ssl http2;
__IPV6_443__
    server_name __SITE_HOST__;

    root __WEB_ROOT__;
    index index.html;
    charset utf-8;
    server_tokens off;
    autoindex off;

    ssl_certificate     __LE_LIVE__/fullchain.pem;
    ssl_certificate_key __LE_LIVE__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:__CACHE_ZONE__:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'none'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; manifest-src 'self'; worker-src 'none'; upgrade-insecure-requests" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;
    add_header Cache-Control $popopx_cache_control always;

    location ~* \.ttf$ {
        types { }
        default_type font/ttf;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
}

# ---------------------------------------------------------------------------
# 主机检查
# ---------------------------------------------------------------------------

OS_NAME="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-${ID:-unknown}}"
elif command -v sw_vers >/dev/null 2>&1; then
  OS_NAME="$(sw_vers -productName) $(sw_vers -productVersion)"
fi

detect_pm() {
  if command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  fi
}

PM="$(detect_pm)"

resolve_ips() {
  local out=""
  if command -v getent >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$SITE_HOST" 2>/dev/null | awk '{print $1}' | sort -u)" || true
  elif command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$SITE_HOST" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u)" || true
  fi
  printf '%s' "$out"
}

cert_state() {
  local cert="${LE_LIVE}/fullchain.pem"
  [[ -f "$cert" && -f "${LE_LIVE}/privkey.pem" ]] || return 1
  if ! openssl x509 -checkend 604800 -noout -in "$cert" >/dev/null 2>&1; then
    return 2
  fi
  openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2
}

port80_listener() {
  local out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -lntp 2>/dev/null | awk 'NR > 1 && $4 ~ /:80$/ {print $4" "$6; exit}')" || true
  elif command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1" "$2; exit}')" || true
  fi
  printf '%s' "$out"
}

run_checks() {
  info "主机"
  ok "系统: ${OS_NAME}"
  if [[ "$(uname -s)" != "Linux" ]]; then
    fail "当前不是 Linux，正式部署需在 CentOS/RHEL 上执行"
  fi
  if ((EUID == 0)); then
    ok "当前用户: root"
  else
    warn "当前非 root；正式部署需要 sudo"
  fi
  if [[ -n "$PM" ]]; then
    ok "包管理器: $PM"
  else
    fail "未找到 dnf / yum，无法安装 nginx 与 certbot"
  fi

  info "工具"
  if command -v nginx >/dev/null 2>&1; then
    ok "nginx: $(nginx -v 2>&1 | sed 's/^nginx version: //')"
  else
    warn "nginx 未安装，部署时将通过 ${PM:-包管理器} 安装"
  fi
  if command -v rsync >/dev/null 2>&1; then
    ok "rsync: $(rsync --version 2>/dev/null | head -n1 | awk '{print $3}')"
  else
    warn "rsync 未安装，部署时将安装"
  fi
  if command -v certbot >/dev/null 2>&1; then
    ok "certbot: $(certbot --version 2>&1 | awk '{print $2}')"
  elif ((NO_CERTBOT == 0)); then
    warn "certbot 未安装，部署时将安装（必要时启用 EPEL）"
  fi

  info "证书"
  local cert_end cert_rc=0
  cert_end="$(cert_state)" || cert_rc=$?
  if ((cert_rc == 0)); then
    ok "可用证书，到期时间: ${cert_end}"
  elif ((cert_rc == 2)); then
    warn "证书存在但将在 7 天内到期，部署时会尝试续期"
  elif ((NO_CERTBOT)); then
    warn "无可用证书，且指定了 --no-certbot；部署后仅提供 HTTP"
  else
    warn "无可用证书，将申请 Let's Encrypt 证书"
  fi

  info "DNS"
  local ips local_ips matched=0 ip
  ips="$(resolve_ips)"
  if [[ -z "$ips" ]]; then
    if ((NO_CERTBOT)); then
      warn "${SITE_HOST} 无 A 记录；--no-certbot 模式下仍可用 IP/Host 访问"
    else
      fail "${SITE_HOST} 无 A 记录，Let's Encrypt HTTP-01 将失败"
    fi
  else
    ok "${SITE_HOST} → $(printf '%s' "$ips" | tr '\n' ' ')"
    local_ips="$(hostname -I 2>/dev/null || true)"
    if [[ -n "$local_ips" ]]; then
      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ " $local_ips " == *" $ip "* ]]; then
          matched=1
        fi
      done <<< "$ips"
      if ((matched == 0)); then
        warn "DNS 未指向本机地址（本机: $(printf '%s' "$local_ips" | tr '\n' ' ')）；若经 NAT/代理请确认 80 端口可达"
      fi
    fi
  fi

  info "端口与现有配置"
  local listener
  listener="$(port80_listener)"
  if [[ -n "$listener" ]]; then
    ok "80 端口监听: ${listener}"
  else
    warn "80 端口当前无监听（nginx 启动后由本脚本接管）"
  fi
  if [[ -f "$NGINX_CONF" ]]; then
    warn "已存在 ${NGINX_CONF}，部署前会备份并在 nginx -t 失败时回滚"
  else
    ok "无同名 vhost: ${NGINX_CONF}"
  fi
  local dup
  dup="$(grep -RlsE "server_name[^;]*[[:space:]]${SITE_HOST//./\\.}([[:space:];]|$)" \
    /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null \
    | grep -vxF "$NGINX_CONF" || true)"
  if [[ -n "$dup" ]]; then
    warn "其他 vhost 也声明了 ${SITE_HOST}，nginx 将按 include 顺序取第一个: $(printf '%s' "$dup" | tr '\n' ' ')"
  fi
  if [[ -d /etc/nginx/conf.d ]] || ((EUID != 0)); then
    ok "配置目录: /etc/nginx/conf.d"
  else
    fail "/etc/nginx/conf.d 不存在，nginx 可能未正确安装"
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

info "源码"
stage_site
FILE_COUNT="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
ok "暂存 ${FILE_COUNT} 个文件: ${STAGE}"
scan_stage

if ((CHECK_ONLY)); then
  run_checks
  echo
  if ((FAILURES > 0)); then
    die "检查完成：${FAILURES} 项未通过"
  fi
  ok "检查完成：全部通过（主机侧 nginx -t 与证书签发需在实际 CentOS 主机验证）"
  exit 0
fi

render_http_conf > "${WORK_DIR}/http.conf"
render_https_conf > "${WORK_DIR}/https.conf"

if ((DRY_RUN)); then
  info "暂存内容"
  find "$STAGE" -type f | sed "s|^${STAGE}/||" | sort
  info "将写入 ${NGINX_CONF}（以下为最终 HTTPS 配置）"
  cat "${WORK_DIR}/https.conf"
  echo
  ok "dry-run 完成：未改动系统；工作目录保留在 ${WORK_DIR}"
  exit 0
fi

[[ "$(uname -s)" == "Linux" ]] || die "正式部署仅支持 CentOS/RHEL（当前: $(uname -s)）"
((EUID == 0)) || die "需要 root 权限，请使用 sudo"
[[ -n "$PM" ]] || die "未找到 dnf / yum"

pkg_install() {
  if "$PM" install -y "$@"; then
    return 0
  fi
  warn "安装 $* 失败，尝试启用 EPEL 后重试"
  "$PM" install -y epel-release || true
  "$PM" install -y "$@"
}

info "依赖"
if ! command -v nginx >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
  pkg_install nginx rsync
else
  ok "nginx 与 rsync 已安装"
fi

NEED_CERT=0
if ! cert_state >/dev/null; then
  if ((NO_CERTBOT == 0)); then
    NEED_CERT=1
  fi
fi
if ((NEED_CERT)); then
  if ! command -v certbot >/dev/null 2>&1; then
    pkg_install certbot
  fi
  if [[ -z "$CERT_EMAIL" ]]; then
    if ((ASSUME_YES)); then
      die "首次签发需要 --email <addr>"
    fi
    read -r -p "Let's Encrypt 邮箱: " CERT_EMAIL || die "无法读取邮箱"
    [[ -n "$CERT_EMAIL" ]] || die "邮箱不能为空"
  fi
fi

info "发布静态文件"
install -d -m 0755 -- "$WEB_ROOT"
rsync -a --delete -- "${STAGE}/" "${WEB_ROOT}/"
chmod -R a+rX "$WEB_ROOT"
ok "已同步到 ${WEB_ROOT}（--delete 保证与白名单一致）"

info "nginx"
systemctl enable nginx >/dev/null 2>&1 || true
if ! systemctl is-active --quiet nginx; then
  systemctl start nginx
fi
ok "nginx 运行中"

if [[ -f "$NGINX_CONF" ]]; then
  BACKUP_CONF="$(mktemp)"
  cp -a -- "$NGINX_CONF" "$BACKUP_CONF"
  ok "已备份现有配置: ${NGINX_CONF}"
fi

apply_conf() {
  local src="$1" phase="$2"
  install -m 0644 -- "$src" "$NGINX_CONF"
  if ! nginx -t; then
    if [[ -n "$BACKUP_CONF" && -f "$BACKUP_CONF" ]]; then
      cp -a -- "$BACKUP_CONF" "$NGINX_CONF"
    else
      rm -f -- "$NGINX_CONF"
    fi
    systemctl reload nginx >/dev/null 2>&1 || true
    die "nginx -t 未通过，已回滚（phase: ${phase}）"
  fi
  systemctl reload nginx
  ok "nginx 已加载（phase: ${phase}）"
}

apply_conf "${WORK_DIR}/http.conf" "http"

if ! cert_state >/dev/null; then
  if ((NO_CERTBOT)); then
    warn "无可用证书且指定了 --no-certbot：站点仅通过 HTTP 提供"
    info "完成"
    ok "HTTP 站点: http://${SITE_HOST}/"
    exit 0
  fi
  info "签发证书"
  certbot certonly --webroot -w "$WEB_ROOT" -d "$SITE_HOST" \
    --non-interactive --agree-tos --email "$CERT_EMAIL" --keep-until-expiring
fi

if ! cert_state >/dev/null; then
  die "证书不可用；查看 /var/log/letsencrypt/letsencrypt.log，站点暂以 HTTP 提供"
fi
ok "证书就绪"

apply_conf "${WORK_DIR}/https.conf" "https"

info "系统收尾"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$WEB_ROOT"
    ok "SELinux 上下文已恢复"
  else
    warn "SELinux 已启用但缺少 restorecon"
  fi
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
  ok "firewalld 已放行 80/443"
fi

info "验收"
code="$(curl -sS --noproxy '*' --resolve "${SITE_HOST}:443:127.0.0.1" \
  -o /dev/null -w '%{http_code}' "https://${SITE_HOST}/" 2>/dev/null || true)"
if [[ "$code" == "200" ]]; then
  ok "本机 HTTPS 校验通过: 200"
else
  warn "本机 HTTPS 校验返回: ${code:-失败}（检查 nginx 日志与证书）"
fi

echo
ok "部署完成: https://${SITE_HOST}/"
printf '%s后续建议:%s\n' "$C_DIM" "$C_RESET"
printf '  1. curl -sI https://%s/ | grep -iE "content-security-policy|strict-transport-security|x-content-type-options|referrer-policy"\n' "$SITE_HOST"
printf '  2. certbot renew --dry-run\n'
printf '  3. 公网访问 https://%s/ 确认证书链与 320px 布局\n' "$SITE_HOST"