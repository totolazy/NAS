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

### 回传语义（重要）

| 项目 | 值 |
| --- | --- |
| 服务器目录 | `/opt/nas`（Mac 拉取的源目录，容器内挂载为 `/Mac`） |
| Mac 目录 | `/Volumes/D/Downloads` |
| 拉取间隔 | 300 秒 |
| **只拉已下完的** | 四道闸门：跳过后缀 + aria2 控制文件 + 静默 180 秒 + mtime 在未来时放行（`--stable-sec`，设 0 关闭计时器） |

「只拉已下完的」靠四道闸门：

1. **跳过后缀**：`*.!qB`（qBittorrent 的未完成文件）、`*.aria2`（aria2 控制文件）、
   `*.part`、`*.unwanted` 一律不拉。
2. **aria2 控制文件**：aria2 有个好习惯——没下完时一定存在同名 `<文件名>.aria2`，
   下完自动删掉。所以只要 `<文件名>.aria2` 还在，`<文件名>` 就**一定没下完**，直接跳过。
   这条比计时器硬：慢速种子或**暂停中的**任务可能几分钟不写盘，光靠静默阈值会漏。
3. **静默阈值**：正在下载的文件 mtime 一直在变（aria2 / qBittorrent 都是边下边写），
   所以每轮都会被跳过；下载结束后静默 180 秒才进入候选，最多再等一轮（约 5–8 分钟到 Mac）。
4. **mtime 在未来时放行**：第 3 条只对「过去的时间」生效。如果源站给的 `Last-Modified`
   在未来（源站时钟不准），那个文件永远等不到「静默够久」，会被无声地卡住——所以
   `age < 0` 时按已下完处理，直接拉。

> 有个反直觉的细节：aria2 **下载完成后**会把文件 mtime 改回源站的 `Last-Modified`
> （实测下完瞬间 mtime 从「刚刚」跳回几小时前，甚至可能是几个月前），所以「mtime 很旧」
> **不能**证明文件已下完——第 2 条闸门就是专门补这个洞的；而第 4 条补的是它的反面。

> 没有这些闸门会怎样：下载中的文件每 5 分钟被**整个重拉一遍**（一个 20 GB 的种子下 10 小时
> 可能白拉几百 GB），而且 `.!qB` 半成品会永久堆在 Mac 上。

### 容器里的挂载点（重要）

| 宿主机 | 容器内 | 谁在用 |
| --- | --- | --- |
| `/opt/openlist/data/temp` | `/downloads` | qBittorrent / aria2 的**默认**下载目录（它们的配置保持原样） |
| `/opt/openlist/data/temp` | `/opt/openlist/data/temp` | 同一条路径再挂一次，**OpenList 的「离线下载」靠它才能工作** |
| `/opt/nas` | `/Mac` | 专门挂给 Mac mini 的目录，Mac 每 5 分钟从这里拉 |

**为什么要把同一个目录挂两次？** OpenList 是以「宿主机视角」工作的：它把任务交给下载器时，
传过去的是它自己算出来的绝对路径，形如

```
/opt/openlist/data/temp/qBittorrent/<任务ID>/xxx.mkv
```

qBittorrent 跑在容器里，那个路径对它必须真实存在，否则它会去尝试创建 `/opt/...` —— 以
`PUID`（1000）身份创建根目录下的路径必然失败，日志里就是：

```
文件错误警报 ... 原因: file_open (/opt/openlist/data/temp/qBittorrent/<任务ID>/xxx.mkv) error: Permission denied
```

所以容器里必须同时有 `/downloads`（下载器的默认值）和同名的 `/opt/openlist/data/temp`。
**这也是 OpenList + Docker 下载器的通用要求：路径里外必须一致。**

**「下到 Mac」怎么操作**：在 qBittorrent 或 aria2 里把这一次的保存路径选成 `/Mac`
（qB：新建一个分类、保存路径填 `/Mac`；aria2：`--dir=/Mac`，或在 AriaNg 里把目录填 `/Mac`）。
留在默认 `/downloads` 的文件只会留在 OpenList 的临时目录里，Mac **不会**去拉它。

部署时脚本会处理三个坑，都已修好：

1. **属主**。挂载源不存在时 Docker 会自动建一个 `root:root` 的目录，而下载器以 `PUID`
   （默认 1000）运行，写不进去 —— 现象是「下载完成但文件不见」。脚本会 `mkdir -p` 并把属主/
   权限设成 `1000:1000` / `2775`（OpenList 自己的数据目录仍保持 `700`）。
2. **权限（OpenList 建的子目录）**。OpenList 以 root 运行，它会先建好
   `<temp>/qBittorrent/<任务ID>` 再把路径交给下载器；root 建的目录默认 `755`，下载器进不去，
   于是又报 `Permission denied`。脚本给 `/opt/openlist/data/temp` 挂了一条**默认 ACL**：

   ```
   setfacl -m u:1000:rwx -m d:u:1000:rwx -m d:g:1000:rwx /opt/openlist/data/temp
   ```

   之后 root 新建的子目录会自动带上 uid 1000 的写权限，**不必把下载器改成 root 运行**。
3. **部署顺序**。OpenList 官方安装脚本遇到「已存在的安装目录」会先 `rm -rf` 再恢复 `data/`；
   如果它在挂载之后重建目录，运行中的容器会绑到一个**已被删除的旧 inode**：文件照样写进去，
   宿主机上却再也找不到。所以脚本改成：① 下载器放在 OpenList **之后**部署；
   ② OpenList 已安装就跳过重装（要升级手动跑官方脚本的 `update`）。

部署完脚本会自己复核，日志里应看到：

```
[  OK  ] 已给 /opt/openlist/data/temp 加默认 ACL（新建子目录自动允许 uid 1000 写入）
[  OK  ] 下载目录就绪：/opt/openlist/data/temp（容器内 /downloads 与 /opt/openlist/data/temp，属主 1000:1000）
[  OK  ] aria2 生效的下载目录：/downloads
```

qBittorrent 那行需要脚本能登进面板才会显示。如果你自己在面板里改过密码，
这里会提示「口令校验未通过」——不影响使用，面板「设置 → 下载 → 默认保存路径」
显示 `/downloads` 就对了。

> 提醒：`/downloads` 用的是 OpenList 的**临时**目录，定位就是中转，OpenList 完成后可能自行
> 清理。需要留档的文件请放到 `/Mac`（= `/opt/nas`），那边由服务器的 24 小时清理策略统一管理。

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
| 交换目录 | `/opt/nas`（Mac 拉取的源目录，容器内挂载为 `/Mac`） |

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
bash deploy-nas-nl-mac.sh --status               # 服务状态 + 端口监听 + 远端待拉文件数
tail -f /usr/local/var/log/nas-nl/pull.log       # 拉取日志
```

想手动跑一次完整流程：在服务器 `/opt/nas` 丢一个文件，然后在 Mac 上
`sudo launchctl kickstart -k system/com.nas.nl.pull`，几秒后文件应出现在落地目录。

---

### 6. 线路丢包时打不开面板怎么办

跨境 TCP 一旦丢包，速度会断崖式下跌（实测 30% 丢包 → 40 KB/s），而 OpenList/AriaNg 的前端
有好几 MB 的 JS，于是浏览器**白屏**——但服务器本身完全正常。

部署脚本已经在本机开了一个 **SOCKS5 入口 `127.0.0.1:1081`**，它走 hysteria2 的 **UDP**
通道（Brutal 抗丢包），实测同一个文件能跑到 **900 KB/s**（比直连快 20 倍）。

三种用法，任选其一：

```bash
# ① 临时全局切换（最快）：系统设置 → 网络 → 你的网络 → 详细信息 → 代理
#    └ 打开「SOCKS 代理」，填 127.0.0.1 : 1081，并把 HTTP/HTTPS 代理先关掉；用完关回去

# ② 只让这几个域名走它（推荐）：用 v2rayN 的路由，或浏览器插件（SwitchyOmega）
#    规则：*.dickgroup.xyz  →  SOCKS5 127.0.0.1:1081

# ③ 开一个专用浏览器窗口，只给它挂代理（不影响日常浏览）：
open -na "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1081" \
     --user-data-dir=/tmp/chrome-nl
```

验证这条通道是否正常：

```bash
curl -o /dev/null -w 'HTTP %{http_code}  %{speed_download} B/s\n' \
     --proxy socks5h://127.0.0.1:1081 https://dllist.dickgroup.xyz/
```

不想要这个入口就 `--socks-port 0`（或填别的端口）重跑一次部署脚本。

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
| Mac 侧 SOCKS5 入口 | `127.0.0.1:1081` | — | 仅本机（走 UDP 隧道出网） |

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
| 面板（dllist / qb / aria）**白屏打不开**，但服务器上 `curl` 是 200 | 跨境 TCP 丢包严重（实测 30% 丢包会把 TCP 压到 40 KB/s），前端 1.4MB 的 JS 拉不完。把浏览器代理指到本机 SOCKS5 `127.0.0.1:1081`（走 UDP 隧道，实测约 900 KB/s）再打开即可。先自查丢包：`ping 你的服务器IP` |
| 自检说 `UDP 8443` 连不上 | 云安全组没放行 UDP 8443，或 SNI 与服务器证书域名不一致 |
| 文件只拉了一半 | 正常：下一轮 size 比对不一致会自动重拉 |
| 文件被删了 | 服务器的 24 小时清理策略。改 `RETENTION_MINUTES` 后可调整 |
| 下载完成了但宿主机上找不到文件 | 先确认下载器的保存路径：默认是 `/downloads`（= OpenList 的临时目录），只有选成 `/Mac` 的才会进 `/opt/nas`。再核对实际生效值：`curl -s http://127.0.0.1:6800/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"t","method":"aria2.getGlobalOption","params":["token:<aria2密钥>"]}'` 里的 `dir` 应为 `/downloads`；不是就重跑 `bash nas-server.sh reconfigure` |
| 日志报 `下载目录就绪` 但容器写不进去 | 挂载源属主不对。执行 `chown 1000:1000 /opt/openlist/data/temp && chmod 2775 /opt/openlist/data/temp`，再重跑下载器部署 |
| qB 日志报 `file_open (.../qBittorrent/<任务ID>/xxx.mkv) error: Permission denied` | OpenList 离线下载给的是宿主机绝对路径，且它建的任务目录属 root。确认容器里存在同名路径（`docker inspect` 看 `/opt/openlist/data/temp` 是否也挂着），并给目录加默认 ACL：`setfacl -m u:1000:rwx -m d:u:1000:rwx -m d:g:1000:rwx /opt/openlist/data/temp`，然后重跑 `bash nas-server.sh reconfigure` |
| OpenList 里用 aria2 离线下载报 Unauthorized | OpenList 的「Aria2 密钥」没填对。面板 → 设置 → 离线下载：地址 `http://localhost:6800/jsonrpc`，密钥填服务器上的 `ARIA2_RPC_SECRET`（在 `/etc/nas-server/nas-server.conf` 里） |
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
| `DOWNLOAD_SRC` | `/opt/openlist/data/temp` | 容器内 `/downloads` 的源目录（qB/aria2 的默认下载目录，也是 OpenList 的临时目录） |
| `MAC_DIR` | `/Mac` | 额外挂给 Mac mini 的挂载点在容器里的名字，源目录是 `EXCHANGE`。改完重跑脚本会自动更新 compose 与两个下载器的配置 |
| `PULL_USER` | `nas` | Mac 拉取用的服务器账号 |
| `RETENTION_MINUTES` | `1440` | 超过这么久没被改动的文件会被删除（1 天） |
| `CLEANUP_INTERVAL` | `10min` | 清理检查频率 |
| `HY2_PORT` | `8443` | hysteria2 的 UDP 端口 |
| `HY2_SNI` | — | 复用的 Caddy 证书域名 |
| `BIND_LOCAL` | `127.0.0.1` | 面板绑定地址 |

Mac 侧参数在 `/usr/local/etc/nas-nl/state.env`，可用命令行覆盖：

```bash
bash deploy-nas-nl-mac.sh --dest <目录> --interval <秒> --parallel <N> \
                          --down-mbps <N> --up-mbps <N> --stable-sec <N>
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--dest` | `/Volumes/D/Downloads` | 本地落地目录 |
| `--interval` | `300` | 拉取间隔（秒） |
| `--parallel` | `8` | 并发传输数（实测拐点，见第六节） |
| `--stable-sec` | `180` | **静默阈值**：远端文件连续 N 秒没被修改才拉走。防止把「正在下载」的半成品反复拉回来；`0` = 关闭该保护 |
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
| `nas-server.sh` | 1.3.0 |
| `deploy-nas-nl-mac.sh` | 1.3.0 |
| `uninstall-nas-nl-mac.sh` | 1.1.0 |
| `nas-server-cleanup.sh` | 随 `nas-server.sh` 生成 |
