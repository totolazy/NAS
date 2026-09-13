# Mac mini 端接入注意事项

> 这份文档说明两件事：**国外服务器那边是怎么做的**，以及**Mac mini 要怎么做才能对接上**。
> 不涉及脚本，照着做即可。

---

## 一、国外服务器这边是怎么实现的

### 1.1 先看一个绕不过去的问题

Mac mini 放在家里，家用宽带**通常没有公网 IP**，它躲在路由器的 NAT 后面。
所以国外服务器**没有办法主动连到 Mac mini**——不管用什么工具都一样，这是网络结构决定的，不是软件问题。

解决办法只有一个方向：**让 Mac mini 主动连出来。**

### 1.2 于是这台服务器上跑了一个 frp 服务端

国外服务器（`91.223.119.169`）上跑着 **frps**，监听 `7000` 端口，等 Mac mini 来连。

Mac mini 上跑 **frpc**，主动连上 `91.223.119.169:7000`，然后说："把我在本地的 22 端口（SSH）挂到你那边去。"

frps 就在服务器本机上开一个端口 `12222`，任何连到 `127.0.0.1:12222` 的流量，都会被沿着 Mac mini 自己建立的那条连接，送回 Mac mini 的 22 端口。

### 1.3 链路长这样

```
   国外服务器 91.223.119.169                        你家的 Mac mini
  ┌────────────────────────────┐                 ┌──────────────────┐
  │  rclone / rsync            │                 │                  │
  │    │ 连 127.0.0.1:12222   │                 │   sshd :22       │
  │    ▼                       │                 │     ▲            │
  │  frps  监听 :7000  ◀───────┼──── Mac mini ───┼─────┘            │
  │        远程端口 12222      │   主动连出来     │  frpc            │
  └────────────────────────────┘                 └──────────────────┘
                                    ↑
                        这条连接是 Mac mini 发起的，
                        所以能穿过它家的 NAT
```

### 1.4 两个刻意的安全设置

| 设置 | 作用 |
|---|---|
| `proxyBindAddr = "127.0.0.1"` | 远程端口 12222 **只绑在服务器本机**，不对外网开放。Mac mini 的 SSH **不会**被暴露到公网，只有服务器自己能连。 |
| `allowPorts = [12222]` | 只允许注册这一个端口。即使 token 泄露，别人也不能拿这台服务器当公共 frp 服务端用。 |

### 1.5 回传是怎么触发的

1. qBittorrent / aria2 下载完成 → 容器内的钩子在 `/var/lib/nas-n/trigger` 里放一个标记文件；
2. 服务器的 systemd 监听这个目录（实测约 4~5 秒触发），启动回传任务；
3. 回传脚本扫描下载目录，挑出「已完成且已经静止 120 秒」的资源；
4. 用 rclone 通过 `127.0.0.1:12222` 推到 Mac mini 的对应目录；
5. 校验通过后记一笔账，**24 小时后自动删掉服务器上的本地副本**。

另外每 5 分钟还有一次兜底扫描，所以就算钩子漏了也不会丢任务。

---

## 二、Mac mini 要做什么

一共四步，都不难。

### 第 1 步：打开远程登录，准备一个账号

系统设置 → 通用 → 共享 → **远程登录**，打开。

然后准备一个专门用来收文件的账号（当前配置里用的是 **`nas`**）。这个账号必须对目标目录有**写权限**。

> 目标目录当前约定为：
> - `/Volumes/Media/Downloads/torrents`（qBittorrent 下载的资源）
> - `/Volumes/Media/Downloads/aria2`（aria2 下载的资源）

这两个目录要**先建好**。名字想改也可以，改完告诉服务器那边同步改配置就行。

### 第 2 步：把服务器的公钥加进去

国外服务器上生成的公钥是这一行：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHHujLZThRja/PEiJRoaGixkUykzeHkTdpT69A2d/1e5 nas-n@localhost
```

在 Mac mini 上（用 `nas` 账号登录后）把它追加到 `~/.ssh/authorized_keys`：

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# 把上面那行公钥粘贴进去
vi ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

这样服务器才能免密登录进来传文件。

### 第 3 步：跑 frpc

Mac mini 需要一个 frpc 客户端，配置内容是固定的这几项：

```toml
# 文件位置随意，例如 /opt/frp/frpc.toml
serverAddr = "91.223.119.169"
serverPort = 7000

auth.method = "token"
auth.token  = "AfT7izKYNNseWlqDQqalEk2HvpbrfuL0"

transport.protocol = "tcp"
transport.tcpMux   = true

log.to    = "/var/log/frpc.log"
log.level = "info"

[[proxies]]
name       = "macmini-ssh"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 22
remotePort = 12222        # ★ 必须和服务器约定的一致
```

其中三个值要对齐：

| 项目 | 值 |
|---|---|
| 服务器地址 | `91.223.119.169` |
| 服务器端口 | `7000` |
| token | `AfT7izKYNNseWlqDQqalEk2HvpbrfuL0` |
| remotePort | `12222` |

**怎么让它常驻？** macOS 没有 systemd，用 launchd。新建一个文件
`~/Library/LaunchAgents/com.nasn.frpc.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nasn.frpc</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/frp/frpc</string>
    <string>-c</string>
    <string>/opt/frp/frpc.toml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
```

然后：

```bash
launchctl load -w ~/Library/LaunchAgents/com.nasn.frpc.plist
```

> **frpc 去哪里下**：`github.com/fatedier/frp/releases`，建议和服务器用同一版本 `v0.71.0`。
> 注意服务器上那份 `frpc` 是 **Linux** 二进制，macOS 用不了，要下对应包：
> Intel 芯片选 `frp_0.71.0_darwin_amd64.tar.gz`，
> Apple 芯片（M 系列）选 `frp_0.71.0_darwin_arm64.tar.gz`。
> 解压后把 `frpc` 放到 `/opt/frp/` 即可。

### 第 4 步：开启自动挂载（如果目标盘是外置盘）

如果 `/Volumes/Media` 是外置硬盘，务必确认它**开机自动挂载**。
否则 Mac mini 一重启，盘没挂上，rclone 会把文件写进内置盘里同名的空目录——看起来传成功了，其实文件跑到别的地方去了。

最简单的判断方法：重启后执行 `ls /Volumes/Media/Downloads`，能看到目录内容才算挂上了。

---

## 三、macOS 上特有的三个坑

### 坑 1：休眠会中断传输

Mac mini 默认会睡眠。回传大文件时一旦睡眠，连接就断了。

```bash
sudo pmset -a sleep 0 disksleep 0
```

或者在需要的时候挂一个 `caffeinate -s` 守着。

### 坑 2：TCC 权限（完全磁盘访问）

macOS 的隐私保护会拦住 sshd 写入某些目录，表现是**能登录、但写文件报 permission denied**。

解决办法：系统设置 → 隐私与安全性 → **完全磁盘访问权限**，把 `/usr/libexec/sshd-keygen-wrapper` 加进去并勾选。

### 坑 3：时间不同步会导致认证失败

时间偏差太大会导致 frp 连接和 SSH 校验出问题：

```bash
sudo systemsetup -setusingnetworktime on
```

另外，如果目标盘是机械 USB 硬盘，写入速度往往只有 100~150MB/s，这会是整个回传链路的瓶颈——不是网络的问题。

---

## 四、怎么确认接通了

按顺序检查，哪一步不对就修哪一步。

**① 在 Mac mini 上：frpc 连上了吗**

```bash
tail -f /var/log/frpc.log
```

看到 `login to server success` 和 `start proxy success` 就说明连上了。

**② 在国外服务器上：端口出现了吗**

```bash
ss -tlnp | grep 12222
```

有监听 = Mac mini 已经挂上来了。这一步没出现，后面都不用试。

**③ 在国外服务器上：真的能登进 Mac mini 吗**

```bash
ssh -p 12222 -i /etc/nas-n/ssh/id_ed25519 \
    -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    nas@127.0.0.1 'uname -a; df -h /Volumes/Media'
```

打印出 `Darwin` 就说明链路完全通了。

**④ 在国外服务器上：跑一次回传看看**

```bash
./nas-n.sh transfer --force
tail -f /var/lib/nas-n/logs/transfer.log
```

---

## 五、常见故障对照

| 现象 | 原因 |
|---|---|
| frpc 报 `connect: connection refused` | 服务器安全组没放行 `7000/tcp`，或 frps 没跑 |
| frpc 报 `token mismatch` | token 抄错了，必须和服务器上完全一致 |
| frpc 报 `port already used` | 12222 被占用了，或者已经有一个 frpc 在跑 |
| 服务器上 `ssh` 报 `Permission denied` | Mac mini 没加公钥，或用户名不对 |
| 能登录但写文件失败 | 目标目录权限不对，或 TCC 完全磁盘访问没开 |
| 服务器上 `ss \| grep 12222` 一直没输出 | Mac mini 的 frpc 没起来 |
| 传完发现 Mac mini 上找不到文件 | 外置盘没挂载，文件写进内置盘了 |

---

## 六、参数速查

| 项目 | 值 |
|---|---|
| 国外服务器 | `91.223.119.169` |
| frps 端口 | `7000`（需在云安全组放行 TCP） |
| frp token | `AfT7izKYNNseWlqDQqalEk2HvpbrfuL0` |
| Mac mini 的 remotePort | `12222` |
| 服务器上的回传入口 | `127.0.0.1:12222`（仅本机，不对外） |
| 回传使用的账号 | `nas` |
| 目标目录 | `/Volumes/Media/Downloads/torrents`、`/Volumes/Media/Downloads/aria2` |
| 服务器本地副本保留 | 回传成功后 24 小时自动删除 |

服务器端如果改了这些值，改的是 `/etc/nas-n/nas-n.conf`，改完在服务器上执行
`./nas-n.sh reconfigure` 重新生成配置。
