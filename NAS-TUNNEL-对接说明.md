# NAS 反向隧道 · 设计说明与 Mac 端对接要点

本文件配合 `deploy-nas-tunnel.sh`（**服务器端**）使用。

脚本负责在这台国内服务器上搭好"公网入口"，把家里 Mac mini 上的 OpenList 通过
**Hysteria2 加密隧道 + frp 反向端口映射**暴露到公网域名上，并由 Caddy 自动申请/续期
Let's Encrypt 证书。**Mac 端脚本由你后期自行编写**，本文件给出对齐用的完整契约。

---

## 一、最终架构与数据流

```
观众 ──TCP/443──► Caddy(服务器)                UDP/443 ◄── QUIC 加密隧道 ── Mac mini
                  │  <域名> 站点块                                        │
                  └► reverse_proxy 127.0.0.1:15244                       │
                                        ▲                                │
                                   frps(服务器 127.0.0.1:7000) ◄── 经隧道登录 ── frpc(Mac)
                                   proxyBindAddr=127.0.0.1        proxyURL=socks5://127.0.0.1:1080
                                                                         │
                                            hysteria 客户端 socks5 ◄─────┘
                                                  (Mac) ──► OpenList 127.0.0.1:5244
```

### 每一跳的真实协议

| 链路 | 实际协议 | 是否跨公网 |
| --- | --- | --- |
| 观众 → 服务器 Caddy | HTTPS / TCP 443 | 是（公网 TCP） |
| Caddy → frps | TCP `127.0.0.1:15244` | 否，本机回环 |
| **frps ↔ frpc** | frp 协议，被 HY2 装进 QUIC 包 | **是 → 公网 UDP/443** |
| **hysteria 客户端 ↔ 服务端** | **QUIC over UDP/443** | **是 → 公网 UDP/443** |
| hysteria 客户端 → OpenList | TCP `127.0.0.1:5244` | 否，本机回环 |

**结论：Mac↔服务器 的公网段是纯 UDP，一个 TCP 包都不出去。**

### 为什么要两层

Hysteria2 **v2 不支持反向隧道**（v1 的 `tcpForwarding` 在 v2 已被官方移除）。

- **HY2** 负责"怎么过公网"：UDP/QUIC + **Brutal 拥塞控制**（丢包不退让，专门抢带宽）
- **frp** 负责"把内网哪个端口接到服务器"：反向端口映射

frp 自己也能走 UDP（`transport.protocol = quic|kcp`），但那样就没有 Brutal 了。
上游 gost 不支持 hy2（数据通道里没有 hysteria2），网上"hy2 版 gost"是第三方 fork，未采用。

### 关键机关：frpc 为什么写 `serverAddr = 127.0.0.1`

frpc 并不直连服务器。它把这句 `CONNECT 127.0.0.1:7000` 交给 **HY2 客户端的 socks5 入站**，
由 **服务器端的 HY2 进程在服务器本机**拨号到 frps。

- 好处 1：公网全程 UDP，没有 TCP 暴露
- 好处 2：frps 可以只绑 `127.0.0.1`，公网扫不到，也不占公网端口
- 好处 3：数据只跨一次公网（Mac→服务器），没有绕路

---

## 二、服务器侧固定约定

| 项目 | 值 | 说明 |
| --- | --- | --- |
| Hysteria2 UDP 端口 | `443`（默认） | 与 Caddy 的 HTTPS 同号，方便伪装；需安全组放行 UDP 443 入站 |
| Hysteria2 配置 | `/etc/hysteria/config.yaml` | |
| Hysteria2 证书 | `/etc/hysteria/tls/<域名>.crt|.key` | 符号链接到 Caddy 签发的证书，续期自动生效 |
| Hysteria2 服务 | `hysteria-server.service` | UDP 监听 |
| frps 控制口 | `127.0.0.1:7000` | **仅回环** |
| frps 映射口 | `127.0.0.1:15244` | **仅回环**，Caddy 反代目标 |
| frps 配置 | `/etc/frp/frps.toml` | |
| frps 服务 | `frps.service` | |
| Caddy 站点块标记 | `# >>> nas-tunnel-managed: <域名>` | 与本仓库 `deploy-openlist.sh` 的 `openlist-managed` 互不干扰 |
| Caddy 全局块标记 | `# >>> nas-tunnel-managed: global` | 只用于关闭 HTTP/3 |
| 状态文件 | `/etc/nas-tunnel/state.env`（600） | `--status` / `--uninstall` / 幂等重跑都读它 |
| 连接信息 | `/root/nas-tunnel-info.txt`（600） | 人类可读的 6 项参数 |
| Mac 端对接包 | `/root/nas-tunnel-mac-client/`（700） | `README.md` + `hysteria-client.yaml` + `frpc.toml` |

安全组需要放行：**TCP 80、TCP 443（已有）+ UDP 443（新增，最关键）**。

---

## 三、Mac 端对接契约（写 Mac 脚本时按这个对齐）

### 3.1 必须从服务器拿到的 6 项参数

服务器上执行 `bash deploy-nas-tunnel.sh --status` 即可打印，也会写进
`/root/nas-tunnel-info.txt` 和 `/root/nas-tunnel-mac-client/README.md`。

1. 服务器公网 IP
2. Hysteria2 UDP 端口（默认 443）
3. Hysteria2 密码
4. 域名 / TLS SNI
5. frp token
6. 远端映射端口（15244）

外加：Mac 端 socks5 入站端口（默认 1080）、Mac 上 OpenList 端口（默认 5244）。

### 3.2 Hysteria2 客户端要点

| 字段 | 值 | 为什么 |
| --- | --- | --- |
| `server` | `<IP>:<UDP端口>` | |
| `auth` | `<HY2 密码>` | 服务器 `auth.type: password` |
| `tls.sni` | **必须 = 域名** | 服务器开了 `sniGuard: strict`，SNI 不匹配直接断 |
| `tls.insecure` | 通常 `false` | 服务器复用 Caddy 真证书；**仅当服务器自签降级时才用 `true`** |
| `socks5.listen` | `127.0.0.1:1080` | 给 frpc 当本地出口 |
| `bandwidth.up` | 你家宽上行 | **不写就没有 Brutal**，会退回 BBR |
| `bandwidth.down` | 家宽下行 / 或省略 | 一般不是瓶颈 |
| `quic.*` | 保持默认 | 官方文档明确不建议随意改接收窗口 |

### 3.3 frpc 要点

```toml
serverAddr = "127.0.0.1"          # 必须是 127.0.0.1，不能写服务器 IP
serverPort = 7000
loginFailExit = false              # 登录失败不要退出，靠 KeepAlive 重试

auth.method = "token"
auth.token = "<token>"

transport.proxyURL = "socks5://<user>:<pass>@127.0.0.1:1080"   # 关键：把连接交给 HY2
transport.tcpMux = true
transport.tls.enable = false       # HY2 已加密，frp 再套 TLS 只是白耗 CPU

[[proxies]]
name = "openlist"
type = "tcp"
localIP = "127.0.0.1"
localPort = 5244                   # Mac 上 OpenList
remotePort = 15244                 # 服务器上的映射口（回环）
```

### 3.4 启动顺序与自启

先起 `hysteria`，再起 `frpc`（frpc 会自动重连，顺序不致命，但日志更干净）。
两个 launchd plist 都放 `/Library/LaunchDaemons/`，都要 `KeepAlive = true`。
完整 plist 模板见 `/root/nas-tunnel-mac-client/README.md`。

### 3.5 OpenList 在 Mac 上的要求

- 监听 `127.0.0.1:5244`，**不要**监听 `0.0.0.0`（否则局域网内可绕过隧道直连）
- 如需外网访问，务必在 OpenList 后台设好管理员密码

---

## 四、性能调优（"速度最快"这一项）

### 4.1 已做的优化

| 措施 | 作用 |
| --- | --- |
| HY2 `Brutal` 拥塞控制 | 丢包不退让，对抗家宽拥塞 |
| AVX2 版 hysteria 二进制（自动探测，失败回退） | 加解密吞吐更高 |
| frp `transport.tls.enable = false` | 去掉冗余 TLS 层，省 CPU 与延迟 |
| Caddy `flush_interval -1` | 关闭响应缓冲，大文件/流媒体不被攒包 |
| UDP 443（而非高位端口） | 家宽/移动网络对 443 的 UDP 限速通常最轻 |
| frp `tcpMux` + 长连接 | 避免每个观众连接都重新握手 |

### 4.2 你必须注意的调参

**服务器出口带宽是硬上限**，任何脚本都突破不了。脚本会把能控制的每一环拉到最大，
但出口带宽是云厂商的账单项。

- Mac 端 `bandwidth.up` 应设为**你家宽上行的实测值**，且**不要远高于服务器出口带宽**。
  官方明确警告：Brutal 目标速率高于链路实际最大值时，丢包补偿会让它猛冲，结果是
  **更慢、更抖、更费流量**。
- 换到更快的服务器后：在新服务器上重跑本脚本即可，客户端配置会重新生成。
- 想额外抑制抖动可以开端口跳跃（`--hop 20000-50000`），但需要安全组放行整段 UDP，
  且 Mac 端配置要同步改成 `server: <IP>:<起>-<止>` + `hopInterval`。

### 4.3 关于 HTTP/3 的取舍

Caddy 默认也监听 UDP 443（HTTP/3）。脚本默认**关闭它**并把 UDP 443 让给 Hysteria2
（`--no-disable-h3` 可保留，Hysteria2 会自动改用 8443）。

理由：家宽那一跳是真正丢包的一跳，让它用最"不起眼"的 443/UDP 收益最大；而播放器/浏览器
通过 OpenList 取流基本走 HTTP/1.1 或 HTTP/2，HTTP/3 收益很小。

---

## 五、运维与排错

```bash
# 状态与连接参数
bash deploy-nas-tunnel.sh --status

# 只重跑端到端自检
bash deploy-nas-tunnel.sh --self-test-only

# 服务
systemctl status hysteria-server      # 隧道
systemctl status frps                 # 反向映射
systemctl status caddy                # 公网入口
journalctl -u hysteria-server -f

# 完整卸载（会恢复 Caddyfile 与 HTTP/3，并备份配置到 /root/nas-tunnel-backup-<ts>）
bash deploy-nas-tunnel.sh --uninstall
```

### 症状对照表

| 症状 | 含义 | 处理 |
| --- | --- | --- |
| `https://域名/` 返回 **502** | Caddy 与隧道都正常，**Mac 端 frpc 没上线** | 在 Mac 上启 frpc；这是部署完成时的正常状态 |
| 浏览器证书错误 | Caddy 没签下证书，走了自签降级 | 查 DNS（Cloudflare 是否关了小云朵）、备案、安全组 80/443 |
| 脚本全绿但 Mac 连不上 | **安全组没放行 UDP 443**（本机自检走回环，查不出这个） | 云控制台放行 UDP 443 入站 |
| HY2 自检失败 | 证书路径 / SNI / 密码有问题 | `journalctl -u hysteria-server -n 50` |
| hysteria 启动即 FATAL `tls.cert: ... permission denied` | systemd 单元少了 `CAP_DAC_READ_SEARCH`：文件其实存在，是 root 被裁掉了绕过 DAC 检查的能力、穿不过 Caddy 的 700 私钥目录 | `systemctl show hysteria-server -p CapabilityBoundingSet` 确认含 `cap_dac_read_search` |
| 隧道通了但打不开页面 | frpc 注册失败或 localPort 写错 | 看 Mac 上 `/var/log/frpc.log` |
| 速度慢、抖动大 | `bandwidth.up` 设得远高于实际链路 | 下调到实测家宽上行的 ~80% |

---

## 六、明确不做的事

- 不写 Mac 端脚本（只生成可直接使用的配置模板与文档）
- 不做通用清理：不删 `/opt/openlist`、不动 `reelbox.dickgroup.xyz` 等其他站点、
  不改云厂商安全组、不代做 DNS 解析
- 只映射 OpenList 的 TCP 5244（`frpc.toml` 里留了加端口的注释示例）
- 不修改 `deploy-openlist.sh`

---

## 七、安全边界

- 公网只开 TCP 443（Caddy）与 UDP 443（Hysteria2）
- frps 控制口与映射口**全部绑定回环**，公网不可达
- Hysteria2：密码认证 + `sniGuard: strict`（SNI 必须匹配证书）
- frp：token 认证（回环内仍保留，双保险）
- Hysteria2 以 root 运行但已收紧：`NoNewPrivileges`、`ProtectSystem=full`、
  `ProtectHome=read-only`、`CapabilityBoundingSet` 只留
  `CAP_NET_ADMIN / CAP_NET_BIND_SERVICE / CAP_NET_RAW / CAP_DAC_READ_SEARCH`。

- **⚠️ `CAP_DAC_READ_SEARCH` 不能删。** 之所以用 root，就是要直接读 Caddy 的私钥目录
  （`/var/lib/caddy/.local/share/caddy/...` 整条链路 700 `caddy:caddy`，文件 600），
  这样**符号链接**即可让证书续期立即生效，不需要额外的定时同步任务。
  而 root 之所以能读别人的 700 目录，靠的正是 `CAP_DAC_OVERRIDE` / `CAP_DAC_READ_SEARCH`
  这类绕过 DAC 检查的能力：**一旦用 `CapabilityBoundingSet` 把它们裁掉，root 也会吃
  EACCES**，表现为 hysteria 启动即 FATAL：

  ```
  failed to load server config  {"error": "invalid config: tls.cert:
    stat /etc/hysteria/tls/<域名>.crt: permission denied"}
  ```

  只加 `CAP_DAC_READ_SEARCH`（仅能读/穿越目录，不能绕过写权限）是最小够用的选择。

  > 如果更希望 hysteria 完全不接触 Caddy 的密钥库，替代方案是「复制证书 + 定时同步」
  > （多一个 timer 单元，续期最迟一个周期后生效）。当前设计选择了「符号链接 + 即时生效」。
