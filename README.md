# NAS 反向隧道

把**家里的 Mac mini** 上的服务，通过一台**有公网 IP 的国内服务器**暴露到公网域名上。
公网段用 **Hysteria2（UDP/QUIC）** 承载，反向端口映射用 **frp**，HTTPS 由 **Caddy** 自动签发与续期。

```
观众 ──TCP/443──► Caddy(服务器)                UDP/443 ◄── QUIC 加密隧道 ── Mac mini
                  │  <域名> 站点块                                        │
                  └► reverse_proxy 127.0.0.1:15244                       │
                                        ▲                                │
                                   frps(服务器 127.0.0.1:7000) ◄── 经隧道登录 ── frpc(Mac)
                                                                         │
                                            hysteria 客户端 socks5 ◄─────┘
                                                  (Mac) ──► OpenList 127.0.0.1:5244
```

**Mac↔服务器 的公网段是纯 UDP，一个 TCP 包都不出去。**
frpc 不直连服务器，而是把 `CONNECT 127.0.0.1:7000` 交给本机 Hysteria2 的 socks5 入站，
由服务器端的 Hysteria2 进程在服务器本机拨号到 frps——这也是公网只出现 UDP 的原因。

---

## 为什么是两层

Hysteria2 **v2 不支持反向隧道**（v1 的 `tcpForwarding` 在 v2 已被官方移除），
所以拆成两层：HY2 负责「怎么过公网」（UDP/QUIC + Brutal 拥塞控制，抗丢包抢带宽），
frp 负责「把内网哪个端口接到服务器」。frp 跑在 HY2 隧道内部，公网不可见。

---

## 目录

| 路径 | 说明 |
| --- | --- |
| `deploy-nas-tunnel.sh` | **服务器端一键部署脚本**（本仓库的主角）：装 hysteria/frps、写 systemd 单元、改 Caddyfile、等证书、跑两级端到端自检、生成 Mac 端对接包 |
| `NAS-TUNNEL-对接说明.md` | 设计说明 + Mac 端对接契约（参数清单、配置要点、性能调优、排错对照表） |
| `mac/README.md` | **Mac mini 端部署说明**：装什么、怎么配、怎么自启、怎么自查 |
| `mac/*.example` | Mac 端配置脱敏模板（`hysteria-client.yaml` / `frpc.toml`） |
| `mac/*.plist` | Mac 端 launchd 开机自启模板 |
| `deploy-openlist.sh` | 另一个独立脚本：在服务器本机部署 OpenList + Caddy 反代（与本隧道无关，可单独使用） |

---

## 快速开始

### 1. 服务器端

```bash
git clone https://github.com/totolazy/NAS.git && cd NAS
sudo bash deploy-nas-tunnel.sh
```

交互式会问你域名、证书邮箱、UDP 端口等。也可以非交互：

```bash
sudo bash deploy-nas-tunnel.sh -d sh.example.com -e you@example.com
```

跑完后：

```bash
bash deploy-nas-tunnel.sh --status           # 打印 Mac 端需要的 6 项参数
bash deploy-nas-tunnel.sh --self-test-only   # 只重跑端到端自检
bash deploy-nas-tunnel.sh --uninstall        # 完全卸载并还原 Caddyfile
```

### 2. Mac mini 端

见 [`mac/README.md`](mac/README.md)。服务器会生成一份**已填好真实参数**的对接包在
`/root/nas-tunnel-mac-client/`，拷到 Mac 直接用最省事。

---

## 部署前必须手动做的两件事

1. **Cloudflare** 给域名加 A 记录指向服务器公网 IP，并**关闭小云朵（仅 DNS）**
   —— TLS-ALPN 挑战穿不过 CF 代理，橙云一定签不下证书
2. **云服务器安全组放行 UDP 443 入站**（TCP 80/443 本来就通）
   —— 这是最容易漏的一步：脚本自检走的是回环、绕过安全组，所以漏了的表现是
   **「脚本全绿但 Mac 连不上」**

域名还需完成 ICP 备案，否则国内云厂商会拦截 80/443 导致证书签发失败。

---

## 安全边界

- 公网只开 TCP 443（Caddy）与 UDP 443（Hysteria2）
- frps 控制口与映射口**全部绑定 127.0.0.1**，公网无任何额外暴露端口
- Hysteria2：密码认证 + `sniGuard: strict`（SNI 必须匹配证书）
- frp：token 认证（回环内仍保留，双保险）
- 脚本只管理 Caddyfile 中带 `nas-tunnel-managed` 标记的区块，**绝不动其他站点**
- 支持幂等重跑：沿用既有密码/token，不重置已部署的隧道

---

## 环境要求

| | |
| --- | --- |
| 服务器 | Debian/Ubuntu、systemd、x86_64、已装 Caddy（v2.x） |
| Mac | Apple Silicon 或 Intel、macOS |
