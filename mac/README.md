# Mac mini 端部署说明

配合服务器端的 [`deploy-nas-tunnel.sh`](../deploy-nas-tunnel.sh) 使用。

服务器端负责公网入口（Caddy + 证书 + frps + Hysteria2 服务端）；
**Mac mini 端负责主动连出去，把本机 OpenList 挂上那条隧道。**

---

## 一、为什么要两个进程

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

## 二、先拿到参数

在**服务器**上执行：

```bash
bash deploy-nas-tunnel.sh --status
```

会打印这 6 项（也会写进 `/root/nas-tunnel-info.txt`）：

| 参数 | 说明 | 本仓库里的占位符 |
| --- | --- | --- |
| 服务器公网 IP | | `<服务器公网IP>` |
| Hysteria2 UDP 端口 | 默认 `443` | `<HY2端口>` |
| Hysteria2 密码 | 32 位随机 | `<HY2密码>` |
| 域名 / TLS SNI | | `<域名>` |
| frp token | 32 位随机 | `<frp_token>` |
| 远端映射端口 | 默认 `15244` | `<远端端口>` |

另外两项是约定值（也可在服务器端改）：

| 参数 | 默认 |
| --- | --- |
| Mac 端 socks5 入站 | `127.0.0.1:1080`（用户名/密码见 `--status`） |
| Mac 上 OpenList | `127.0.0.1:5244` |

> 服务器还会生成一份**已填好真实参数的对接包**在 `/root/nas-tunnel-mac-client/`，
> 直接拷到 Mac 用最省事。本仓库里的 `*.example` 是脱敏模板，需要自己替换占位符。

---

## 三、安装二进制（Apple Silicon）

```bash
# hysteria（同一二进制既可做服务端也可做客户端）
curl -fsSL -o hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-darwin-arm64
chmod +x hysteria
sudo install -m 755 hysteria /usr/local/bin/hysteria

# frp（取你要的版本，服务器端会告诉你具体版本号）
curl -fsSL -o frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_darwin_arm64.tar.gz
tar -xzf frp.tar.gz
sudo install -m 755 frp_0.71.0_darwin_arm64/frpc /usr/local/bin/frpc

# 验证
hysteria version
frpc --version
```

Intel Mac 把 `darwin-arm64` 换成 `darwin-amd64`。

---

## 四、写配置

```bash
sudo mkdir -p /usr/local/etc/nas-tunnel
sudo cp mac/hysteria-client.yaml.example /usr/local/etc/nas-tunnel/hysteria-client.yaml
sudo cp mac/frpc.toml.example          /usr/local/etc/nas-tunnel/frpc.toml
sudo chmod 600 /usr/local/etc/nas-tunnel/*.yaml /usr/local/etc/nas-tunnel/*.toml
```

然后把两个文件里的 `<...>` 占位符替换成第二步拿到的真实值。

### 必须改对/别改错的几处

| 项 | 要求 | 原因 |
| --- | --- | --- |
| `tls.sni` | **必须等于域名** | 服务器开了 `sniGuard: strict`，SNI 不匹配会直接断开 |
| `tls.insecure` | 通常 `false` | 服务器复用 Caddy 签发的真证书；**仅当服务器报告自签降级时才改 `true`** |
| `bandwidth` | **不能省** | 省了 Hysteria2 会退回 BBR，拿不到 Brutal 的抗丢包/抢带宽效果 |
| `bandwidth.up` | 你家宽上行实测值 | 填太大会让 Brutal 的丢包补偿猛冲，**反而更慢更抖更费流量** |
| `serverAddr` | **必须是 `127.0.0.1`** | 写服务器 IP 会让 frpc 绕过隧道直连，白搭 |
| `transport.proxyURL` | 必须指向 hysteria 的 socks5 入站 | 同上 |
| `transport.tls.enable` | `false` | HY2 已端到端加密，frp 再套 TLS 只是白耗 CPU |

---

## 五、launchd 开机自启

```bash
sudo cp mac/com.nas.tunnel.hysteria.plist /Library/LaunchDaemons/
sudo cp mac/com.nas.tunnel.frpc.plist     /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.nas.tunnel.*.plist
sudo chmod 644        /Library/LaunchDaemons/com.nas.tunnel.*.plist

# 先起 hysteria，再起 frpc
sudo launchctl load -w /Library/LaunchDaemons/com.nas.tunnel.hysteria.plist
sleep 3
sudo launchctl load -w /Library/LaunchDaemons/com.nas.tunnel.frpc.plist
```

两个 plist 都设了 `KeepAlive`，进程挂了会自动拉起。
卸载：`sudo launchctl unload -w /Library/LaunchDaemons/com.nas.tunnel.frpc.plist`（同理 hysteria）。

---

## 六、起来之后怎么确认

### 在 Mac 上

```bash
# 1) 隧道本身通不通（应返回 200/301/302）
curl -x socks5h://127.0.0.1:1080 -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com

# 2) frpc 是否登录成功 / 是否登记了 openlist
grep -i 'login to server success\|openlist' /var/log/frpc.log

# 3) OpenList 本身在不在
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5244/
```

### 在服务器上

```bash
ss -tln | grep 15244        # 出现 LISTEN 说明隧道登记成功
curl -s -o /dev/null -w '%{http_code}\n' https://<域名>/   # 应返回 200
```

---

## 七、故障对照表

| 症状 | 含义 | 处理 |
| --- | --- | --- |
| 浏览器访问域名一直 **502** | Caddy 和隧道都正常，但**没有 frpc 登记**（`127.0.0.1:15244` 无人监听） | 就是本文档要解决的事：把 hysteria + frpc 跑起来 |
| 隧道 curl 一直挂 / 超时 | UDP 被挡或参数错 | 先确认**服务器安全组放行了 UDP 443 入站**（最常见）；再核对密码、`tls.sni` |
| frpc 报 `login to server failed` | token 不对，或 socks5 没起来 | 核对 `auth.token`；确认 hysteria 已在 `127.0.0.1:1080` 监听 |
| frpc 起来了但访问仍 502 | 端口没对上 | 核对 `remotePort`（应 = 服务器 `15244`）、`localPort`（应 = Mac 上 OpenList 端口） |
| 速度慢、抖动大 | `bandwidth.up` 远高于实际链路 | 下调到实测家宽上行的 ~80% |
| 能连但过一会儿断 | 家宽 NAT 会话超时 | 两个进程的 `KeepAlive` 都保持开启即可 |

---

## 八、安全注意

- OpenList 在 Mac 上**只监听 `127.0.0.1:5244`**，不要绑 `0.0.0.0`——否则局域网内可绕过隧道直连
- `/usr/local/etc/nas-tunnel/` 下两个配置文件含密码/token，权限设 `600`
- 本仓库里的 `*.example` 是**脱敏模板**，请勿把填好真实密钥的配置文件提交上来
