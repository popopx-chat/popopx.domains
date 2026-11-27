# POPOPX · domains.popopx.chat

POPOPX 官方域名安全公示与全生态导航站。单页静态站点：零构建、零 Cookie、零外部请求，用于告知用户如何核验 POPOPX 官方域名、识别钓鱼假冒站点，并列出全部官方入口。

- 站点：`https://domains.popopx.chat/`（该主机尚无 A 记录，部署前须先解析，见「部署」）
- 源码：`https://github.com/popopx-chat/popopx.domains`
- 最后核验：2026-11-27

## 官方域名清单

| # | 域名 | 用途 | 状态（2026-11-27） |
|---|---|---|---|
| 01 | `popopx.chat` | 旗舰主站与 `/i/v1/` 隐私邀请落地页 | 在线 |
| 02 | `node.popopx.chat` | Mac Node 边缘智能中枢与桌面端下载 | 在线 |
| 03 | `mp.popopx.chat` | Service Suite 企业服务号与零知识频道套件 | 在线 |
| 04 | `bot.popopx.chat` | Bot Studio 自托管机器人工作台 | 在线 |
| 05 | `status.popopx.chat` | 基础设施实时运行状态监控 | 筹备中（无 DNS 记录） |
| 06 | `domains.popopx.chat` | 官方域名安全公示页（本页） | 待上线（无 DNS 记录） |
| 07 | `smp1.popopx.im` | 官方加密消息中继（SMP Relay）；`smp2`–`smp8` 同域提供同一服务 | 在线 |
| 08 | `bpay.popopx.im` | 非托管 BTCPay 闪电网络支付机器人 | 在线（登录保护） |
| 09 | `github.com/popopx-chat` | 官方开源代码与签名公证版本发布源 | 在线 |

清单之外的地址一律视为非官方，包括拼写相近、连字符变体、其他顶级域与「备用入口」。`popopx.im` 只承载中继与支付节点，裸域不提供网页服务。

## 核验方法

任选一种，确认完整主机名与证书 SAN 一致：

```bash
dig +short A popopx.chat
# 2026-11-27 实测：43.129.40.33

printf '' | openssl s_client -connect popopx.chat:443 -servername popopx.chat 2>/dev/null \
  | openssl x509 -noout -subject -dates -text | grep -A1 "Subject Alternative Name"
# 2026-11-27 实测：subject= /CN=popopx.chat
# SAN: DNS:popopx.chat, DNS:www.popopx.chat
# 签发：Let's Encrypt，有效期 2026-11-13 → 2027-02-11
```

macOS 自带的 LibreSSL 不支持 `x509 -ext`，因此上面用 `-text | grep` 取 SAN。

浏览器侧：点击地址栏锁形图标，确认证书由受信任机构签发，且 SAN 包含你正在访问的完整主机名；地址栏出现 `xn--` 前缀或证书不匹配时立即关闭。

## 页面约束

- **零外部请求**：整页只有 8 个请求，全部同源——1 个 HTML、`assets/site.css`、`assets/theme.js`、`assets/site.js`、`img/popopx-mark.svg`，以及 Manrope 400/600/800 三个 TTF。无统计、无追踪像素、无 CDN。
- **严格 CSP 兼容**：无内联 `<style>`、无内联 `<script>`、无 `style=""` 属性，服务器以 `default-src 'self'` 下发 CSP。
- **零追踪存储**：不使用 Cookie；`localStorage` 只保存明暗主题偏好。
- **字体自托管**：`fonts/Manrope/`（SIL OFL 1.1，许可证见 `fonts/Manrope/OFL.txt`），中文回退系统字体。
- **不发布非自由字体**：`fonts/GT-Walsheim/` 为上游遗留的商用字体，许可证不允许再分发（见该目录内 README）。它保留在源码仓库中，但不在页面引用，也不在部署白名单内。
- **无构建步骤**：直接编辑 `index.html` / `assets/` 即可；`favicon.ico` 与 `apple-touch-icon.png` 由 `img/popopx-mark.svg` 预渲染（Chrome headless 512px → `sips` 缩放，ICO 为 16/32/48/64 四尺寸封装）。

## 目录结构

```
index.html                 单页站点
assets/site.css            样式（Manrope @font-face、明暗主题变量）
assets/theme.js            绘制前确定主题（避免闪烁）
assets/site.js             主题切换与系统偏好跟随
img/popopx-mark.svg        POPOPX 矢量标记
favicon.ico                16/32/48/64
apple-touch-icon.png       180×180 全出血方形
robots.txt
fonts/Manrope/             7 个 TTF + OFL.txt
fonts/GT-Walsheim/         非自由字体，不发布
deploy/centos/deploy_centos.sh
```

## 本地预览

```bash
cd popopx.domains
python3 -m http.server 8971 --bind 127.0.0.1
# 打开 http://127.0.0.1:8971/
```

请通过 HTTP 预览，不要用 `file://` 直接打开：`@font-face` 与 CSP 的行为在 `file://` 下不可靠。

## 部署到 CentOS

前置条件：

1. `domains.popopx.chat` 的 A/AAAA 记录已指向本机公网 IP；80/443 对公网可达（Let's Encrypt 走 HTTP-01）。
2. root 权限（或 `sudo`）。
3. CentOS 7+/RHEL 兼容系统，具备 `dnf` 或 `yum`；首次签发需要 `certbot`（脚本会从 EPEL 安装）。

```bash
cd popopx.domains

# 只读检查：系统、工具、源码、DNS、端口、已有证书
sudo ./deploy/centos/deploy_centos.sh --check

# 生成静态目录与 nginx 配置到临时目录并打印，不改动系统
./deploy/centos/deploy_centos.sh --dry-run

# 正式部署（首次签发需 --email）
sudo ./deploy/centos/deploy_centos.sh --email ops@example.com --yes
```

| 参数 | 说明 |
|---|---|
| `--email <addr>` | Let's Encrypt 账户与到期通知；首次签发必需 |
| `-y`, `--yes` | 非交互确认 |
| `--check` | 只读检查，不写任何文件 |
| `--dry-run` | 构建暂存目录并输出配置，不改动系统 |
| `--source <dir>` | 站点源码目录，默认仓库根目录 |
| `--host <name>` | 站点域名，默认 `domains.popopx.chat` |
| `--web-root <dir>` | Web 根目录，默认 `/var/www/<host>` |
| `--no-certbot` | 跳过证书签发，仅生成 HTTP 站点（调试或前置代理场景） |

脚本行为：

1. 按白名单暂存静态文件（`index.html`、`favicon.ico`、`apple-touch-icon.png`、`robots.txt`、`assets/`、`img/`、`fonts/Manrope/`），`README.md`、`deploy/`、`fonts/GT-Walsheim/` 不会进入 Web 根目录。
2. 预检：拒绝暂存目录中出现上游品牌字符串、外部资源加载、内联脚本/样式。
3. 安装 `nginx`、`rsync`；需要时安装 `certbot`。
4. `rsync --delete` 同步到 Web 根目录，保证线上与白名单完全一致。
5. 先写入 HTTP vhost（保留 `/.well-known/acme-challenge/`），`nginx -t` 通过后 reload。
6. 复用未到期证书，或用 `certbot certonly --webroot` 签发。
7. 写入 HTTPS vhost：HTTP→HTTPS 强制跳转、`Content-Security-Policy: default-src 'self'`、`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、HSTS、COOP/CORP、Permissions-Policy。
8. `nginx -t` 失败时回滚到上一份配置并恢复服务。
9. SELinux `restorecon`、firewalld 放行 80/443，最后用本机 `curl` 校验 200 与响应头。

部署后核验：

```bash
curl -sI https://domains.popopx.chat/ \
  | grep -iE 'strict-transport-security|content-security-policy|x-content-type-options|referrer-policy'

printf '' | openssl s_client -connect domains.popopx.chat:443 -servername domains.popopx.chat 2>/dev/null \
  | openssl x509 -noout -subject -dates -text | grep -A1 "Subject Alternative Name"

sudo certbot renew --dry-run
```

## 本次核验记录（2026-11-27）

- `popopx.chat`、`node.popopx.chat`、`mp.popopx.chat`、`bot.popopx.chat`：HTTPS 200，A 记录均为 `43.129.40.33`。
- `smp1.popopx.im`：HTTPS 200，服务器信息页；`smp2`–`smp8`、`relay1.popopx.im` 均可解析。
- `bpay.popopx.im`：302 → `/login`，登录保护。
- `github.com/popopx-chat`：200。
- `status.popopx.chat`：无 A/AAAA/CNAME 记录，因此页面标注「筹备中」且不提供可点击入口。
- `domains.popopx.chat`：无 A 记录，部署前需先解析。
- `popopx.xyz`：解析到与主站相同的 IP，但证书 SAN 不含该域，不属于 POPOPX；页面已将其作为实例提醒。
- 证书：`popopx.chat` 由 Let's Encrypt 签发，SAN 为 `popopx.chat`、`www.popopx.chat`。

## 安全报告

发现仿冒站点或可疑入口，请记录完整 URL 与截图，在 `github.com/popopx-chat` 的对应仓库提交 Issue。本站不通过私聊处理任何安全报告。

## 许可证

页面代码随本仓库发布。字体 Manrope 采用 SIL Open Font License 1.1，全文见 `fonts/Manrope/OFL.txt`。`fonts/GT-Walsheim/` 不在许可证覆盖范围内，且不随站点分发。