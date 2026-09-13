# Mac mini 端部署说明

配套服务器端的 [`deploy-nas-tunnel.sh`](../deploy-nas-tunnel.sh) 使用。
本目录同时提供**一键脚本** [`deploy-nas-tunnel-mac.sh`](../deploy-nas-tunnel-mac.sh)
和**手工部署用的模板文件**。

- 服务器端负责公网入口（Caddy + 证书 + frps + Hysteria2 服务端）
- **Mac mini 端负责主动连出去**，把本机 OpenList 挂上那条隧道

---

## 一、先看结构（为什么要两个进程）

Hysteria2 **v2 不支持反向隧道**（v1 的 `tcpForwarding` 在 v2 已被官方移除），
所以拆成两层：

| 层 | 进程 | 职责 |
| --- | --- | --- |
| 过公网 | `hysteria`（客户端） | 用 UDP/QUIC 把 Mac 连到服务器，提供本地 socks5 出口；Brutal 拥塞控制负责抗丢包、抢带宽 |
| 接端口 | `frpc` | 反向端口映射：把「服务器上的 `15244` 端口」接到「Mac 的 `5244`」 |

**关键的机关**：frpc 并不直连服务器。它的 `serverAddr` 写成 `127.0.0.1:7000`，
再由 `transport.proxyURL` 把这句 `CONNECT 127.0.0.1:7000` 交给 Hysteria2 的 socks5 入站，
最终由**服务器端的 Hysteria2 进程在服务器本机**拨号到 frps。

```
浏览器 ──TCP/443──► Caddy(服务器)              UDP/443 ◄── QUIC 加密隧道 ── Mac mini
                    │  <域名> 站点块                                      │
                    └► reverse_proxy 127.0.0.1:15244                     │
                                          ▲                              │
                                     frps(服务器 127.0.0.1:7000) ◄── 经隧道登录 ── frpc(Mac)
                                                                          │
                                              hysteria 客户端 socks5 ◄────┘
                                                    (Mac) ──► OpenList 127.0.0.1:5244
```

**结果**：Mac↔服务器 的公网段**只有 UDP**，一个 TCP 包都不出去。

---

## 二、一键部署（推荐）

前提：服务器侧已经跑通 `deploy-nas-tunnel.sh`（它会在
`/root/nas-tunnel-mac-client/` 生成一份**已填好真实参数**的对接包）。

```bash
# 在 Mac mini 上，用「普通用户」执行 —— 不要 sudo bash
bash deploy-nas-tunnel-mac.sh
```

脚本会问你一个东西：**服务器公网 IP**（其余参数它自己从那台服务器上拉）。
中间会用 SSH 登录服务器，**提示你输入一次 server 的 root 密码**。

常用子命令：

```bash
bash deploy-nas-tunnel-mac.sh --status            # 查看状态
bash deploy-nas-tunnel-mac.sh --self-test-only    # 只跑端到端自检
bash deploy-nas-tunnel-mac.sh --uninstall         # 卸载（默认保留 OpenList 数据目录）
bash deploy-nas-tunnel-mac.sh --uninstall --purge-data   # 连数据目录一起删
bash deploy-nas-tunnel-mac.sh -p http://127.0.0.1:10808  # 指定下载代理
```

### 两个容易踩的前提

1. **下载要走代理。** 实测国内直连 `github.com` 时通时不通，脚本默认探测
   `127.0.0.1:10808`（v2rayN 的 xray 后端）。探测不到会退回 GitHub 加速站。
2. **不要用 sudo 跑本脚本。** Homebrew 拒绝以 root 运行；脚本内部需要提权的地方
   会自己调用 `sudo`（`/usr/local`、`/opt`、`/Library/LaunchDaemons`）。

---

## 三、脚本具体做了什么

| 阶段 | 内容 | 落地位置 |
| --- | --- | --- |
| 0 | 校验 macOS/架构、代理探测、sudo 预热 | — |
| 1 | SSH 拉取服务器对接包并解析参数 | `/usr/local/etc/nas-tunnel/`（600） |
| 2 | 按需安装 Homebrew → `brew install openlist` → **把监听地址改成 127.0.0.1** | `/opt/openlist/data`、`/opt/homebrew/bin/openlist` |
| 3 | 下载 hysteria / frpc（darwin-arm64） | `/usr/local/bin/` |
| 4 | 校正配置（**把 frpc 的 `log.to` 改到用户可写目录**） | `/usr/local/etc/nas-tunnel/` |
| 5 | 写三个 LaunchDaemon（`RunAtLoad` + `KeepAlive`） | `/Library/LaunchDaemons/` |
| 6 | 四项端到端自检 + 汇总 | 运行日志在 `/usr/local/var/log/nas-tunnel/` |

三个 launchd 服务：

| Label | 程序 | 说明 |
| --- | --- | --- |
| `com.openlist.server` | `openlist server --data /opt/openlist/data --log-std` | OpenList 本体 |
| `com.nas.tunnel.hysteria` | `hysteria client --config …/hysteria-client.yaml` | 隧道 |
| `com.nas.tunnel.frpc` | `frpc -c …/frpc.toml` | 反向映射 |

都放在 **system 域**（`/Library/LaunchDaemons/`），所以**开机即起、不需要登录**；
三个都带 `KeepAlive`，进程挂了会自动拉起。三者都以**登录用户**身份运行
（`UserName` 键），不是 root。

---

## 四、参数从哪来

在**服务器**上执行 `bash deploy-nas-tunnel.sh --status`，会打印这 6 项
（也会写进 `/root/nas-tunnel-info.txt`）：

| 参数 | 说明 |
| --- | --- |
| 服务器公网 IP | |
| Hysteria2 UDP 端口 | 默认 `443` |
| Hysteria2 密码 | 32 位随机 |
| 域名 / TLS SNI | |
| frp token | 32 位随机 |
| 远端映射端口 | 默认 `15244` |

另外两项在服务器侧的 `--status` 里也有：Mac 端 socks5 入站的端口与用户名/密码。

一键脚本不需要你手抄这些：它直接 `scp` 服务器上的
`/root/nas-tunnel-mac-client/`（含 `hysteria-client.yaml`、`frpc.toml`、`README.md`）。
**拉不到时**（服务器侧没部署、SSH 不通等）它会问你是否改为手工输入，
然后按同样的格式生成配置。

---

## 五、手工部署对照

如果你偏手工做，本目录的模板可以直接用：

| 模板 | 落到哪里 |
| --- | --- |
| `hysteria-client.yaml.example` | `/usr/local/etc/nas-tunnel/hysteria-client.yaml`（600） |
| `frpc.toml.example` | `/usr/local/etc/nas-tunnel/frpc.toml`（600） |
| `com.nas.tunnel.hysteria.plist` | `/Library/LaunchDaemons/` |
| `com.nas.tunnel.frpc.plist` | `/Library/LaunchDaemons/` |
| `com.openlist.server.plist` | `/Library/LaunchDaemons/` |

模板里有两处占位符要替换：

1. 配置里的 `<...>`（见服务器 `--status`）
2. plist 里的 `__RUN_USER__` → 你的登录用户名（`id -un`）

> ⚠️ **你给的那个 `res.oplist.org.cn/script/v4.sh` 在 macOS 上跑不了**：
> 它开头就 `uname -s != Linux → 退出`，并要求 systemd / OpenRC。
> macOS 上请用 `brew install openlist`（一键脚本就是这么做的）。

手工装 OpenList 的要点：

```bash
# 1) 装 Homebrew（若没有）—— 官方脚本
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# 2) 装 OpenList
/opt/homebrew/bin/brew install openlist
```

---

## 六、必须注意的坑

| 项 | 要求 | 原因 |
| --- | --- | --- |
| `tls.sni` | **必须等于域名** | 服务器开了 `sniGuard: strict`，SNI 不匹配直接断开 |
| `tls.insecure` | 通常 `false` | 服务器复用 Caddy 真证书；**仅当服务器自签降级时才 `true`** |
| `bandwidth` | **不能省** | 省了就退回 BBR，拿不到 Brutal 的抗丢包/抢带宽效果 |
| `bandwidth.up` | 你家宽上行实测值 | 填太大会让 Brutal 的丢包补偿猛冲，**反而更慢更抖更费流量** |
| `serverAddr` | **必须是 `127.0.0.1`** | 写服务器 IP 会让 frpc 绕过隧道直连，白搭 |
| `transport.proxyURL` | 指向 hysteria 的 socks5 入站 | 同上 |
| `transport.tls.enable` | `false` | HY2 已端到端加密，frp 再套 TLS 只是白耗 CPU |
| OpenList 监听地址 | **只绑 `127.0.0.1`** | OpenList 默认是 `0.0.0.0`；绑全网卡等于局域网可绕过隧道直连。一键脚本会自动把数据目录下 `config.json` 的 `scheme.address` 改成 `127.0.0.1` |
| frpc `log.to` | 指到用户可写目录 | 服务器生成的模板写的是 `/var/log/frpc.log`，普通用户写不进去；脚本会改到 `/usr/local/var/log/nas-tunnel/frpc.log` |
| 运行身份 | 普通用户 | 用 root 跑没必要且风险更高；Homebrew 还拒绝以 root 运行 |

---

## 七、起来之后怎么确认

一键脚本会自动跑这四项自检，也可以手动：

```bash
# 1) 隧道本身通不通（应返回 200/301/302）
curl -x socks5h://<socks5用户名>:<socks5密码>@127.0.0.1:1080 -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com

# 2) OpenList 在不在
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5244/

# 3) frpc 有没有登记映射（应看到 start proxy success）
grep -i 'start proxy success' /usr/local/var/log/nas-tunnel/frpc.log

# 4) 公网入口（应返回 200）
curl -s -o /dev/null -w '%{http_code}\n' https://<域名>/
```

在**服务器**上再确认一眼：

```bash
ss -tln | grep 15244        # 出现 LISTEN 说明隧道登记成功
curl -s -o /dev/null -w '%{http_code}\n' https://<域名>/   # 应返回 200
```

平时看服务状态：

```bash
sudo launchctl print system/com.openlist.server
sudo launchctl print system/com.nas.tunnel.hysteria
sudo launchctl print system/com.nas.tunnel.frpc
tail -f /usr/local/var/log/nas-tunnel/*.log
```

---

## 八、故障对照表

| 症状 | 含义 | 处理 |
| --- | --- | --- |
| 浏览器访问域名一直 **502** | Caddy 和隧道都正常，但没有 frpc 登记（`127.0.0.1:15244` 无人监听） | 把 frpc 跑起来：`sudo launchctl print system/com.nas.tunnel.frpc` |
| 隧道 curl 一直挂 / 超时 | UDP 被挡或参数错 | 先确认**服务器安全组放行了 UDP 443 入站**（最常见）；再核对密码、`tls.sni` |
| frpc 报 `login to server failed` | token 不对，或 socks5 没起来 | 核对 `auth.token`；确认 hysteria 已在 `127.0.0.1:1080` 监听 |
| frpc 起来了但访问仍 502 | 端口没对上 | 核对 `remotePort`（应 = 服务器 `15244`）、`localPort`（应 = Mac 上 OpenList 端口） |
| 速度慢、抖动大 | `bandwidth.up` 远高于实际链路 | 下调到实测家宽上行的 ~80% |
| 能连但过一会儿断 | 家宽 NAT 会话超时 | 两个进程的 `KeepAlive` 都保持开启即可 |
| 局域网里能直接访问 5244 | `scheme.address` 不是 `127.0.0.1` | 改 `/opt/openlist/data/config.json` 里的 `address` 后重启 `com.openlist.server` |
| 忘了 OpenList 管理员密码 | 初始密码只在首次启动打印一次 | `openlist admin random --data /opt/openlist/data`（重置为随机密码并打印），或 `openlist admin set <新密码>` |

---

## 九、安全注意

- OpenList 在 Mac 上**只监听 `127.0.0.1:5244`**，不要绑 `0.0.0.0`
- `/usr/local/etc/nas-tunnel/` 下的配置含密码/token，权限 `600`（一键脚本已处理）
- 本仓库里的 `*.example` 是**脱敏模板**，请勿把填好真实密钥的配置提交上来
- 三个服务都以**普通用户**运行，日志目录 `/usr/local/var/log/nas-tunnel/` 属于该用户
