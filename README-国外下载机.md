# NAS 下载机 —— 国外服务器 + Mac mini 自动回传

一台**国外服务器**负责下载（qBittorrent / aria2）和网盘挂载（OpenList），
通过**纯 UDP 的 hysteria2 隧道**把文件送到家里的 **Mac mini**；
服务器上的副本保留 24 小时后自动删除。

```
        ┌─────────────── 国外服务器（有公网 IP） ───────────────┐
        │  qBittorrent   aria2   AriaNg   OpenList             │
        │        └──────────┬──────────┘                       │
        │             /opt/nas  （交换目录）                    │
        │                    ▲                                 │
        │        Caddy :443  │ 域名 HTTPS 访问面板              │
        │   hysteria2 服务端 :8443/UDP                          │
        │   cleanup.timer：每 10 分钟删超过 24 小时的文件         │
        └────────────────────┼─────────────────────────────────┘
                             │  UDP/QUIC（hysteria2）
                             │  隧道内再把服务器 22 端口映射到 Mac 的 127.0.0.1:2222
        ┌────────────────────┼─────────────────────────────────┐
        │  Mac mini          ▼                                 │
        │   hysteria2 客户端（launchd 常驻）                     │
        │   pull 任务（launchd，每 300 秒）                      │
        │        └─► scp 增量拉取 → /Volumes/D/Downloads        │
        └──────────────────────────────────────────────────────┘
```

---

## 一、文件说明

| 文件 | 跑在哪 | 说明 |
| --- | --- | --- |
| `nas-server.sh` | **国外服务器** | 一键部署：Docker + qBittorrent + aria2 + AriaNg + OpenList（官方脚本）+ Caddy 自动 HTTPS + hysteria2 服务端 + **自动生成清理脚本与定时器** + sshd 并发调优 |
| `deploy-nas-nl-mac.sh` | **Mac mini** | 一键部署：hysteria2 客户端 + 每 5 分钟增量拉取，两者都注册为 launchd 开机自启 |
| `uninstall-nas-nl-mac.sh` | **Mac mini** | 一键卸载/重置：把 Mac 侧部署的东西全部清除，以便从 0 重新部署。默认不碰国内那套隧道、SSH 密钥和已下载的文件 |
| `nas-server-cleanup.sh` | 国外服务器 | **不需要手动运行**。它由 `nas-server.sh` 自动生成并安装到 `/opt/nas-server/cleanup.sh`，配套 `nas-server-cleanup.timer` 每 10 分钟跑一次。放在这里只为方便查看内容 |

> 与本仓库的 `deploy-nas-tunnel-mac.sh`（Mac ↔ 国内服务器 · OpenList 反代）**完全独立**，
> 两套互不干扰：不同的 launchd 标签（`com.nas.nl.*` vs `com.nas.tunnel.*`）、
> 不同配置目录（`/usr/local/etc/nas-nl/` vs `/usr/local/etc/nas-tunnel/`）、不同端口。
> 唯一共用的是 `/usr/local/bin/hysteria` 这个二进制，因此本套的 `--uninstall` **不会**删除它。

---

## 二、换新机器：完整部署步骤

### 0. 前提（脚本代替不了的四件事）

1. **DNS**：把要用的三个域名的 A 记录指向**新服务器的公网 IP**，并且
   **必须关闭 Cloudflare 橙云代理（用 DNS only）** —— 橙云穿透不了 ACME 挑战，证书签不下来。
   例：`dllist.example.com`、`qb.example.com`、`aria.example.com`
2. **防火墙 / 云安全组**放行：`TCP 22、80、443` 和 `UDP 8443`（8443 可改，见参数）。
3. **服务器能访问外网**：脚本要下载 Docker、OpenList、hysteria2、Caddy。
   国内网络受限时可在运行时指定代理 `-p`（见第三节）。
4. **（仅当落地目录在外置盘时）macOS 授权**：见第 4 步。

系统要求：服务器 Debian 12 / Ubuntu（systemd，x86_64 或 arm64）；Mac mini macOS 12+。

### 1. 部署服务器

```bash
# 在服务器上，用 root
bash nas-server.sh
```

交互会问：交换目录、端口、各服务口令（可回车自动生成强随机值）、
**三个访问域名**、hysteria2 的 UDP 端口与密码、**Mac 的公钥**、清理保留时长。

- Mac 公钥此刻还没有也没关系，**直接回车跳过**，之后可以补（第 3 步给了更省事的办法）。
- 跑完后终端会打印一份汇总：三个域名的 HTTPS 地址、各服务账号密码、
  hysteria2 的地址/端口/密码/SNI —— **把 hysteria2 那几项记下来，第 2 步要用**。

跑完会得到：

| 服务 | 地址 |
| --- | --- |
| OpenList | `https://<你填的 OpenList 域名>` |
| qBittorrent WebUI | `https://<你填的 qb 域名>` |
| AriaNg | `https://<你填的 aria 域名>`（aria2 RPC 走同域 `/jsonrpc`） |
| 交换目录 | `/opt/nas`（qb/aria2 的下载目录，也是 Mac 拉取的源目录） |

### 2. 部署 Mac mini

```bash
# 在 Mac mini 上，用「普通用户」运行（不要 sudo bash）
bash deploy-nas-nl-mac.sh
```

交互会问：荷兰机 IP、hysteria2 UDP 端口、hysteria2 密码、TLS SNI、
本机监听端口（默认 2222）、拉取账号（默认 `nas`）、远端目录（默认 `/opt/nas`）、
落地目录（默认 `/Volumes/D/Downloads`）、间隔（默认 300 秒）、并发（默认 4）。

- 如果这台 Mac **没有 SSH 密钥**，脚本会**自动生成一把**，并打印出一条
  「把公钥装到服务器」的命令 —— 照着执行一次即可（第 3 步）。
- 脚本内部会自己调用 `sudo` 写 `/usr/local` 和 `/Library/LaunchDaemons`，会要求输一次密码。

### 3. 把 Mac 公钥装到服务器（新机器必做）

在 Mac 上执行脚本打印的那一条，形如：

```bash
ssh root@<服务器IP> 'install -d -m700 -o nas -g nas /home/nas/.ssh; \
  touch /home/nas/.ssh/authorized_keys; \
  grep -qF "<你的公钥>" /home/nas/.ssh/authorized_keys || echo "<你的公钥>" >> /home/nas/.ssh/authorized_keys; \
  chown nas:nas /home/nas/.ssh/authorized_keys; chmod 600 /home/nas/.ssh/authorized_keys'
```

或者重跑一次 `nas-server.sh`（幂等），它会把公钥写进 `MIRROR_PUBKEY`。

装完立刻验证：

```bash
bash deploy-nas-nl-mac.sh --self-test     # 四项自检应全绿
bash deploy-nas-nl-mac.sh --pull-now      # 手动拉一次，观察输出
```

### 4. 只在「落地目录在外置盘」时需要：macOS TCC 授权

macOS 会拦截后台任务写入**外置卷**（报 `Operation not permitted`）。
一次性授权即可：

```
系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点 + → 按 Cmd+Shift+G
  → 输入 /bin/bash → 打开 → 在列表里把开关打开
```

> **加完列表里看不到？** 退出「系统设置」再打开就有了（这是 macOS 的刷新问题，不是没加上）。

不想授权也可以把落地目录改到内置盘（内置盘不受此限制）：

```bash
bash deploy-nas-nl-mac.sh --dest "$HOME/NAS"
```

### 5. 验收

```bash
# 服务器
ls -la /opt/nas                                  # 交换目录
systemctl is-active openlist caddy hysteria-server nas-server-cleanup.timer

# Mac
bash deploy-nas-nl-mac.sh --status               # 服务状态 + 远端待拉文件数
tail -f /usr/local/var/log/nas-nl/pull.log       # 拉取日志
```

想手动跑一次完整流程：在服务器 `/opt/nas` 丢一个文件，然后在 Mac 上
`sudo launchctl kickstart -k system/com.nas.nl.pull`，几秒后文件应出现在落地目录。

---

## 三、常用命令

### 服务器（`nas-server.sh`）

```bash
bash nas-server.sh                  # 部署（已部署过则复用配置）
bash nas-server.sh reconfigure      # 重新问答并覆盖配置
bash nas-server.sh status           # 运行状态
bash nas-server.sh ports            # 端口映射表
bash nas-server.sh cleanup          # 立刻清理一次交换目录
bash nas-server.sh macmini          # 打印 Mac 端对接参数
bash nas-server.sh uninstall        # 卸载（保留交换目录数据）
```

### Mac（`deploy-nas-nl-mac.sh`）

```bash
bash deploy-nas-nl-mac.sh                   # 部署
bash deploy-nas-nl-mac.sh --status          # 状态
bash deploy-nas-nl-mac.sh --pull-now        # 立刻拉一次
bash deploy-nas-nl-mac.sh --self-test       # 只跑自检
bash deploy-nas-nl-mac.sh --uninstall       # 卸载（不删共享的 hysteria 二进制）
bash deploy-nas-nl-mac.sh -y --nl-host <IP> --nl-pass <密码> --nl-sni <域名>   # 非交互
```

### Mac 重置（`uninstall-nas-nl-mac.sh`）

遇到问题想**推倒重来**时用这个：它把 Mac 侧部署的东西全部清除，然后重跑
`deploy-nas-nl-mac.sh` 即可从 0 开始。

```bash
bash uninstall-nas-nl-mac.sh --list          # 只读清点：当前装了什么
bash uninstall-nas-nl-mac.sh --dry-run       # 只显示会删什么，不真删
bash uninstall-nas-nl-mac.sh                 # 交互式清理
bash uninstall-nas-nl-mac.sh -y              # 不交互

# 需要时显式扩大范围（各自都会再确认一次）
bash uninstall-nas-nl-mac.sh --purge             # 连落地目录里的文件一起删
bash uninstall-nas-nl-mac.sh --purge-key         # 连 ~/.ssh/id_ed25519 一起删
bash uninstall-nas-nl-mac.sh --purge-hysteria    # 连共用的 hysteria 二进制一起删
```

**默认删**：`com.nas.nl.hysteria`、`com.nas.nl.pull`（含 plist）、
`/usr/local/etc/nas-nl/`、`/usr/local/var/log/nas-nl/`、`/usr/local/bin/nas-nl-pull.sh`、
正在跑的拉取进程。

**默认绝对不动**：`/usr/local/bin/hysteria`（与国内那套共用）、`~/.ssh/id_ed25519`
（你的密钥）、落地目录里的文件、国内那套（`com.nas.tunnel.*`、`/usr/local/etc/nas-tunnel/`）
的任何东西。

> 两个不带走的：macOS「完全磁盘访问权限」里给 `/bin/bash` 的授权不会被清（重新部署后
> 直接可用，不用再授一次）；服务器上拉取账号的 `authorized_keys` 也还在。
> 如果连密钥一起删了（`--purge-key`），脚本会打印一条命令帮你把旧公钥从服务器清掉。

---

## 四、端口一览

| 服务 | 宿主机 | 容器内 | 公网 |
| --- | --- | --- | --- |
| OpenList | `127.0.0.1:5244` | — | 经 Caddy 的 HTTPS |
| qBittorrent WebUI | `127.0.0.1:8080` | 8080 | 经 Caddy 的 HTTPS |
| qBittorrent BT | `0.0.0.0:6881` TCP+UDP | 6881 | 需放行 |
| aria2 RPC | `127.0.0.1:6800` | 6800 | 经 Caddy 的 `/jsonrpc` |
| aria2 BT | `0.0.0.0:6888` TCP+UDP | 6888 | 需放行 |
| AriaNg | `127.0.0.1:8081` | 6880 | 经 Caddy 的 HTTPS |
| hysteria2 | — | — | **UDP 8443** |
| Mac 侧隧道转发 | `127.0.0.1:2222` | — | 仅本机 |

面板只绑 `127.0.0.1` 是刻意的：外部一律走 Caddy 的 HTTPS，避免绕过证书直连。

---

## 五、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 域名返回 502 | 对应的本地服务没起来：`docker ps`、`systemctl status openlist` |
| 证书签不下来 | 域名 A 记录没指向本机，或开了 Cloudflare 橙云；也可能是 80/443 没放行 |
| `--self-test` 里 SSH 失败 | Mac 公钥没装到服务器（第 3 步），或拉取账号/端口填错 |
| 拉取日志 `Operation not permitted` | 外置卷的 TCC 授权没做（第 4 步） |
| 拉取日志 `本地转发端口 2222 未就绪` | hysteria2 客户端没起来：`sudo launchctl print system/com.nas.nl.hysteria` |
| 自检说 `UDP 8443` 连不上 | 云安全组没放行 UDP 8443，或 SNI 与服务器证书域名不一致 |
| 文件只拉了一半 | 正常：下一轮 size 比对不一致会自动重拉 |
| 文件被删了 | 服务器的 24 小时清理策略。改 `RETENTION_MINUTES` 后可调整 |
| `hysteria-server` 起不来，日志报 `tls.cert: stat /etc/nas-server/tls/hy2.crt: permission denied` | `/etc/nas-server` 目录权限是 700，`hysteria` 用户无法穿越。执行 `chmod 711 /etc/nas-server` 再 `systemctl restart hysteria-server`（本仓库脚本已修正为 711） |

---

## 六、性能实测（中国 ↔ 荷兰，真实家宽）

**并发数决定一切**（8 个 25 MiB 文件，两轮实测）：

| 并发数 | 吞吐 |
| --- | --- |
| 4 | 7.1 MiB/s |
| **8（默认）** | **11.9 MiB/s** ← 拐点 |
| 12 | 12.2 MiB/s |
| 16 | 13.1 MiB/s（收益递减，且需抬高服务器 sshd 上限） |

其他实测：

| 场景 | 结果 |
| --- | --- |
| 脚本实际拉取（16 文件 / 400 MiB / 并发 8） | **8.7 MiB/s（约 73 Mbps）**，两轮 45–46s 稳定 |
| 单流（1 个文件） | 2.1–2.9 MiB/s —— 单流是瓶颈，不是隧道 |
| 同链路纯 TCP 直连（不走隧道） | 3.3–4.1 MiB/s —— **并发后隧道比 TCP 还快** |
| 国内线路本身的下载能力 | 16.5 MiB/s（132 Mbps） |

Brutal 声明带宽实测（并发 4）：`50/300` 7.06、`50/100` 7.24、`50/50` 4.68、`600` 5.74、
去掉 bandwidth 走 BBR 只有 6.44 MiB/s。**默认取 `50/100`**（与 300 在噪声内，声明更低、对链路更温和）。

> **为什么单流慢**：跨境 RTT 约 250ms，单个 TCP 流受制于自身窗口；
> 多开几个流就能把带宽抢回来。所以默认并发 8。
> 代价：**单个超大文件**只能单流（约 2.9 MiB/s）——scp 无法把一个文件拆成多流。

**稳定性配套**：`nas-server.sh` 会在 `/etc/ssh/sshd_config.d/99-nas-server.conf`
把 `MaxStartups` 抬到 `100:30:200`、`MaxSessions 64`。
Debian 默认的 `10:30:100` 会在未认证连接超过 10 个时**随机丢弃新连接**，
表现为并发拉取时偶发 `Connection reset by peer`；改动前会 `sshd -t` 校验，失败自动回滚。

---

## 七、可调参数

都在服务器 `/etc/nas-server/nas-server.conf`（权限 600）里，
改完执行 `bash nas-server.sh reconfigure` 生效：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `EXCHANGE` | `/opt/nas` | 交换目录（qb/aria2 都下到这里） |
| `PULL_USER` | `nas` | Mac 拉取用的服务器账号 |
| `RETENTION_MINUTES` | `1440` | 超过这么久没被改动的文件会被删除（1 天） |
| `CLEANUP_INTERVAL` | `10min` | 清理检查频率 |
| `HY2_PORT` | `8443` | hysteria2 的 UDP 端口 |
| `HY2_SNI` | — | 复用的 Caddy 证书域名 |
| `BIND_LOCAL` | `127.0.0.1` | 面板绑定地址 |

Mac 侧参数在 `/usr/local/etc/nas-nl/state.env`，可用命令行覆盖：

```bash
bash deploy-nas-nl-mac.sh --dest <目录> --interval <秒> --parallel <N> \
                          --down-mbps <N> --up-mbps <N>
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--dest` | `/Volumes/D/Downloads` | 本地落地目录 |
| `--interval` | `300` | 拉取间隔（秒） |
| `--parallel` | `8` | 并发传输数（实测拐点，见第六节） |
| `--down-mbps` | `100` | hysteria2 Brutal 声明下行带宽 |
| `--up-mbps` | `50` | hysteria2 Brutal 声明上行带宽 |
| `--nl-host` | 必填 | 服务器公网 IP |
| `--nl-pass` | 必填 | hysteria2 认证密码 |
| `--nl-sni` | 必填 | TLS SNI（证书域名） |

---

## 八、安全说明

- 公网只暴露：`TCP 80/443`（Caddy）、`UDP 8443`（hysteria2）、`TCP 6881/6888`（BT）。
- 面板（OpenList / qBittorrent / AriaNg / aria2 RPC）只绑回环，外部必须走 HTTPS。
- hysteria2：密码认证 + 真实 Let's Encrypt 证书（客户端正常校验证书链，不用 `insecure`）。
- 服务器上的清理脚本只操作交换目录，不会碰其它路径。
- 所有口令由脚本随机生成并存于权限 600 的配置文件，脚本本身不含任何密钥。

---

## 九、版本

| 脚本 | 版本 |
| --- | --- |
| `nas-server.sh` | 1.0.0 |
| `deploy-nas-nl-mac.sh` | 1.0.0 |
| `uninstall-nas-nl-mac.sh` | 1.0.0 |
| `nas-server-cleanup.sh` | 随 `nas-server.sh` 生成 |
