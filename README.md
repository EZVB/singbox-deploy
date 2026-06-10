# Sing-box 多协议一键部署脚本

一个强大的 Sing-box 自动化部署工具，支持SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选部署和线路机 VLESS Reality 中转的完整解决方案。

---

## ✨ 主要特性

### 🎯 部署机功能

- ✅ **一键安装** - 自动部署 Sing-box 最新服务端
- ✅ **自动生成** - 自动生成 密钥和配置文件，Reality 自选或默认SNI
- ✅ **多系统支持** - 支持 Alpine, Debian, Ubuntu, CentOS, RHEL, Fedora 等操作系统
- ✅ **开机自启** - 自动配置 Systemd / OpenRC 开机自启，崩溃自动拉起服务端
- ✅ **连接 IP** - 自动获取公网 IP 或手动输入 连接IP/DDNS域名 并生成客户端链接
- ✅ **管理工具** - 输入 sb 指令进入管理界面查看节点链接、重置端口、服务端控制查看等功能
- ✅ **分流规则** - 支持全部直连、全部代理、国内/私网直连、广告拦截以及自定义域名/IP 规则
- ✅ **链式代理** - 支持新增 SOCKS5/HTTP/Shadowsocks/VLESS Reality 出站，并通过 detour 组成多跳链路

### 🔗 线路机功能

- ✅ **一键生成** - 从落地机直接生成线路机安装脚本
- ✅ **Reality 入站** - 自动部署 VLESS Reality 入站
- ✅ **灵活端口** - 支持自动寻找空闲端口或手动指定
- ✅ **流量转发** - 自动转发流量到落地机SS节点
- ✅ **完整链接** - 生成可用的 VLESS Reality 客户端链接

## ✅ 一键部署命令

安装全功能 sing-box：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/EZVB/singbox-deploy/main/install-singbox-yyds.sh)"
```

## 🔧 分流与链式代理

安装完成后输入 `sb` 进入管理面板：

- `查看出站/分流状态`：查看当前 outbounds、detour 链路和 route 配置
- `新增代理出站节点`：添加 SOCKS5、HTTP、Shadowsocks 或 VLESS Reality 出站
- `设置/取消链式代理`：给指定出站设置上游 `detour`，可组成 `proxy-a -> proxy-b -> direct` 这类多跳链路
- `配置分流规则`：套用国内直连/国外代理、广告拦截等预设，也可以追加自定义 `domain_suffix`、`domain_keyword`、`domain`、`ip_cidr` 规则

常见用法：先新增一个代理出站节点，再在分流规则里选择它作为默认出站；如果需要多跳，则给这个出站设置上游 detour。
