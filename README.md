# realm

易上手realm的一键转发管理脚本，终端菜单式操作，覆盖 realm 官方支持的绝大部分功能：双栈转发、TCP/UDP独立开关、WS/TLS/WSS隧道封装、MPTCP、PROXY protocol、多出口负载均衡、出口IP/网卡绑定，并通过 systemd 托管服务。

## 特性

- **自动装机**：自动识别 CPU 架构（x86_64 / aarch64 / armv7）与 libc（glibc / musl），从 GitHub Releases 拉取最新版 realm 二进制
- **双栈转发**：监听地址可选 IPv4 / IPv6 / 双栈，双栈模式下单个 socket 同时接受 v4 与 v6 连接
- **WS / TLS / WSS 隧道**：监听端与出口端可分别独立配置传输层封装，满足链式中转、CDN 中转等场景
- **多出口负载均衡**：支持 `roundrobin`（轮询）与 `iphash`（同源IP固定出口）两种算法，可自定义各出口权重
- **MPTCP**：支持全局启用，也支持单条规则用 `[endpoints.network]` 单独覆盖
- **PROXY protocol**：收发方向可分别开关，支持 v1/v2
- **出口IP/网卡绑定**：通过 `through` / `interface` 字段，适配多IP、多网卡机器的分流需求
- **规则管理**：每条转发规则用唯一标记包裹，菜单里按序号增删，不会误改其他规则
- **systemd 托管**：开机自启、异常退出自动重启，日志可直接用 `journalctl -u realm -f` 查看

## 快速开始

```bash
wget -O realm-manager.sh https://raw.githubusercontent.com/lanjiangqaq/realm/main/realm-manager.sh
chmod +x realm-manager.sh
sudo ./realm-manager.sh
```

首次运行后，脚本会常驻在当前目录，之后再次管理只需：

```bash
sudo ./realm-manager.sh
```

## 环境要求

- Linux 系统，依赖 **systemd**（Debian / Ubuntu / CentOS / RHEL 等主流发行版均可，暂不支持 OpenRC / Alpine 的服务管理）
- 需要 **root** 权限运行
- 服务器需能正常访问 GitHub（用于拉取 realm 二进制）

## 菜单说明

```
1) 安装 / 更新 realm
2) 添加转发规则 (支持双栈/负载均衡/WS/TLS/WSS/MPTCP)
3) 查看转发规则
4) 删除转发规则
5) 服务管理 (启动/停止/重启/状态/日志)
6) 全局网络设置 (TCP/UDP开关/MPTCP/PROXY protocol/超时)
7) 查看原始配置文件
8) 卸载 realm
```

### 添加转发规则

按提示依次填写即可，全部为交互式问答：

1. 规则备注（用于后续识别）
2. 本地监听端口 + 监听模式（双栈 / 仅IPv4 / 仅IPv6）
3. 出口目标地址；如需负载均衡，可添加多个出口并分别设置权重、选择算法
4. 是否需要 WS / TLS / WSS 隧道封装（监听端、出口端可分别配置）
5. 是否为该规则单独启用 MPTCP
6. 是否绑定指定出口 IP / 网卡

保存后会询问是否立即重启服务生效，可以先加完多条规则再统一重启。

## 文件位置

| 用途 | 路径 |
|---|---|
| realm 可执行文件 | `/etc/realm/realm` |
| 配置文件 | `/etc/realm/config.toml` |
| 日志文件 | `/etc/realm/realm.log` |
| systemd 服务文件 | `/etc/systemd/system/realm.service` |

配置文件是标准的 realm 官方 TOML 格式，可以直接手动编辑，改完后在菜单里重启服务即可生效。字段含义参考 [realm 官方文档](https://github.com/zhboner/realm)。

## 卸载

菜单选项 `8`，会停止服务并删除二进制、配置文件、systemd 服务文件。

## 免责声明

本脚本仅对 [zhboner/realm](https://github.com/zhboner/realm) 做安装与配置管理封装，转发行为的合法合规性由使用者自行负责。
