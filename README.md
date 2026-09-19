# NAS 项目（三端：Mac mini + 国内服务器 + 国外下载机）

把**家里的 Mac mini** 变成「公网可访问的 NAS + 自动收片的落地端」。仓库里只有 **4 个脚本 + 本说明**，
每个脚本都是**单文件、自包含、可反复重跑（幂等）**的。

| 文件 | 版本 |
| --- | --- |
| `nas-n.sh` | 1.5.1 |
| `nas-n-mac.sh` | 1.5.1 |
| `nas-c.sh` | 1.0.0 |
| `nas-c-mac.sh` | 1.0.0 |

```
                        ┌──────────────────────────────────────┐
   观众/自己 ◄──TCP443──│ 国内服务器（公网入口）                  │
                        │  Caddy ─► 127.0.0.1:15244 (frps)     │
                        └──────────────▲───────────────────────┘
                                       │ Hysteria2 UDP/443（公网段纯 UDP）
                        ┌──────────────┴───────────────────────┐
                        │ Mac mini（家里）                       │
                        │  hysteria 客户端 + frpc                │
                        │  OpenList  127.0.0.1:5244             │
                        │  落地目录  /Volumes/D/Downloads         │
                        └──────────────▲───────────────────────┘
                                       │ Hysteria2 UDP/8443
                        ┌──────────────┴───────────────────────┐
                        │ 国外服务器（下载机）                    │
                        │  qBittorrent + aria2 + AriaNg         │
                        │  OpenList + Caddy                     │
                        │  待拉 /opt/nas ─► 归档 /opt/nas-used    │
                        └──────────────────────────────────────┘
```

## 一、四个脚本分别是干什么的

| 文件 | 跑在哪 | 覆盖的线路 | 作用 |
| --- | --- | --- | --- |
| **`nas-n.sh`** | **国外服务器** | 国外服务器侧 | 一键部署下载机：Docker + qBittorrent + aria2 + AriaNg + OpenList + Caddy 自动 HTTPS + **hysteria2 服务端** + 自动生成**归档助手与清理定时器** + sshd 并发调优 |
| **`nas-n-mac.sh`** | **Mac mini** | Mac ↔ **国外服务器** | 一键部署 Mac 侧收片链路：hysteria2 客户端（本机 SOCKS5 入口 + 把服务器 22 端口映射到 `127.0.0.1:2222`）+ **每 300 秒增量拉取**（拉完校验大小 → 归档远端那份），两者都注册为 launchd 开机自启 |
| **`nas-c.sh`** | **国内服务器** | 国内服务器侧 | 一键部署公网入口：hysteria2 服务端（UDP/443，复用 Caddy 证书、`sniGuard: strict`）+ frps（只绑回环 `7000` / 映射口 `15244`）+ 改 Caddyfile 站点块 + 端到端自检，并生成 **Mac 端对接包** 到 `/root/nas-tunnel-mac-client/` |
| **`nas-c-mac.sh`** | **Mac mini** | Mac ↔ **国内服务器**（**含 Mac 端项目部署**） | 一键部署 Mac 侧：按需装 Homebrew + OpenList（并改成只监听 `127.0.0.1`）、装 hysteria / frpc、写三个 LaunchDaemon（OpenList、隧道、frpc）+ **开机代理守护**（等代理就绪再重启 OpenList，治「重启后云盘打不开」）、拉取服务器对接包、跑四项端到端自检 |

命名规律：`nas-` + `n`（国外 / Netherlands）/ `c`（国内 / China）+ `-mac`（跑在 Mac 上的那一半）。

## 二、两套系统互相独立（重要）

「国外下载机」和「国内公网入口」是**两套完全独立**的部署，可以只用一套：

| | 国内入口那套 | 国外下载机那套 |
| --- | --- | --- |
| 服务器脚本 | `nas-c.sh` | `nas-n.sh` |
| Mac 脚本 | `nas-c-mac.sh` | `nas-n-mac.sh` |
| launchd 标签 | `com.nas.tunnel.*` + `com.openlist.server` + `com.openlist.wait-proxy` | `com.nas.nl.*` |
| 配置目录 | `/usr/local/etc/nas-tunnel/` | `/usr/local/etc/nas-nl/` |
| 日志目录 | `/usr/local/var/log/nas-tunnel/` | `/usr/local/var/log/nas-nl/` |
| 公网端口 | TCP 80/443 + **UDP 443** | **UDP 8443** + TCP 80/443 + BT 6881/6888 |

**唯一共用**：`/usr/local/bin/hysteria` 二进制。所以 `nas-n-mac.sh --uninstall` 不会删它。

## 三、部署顺序

```
【方案 A：把 Mac 上的 OpenList 暴露到公网】
  1. 国内服务器： sudo bash nas-c.sh          # 产出 /root/nas-tunnel-mac-client/ 对接包
  2. Mac mini   ： bash nas-c-mac.sh          # 普通用户跑，不要 sudo
  3. Mac mini   ： bash nas-c-mac.sh --self-test-only

【方案 B：国外服务器下载 → Mac 自动收片】
  1. 国外服务器： sudo bash nas-n.sh          # 跑完打印 hysteria2 地址/端口/密码/SNI
  2. 把 Mac 公钥装到国外服务器的 nas 账号      # 脚本会打印现成命令；或幂等重跑 nas-n.sh
  3. Mac mini   ： bash nas-n-mac.sh          # 普通用户跑，不要 sudo
  4. Mac mini   ： bash nas-n-mac.sh --self-test && bash nas-n-mac.sh --pull-now
```

两套都部署时建议**先 A 后 B**：A 决定 Mac 上 OpenList 的位置和「重启后等代理就绪」的兜底，B 只是往落地目录送文件。

## 四、常用子命令

```bash
# 国内服务器
sudo bash nas-c.sh                    # 部署 / 幂等重跑
sudo bash nas-c.sh --status           # 状态 + Mac 端对接参数（6 项）
sudo bash nas-c.sh --self-test-only   # 只重跑端到端自检
sudo bash nas-c.sh --uninstall        # 卸载并还原 Caddyfile

# 国外服务器
sudo bash nas-n.sh                    # 部署 / 幂等重跑
sudo bash nas-n.sh reconfigure        # 重新问答并覆盖配置
sudo bash nas-n.sh status | ports | macmini | cleanup
sudo bash nas-n.sh uninstall          # 卸载（保留交换目录数据）

# Mac（两套各一份）
bash nas-c-mac.sh [--status|--self-test-only|--uninstall|--help]
bash nas-n-mac.sh [--status|--pull-now|--self-test|--recall "<文件名子串>"|--uninstall|--help]
```

> Mac 端脚本**不要用 `sudo bash` 运行**（Homebrew 拒绝以 root 运行）；脚本内部会在需要提权处自己调用 `sudo`。

## 五、收片语义（本项目最容易搞错的地方）

```
/opt/nas        待拉目录：qB/aria2 下载到这里，Mac 只从这里拉
   │  Mac 拉走，且「本地大小 == 远端大小」
   ▼
/opt/nas-used   已送达归档：远端那份被 mv 过来，24 小时后自动删除
```

**「只传一遍」的实现是移动文件，不靠状态文件**：文件被拉走后立刻离开待拉目录，Mac 再也不会看到它 ——
所以在本地怎么整理、改名、甚至删掉都不会重传。想重传用 `--recall "<文件名子串>"`（把归档区的文件挪回待拉区）。

**归档后自动从 qBittorrent 面板删掉对应种子**（只删种子、不删文件；判定很保守：非下载态 + 进度 100% +
它的每个文件在磁盘上都不存在）。目的是打断「搬走 → 被标 missingFiles → 重新下载」的循环。

**「只拉已下完的」四道闸门**（缺一不可）：

1. **跳过后缀**：`*.!qB`、`*.aria2`、`*.part`、`*.unwanted` 一律不拉；
2. **同名 `.aria2` 控制文件还在 → 一定没下完**（比计时器硬，慢速/暂停任务也挡得住）；
3. **静默阈值 180 秒**：mtime 一直在变的文件每轮都被跳过，下完静默够久才进入候选；
4. **`age < 0` 放行**：源站 `Last-Modified` 在未来时永远等不到「静默够久」，按已下完处理。

> ⚠️ **qBittorrent 必须开启「未完成文件加 `.!qB` 后缀」**（`nas-n.sh` 会通过 WebUI API 自动打开）。
> 因为 qB 预分配的文件在磁盘上就是满大小，Mac 只看大小会把没下完的误判成已送达，剩下没下的部分就永久丢了。

**保留策略**（清理定时器每 10 分钟跑一次，两个目录各算各的）：

| 目录 | 默认保留 | 含义 |
| --- | --- | --- |
| `/opt/nas-used`（已送达） | 1440 分钟（24 小时） | 留档窗口，过期删除 |
| `/opt/nas`（待拉） | 10080 分钟（7 天） | 还没送出去的东西不会太快被删（Mac 长期离线的保护） |

## 六、参数速查

| 项 | 值 |
| --- | --- |
| 国内线路 | Mac `127.0.0.1:1080`(SOCKS5) → 服务器 `127.0.0.1:7000`(frps)；映射口 `127.0.0.1:15244` → Mac 的 OpenList `127.0.0.1:5244`；hy2 端口 UDP **443** |
| 国外线路 | Mac `127.0.0.1:2222` → 服务器 `127.0.0.1:22`(SSH)；SOCKS5 `127.0.0.1:1081`；hy2 端口 UDP **8443** |
| 拉取参数 | 间隔 300 秒、并发 8、静默阈值 180 秒、落地目录 `/Volumes/D/Downloads`、Brutal 声明 50/100 Mbps |
| 服务器配置 | `/etc/nas-server/nas-server.conf`（600）：`EXCHANGE=/opt/nas`、`EXCHANGE_USED=/opt/nas-used`、`DOWNLOAD_SRC=/opt/openlist/data/temp`、`MAC_DIR=/Mac`、`DEFAULT_SAVE_DIR=/Mac`、`PULL_USER=nas`、`RETENTION_MINUTES=1440`、`INBOX_RETENTION_MINUTES=10080`、`CLEANUP_INTERVAL=10min`、`HY2_PORT=8443`、`BIND_LOCAL=127.0.0.1` |
| Mac 配置 | `/usr/local/etc/nas-nl/state.env`、`/usr/local/etc/nas-tunnel/state.env`（600）；国内服务器：`/etc/nas-tunnel/state.env`（600） |
| 服务器定时任务 | `nas-server-cleanup.timer`（每 10 分钟清理两个目录）、`nas-server-cert-sync.timer`（每天把 Caddy 证书同步给 hysteria2） |

Mac 侧可在部署时覆盖：`--dest <目录> --interval <秒> --parallel <N> --down-mbps <N> --up-mbps <N> --stable-sec <N>`。

## 七、不变量（设计前提，不要改）

1. **`frpc` 的 `serverAddr` 必须写 `127.0.0.1`**，再由 `transport.proxyURL = socks5://…@127.0.0.1:1080` 把连接交给 hysteria2 —— 写成服务器 IP 就绕过隧道，公网段会出现 TCP。
2. **两层结构不能合一**：hysteria2 **v2 已移除反向隧道**（v1 的 `tcpForwarding` 没了），所以必须「HY2 负责过公网（UDP/QUIC + Brutal）+ frp 负责接端口」。
3. hysteria2 客户端**必须写 `bandwidth`**（否则退回 BBR，失去 Brutal 抗丢包/抢带宽）；`tls.sni` **必须等于证书域名**（服务器 `sniGuard: strict`）。
4. 服务器端 **frps 的 `bindAddr` / `proxyBindAddr` 都是 `127.0.0.1`**；面板（OpenList / qBittorrent / AriaNg / aria2 RPC）也只绑回环，外部一律走 Caddy 的 HTTPS。
5. Mac 上 **OpenList 只监听 `127.0.0.1:5244`**（监听 `0.0.0.0` 等于让局域网绕过隧道直连）。
6. 服务器端配置文件由脚本生成（文件头写「勿手改」），**重跑脚本会覆盖**；脚本只动 Caddyfile 中带 `nas-tunnel-managed` 标记的区块，绝不动其他站点。
7. **归档必须「先校验、后移动」**：本地大小 == 远端大小才算送达，之后才把远端那份 mv 进归档区 —— 顺序颠倒会把没下完的文件从下载器手里抢走。
8. `com.openlist.wait-proxy` 这个兜底不能删：OpenList 是系统级守护（开机约 6 秒就起），代理是登录级（起得更晚），没有它就绪检查，云盘存储在代理未就绪时会初始化失败且不自愈。
9. Mac 端落地目录若在外置卷上，必须给 `/bin/bash` 开「完全磁盘访问权限」（否则任务报 `Operation not permitted`）。
10. 国外服务器的 OpenList 与容器里的下载器**路径必须里外一致**：容器里要同时挂 `/downloads` 和同名的 `/opt/openlist/data/temp`（OpenList 传的是宿主机绝对路径），且该目录要带 uid 1000 的默认 ACL，否则 qB 会报 `Permission denied`。

## 八、环境前提（脚本代替不了的事）

- **DNS**：域名 A 记录指向对应服务器公网 IP，且 **Cloudflare 必须关掉橙云（DNS only）** —— 橙云穿不过 ACME 挑战，证书签不下来。
- **云安全组 / 防火墙放行**：国内服务器 `TCP 80、443` + **`UDP 443`**（最易漏；漏了的表现是「脚本自检全绿但 Mac 连不上」，因为自检走回环）；国外服务器 `TCP 22、80、443` + **`UDP 8443`** + BT `6881/6888`。
- **国内域名需完成 ICP 备案**：国内云厂商会对未备案域名在 80/443 做拦截（HTTP 返回 `403` / `Server: Beaver`，HTTPS 握手后被 RST；抽样拦截，表现为「时通时不通」）。
- Mac mini 建议关睡眠：`sudo pmset -a sleep 0 disksleep 0`；时间同步：`sudo systemsetup -setusingnetworktime on`。
- Mac 端脚本需要能访问 GitHub（国内直连不稳），可用 `-p http://127.0.0.1:10808` 指定本机代理。

## 九、常见故障对照

| 现象 | 含义 / 处理 |
| --- | --- |
| 访问域名一直 **502** | Caddy 与隧道都正常，但 frpc 没登记（`15244` 无人监听）→ 在 Mac 上把 frpc 起起来 |
| 自检全绿但 Mac 连不上 | 云安全组没放行 **UDP 443**（国内）/ **UDP 8443**（国外） |
| 浏览器证书报错 | DNS 没指对、开了 Cloudflare 橙云、或国内域名没备案 |
| 隧道通但页面打不开 | frpc 注册失败，或 `localPort` / `remotePort` 对不上（看 `/usr/local/var/log/nas-tunnel/frpc.log`） |
| 拉取日志只有「开始检查」没有结果行 | 服务器待拉目录是空的 → **正常**，不是故障 |
| 拉取日志报 `Operation not permitted` | 外置卷的「完全磁盘访问权限」授权没做 |
| 拉取日志报「本地转发端口 2222 未就绪」 | 国外那套的 hysteria 客户端没起来 |
| 文件只拉了一半 | 正常，下一轮 size 不一致会自动重拉 |
| 面板白屏（国外那套） | 跨境 TCP 丢包，把浏览器代理指到本机 SOCKS5 `127.0.0.1:1081`（走 UDP 隧道） |
| 速度慢 / 抖动大 | `bandwidth.up` 设得远高于家宽实测上行 → 下调到实测值（或 ~80%） |
| 下载完了但服务器上找不到文件 | 下载器实际保存路径不对（默认应是 `/Mac`）；或容器挂载源属主不是 `1000:1000` |
| qB 报 `file_open … Permission denied` | `/opt/openlist/data/temp` 缺 uid 1000 的默认 ACL |

## 十、卸载与仓库历史

- 四个脚本各自带 `--uninstall` / `uninstall`。Mac 端卸载**默认不碰**：共享的 `hysteria` 二进制、`~/.ssh` 密钥、落地目录里的文件、另一套系统的任何东西。
- 仓库经过一次整理：原先的多份 README 文档、`mac/` 手工部署模板、`uninstall-*.sh`、旧一代「推送方案」的 `nas-n.sh` 都从工作区删除，但**全部保留在 git 历史里**，需要时取回：

```bash
git log --oneline --all                  # 找整理前的提交
git show <提交>:<旧文件名> > /tmp/恢复的文件
```

- 旧名 → 新名对照（查历史时用）：

| 旧名 | 新名 |
| --- | --- |
| `deploy-nas-nl-mac.sh` | `nas-n-mac.sh` |
| `deploy-nas-tunnel-mac.sh` | `nas-c-mac.sh` |
| `deploy-nas-tunnel.sh` | `nas-c.sh` |
| `nas-server.sh` | `nas-n.sh` |
