# Alpine Tinyproxy 一键部署

适用于 Alpine Linux 的交互式 Tinyproxy HTTP 代理部署脚本。脚本不限定 Alpine 版本，依赖系统配置好的 APK 软件源和 OpenRC。

## 一键安装

使用 root 登录 Alpine 后运行：

```sh
curl -fsSL https://raw.githubusercontent.com/Cupidzp/tinyproxy-alpine/main/install.sh | sh
```

如果没有 `curl`，可用 Alpine 自带的 `wget`：

```sh
wget -qO- https://raw.githubusercontent.com/Cupidzp/tinyproxy-alpine/main/install.sh | sh
```

脚本会交互询问 TCP 端口、BasicAuth 用户名和密码。默认端口为 `12345`，默认用户名为 `admin`；密码需输入两次且不会回显，长度为 8-128 位，仅支持字母、数字及 `._!@%+=:,~-`。需要先在云安全组或防火墙放行所选 TCP 端口，脚本不会修改云平台规则。

## 功能

- 仅在 Alpine Linux 上运行，使用 `apk` 安装 `tinyproxy` 和 `iproute2-ss`。
- 配置 IPv4 监听；系统启用 IPv6 时同时配置 IPv6。
- 开启 BasicAuth，并允许公网客户端连接。
- 限制 HTTPS `CONNECT` 隧道目标端口为 `443` 和 `563`。
- 使用 OpenRC 启动服务并设为开机自启。
- 覆盖配置前先备份；启动或检查失败时恢复旧配置和服务状态。

## 安全说明

该配置会把代理开放给公网访问，认证密码以明文保存在 `/etc/tinyproxy/tinyproxy.conf`，HTTP 代理认证也可能在客户端到代理服务器这一段以明文传输。请使用至少 16 位的唯一随机密码，并仅通过可信网络连接代理。不要把真实密码提交到 GitHub。

重复运行脚本可以更改端口或凭据。若已有配置，成功更新后旧配置备份会保留在 `/root/tinyproxy-backup.*`。

## 服务管理

```sh
rc-service tinyproxy status
rc-service tinyproxy restart
rc-service tinyproxy stop
ss -ltnp | grep ':12345'
```
