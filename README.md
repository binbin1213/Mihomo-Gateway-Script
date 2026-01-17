# Mihomo Gateway 部署脚本

自动部署 Mihomo (Clash Meta) 作为透明网关的 Shell 脚本。

## 工作原理

```
┌─────────┐     ┌─────────────┐     ┌─────────────┐
│  客户端  │ ──→ │  Mihomo网关  │ ──→ │  规则分流   │
└─────────┘     └─────────────┘     └─────────────┘
                      │                     │
                      ↓                     ↓
                  DNS服务              国内直走/国外代理
                      │
                      ↓
                  广告拦截（内置）
```

**核心流程：**
1. 客户端将网关和 DNS 指向 Mihomo IP
2. 所有流量经过 Mihomo 网关
3. 根据规则自动分流（国内直连，国外走代理）
4. 支持策略组自动测速选择最优节点

**广告拦截机制：**
- Mihomo 内置广告拦截规则（Block.list），无需额外配置
- 可选集成 AdGuardHome 获得更强大的过滤能力（详见下方说明）

## 快速开始

```bash
# 下载脚本（配置模板会在首次运行时自动下载）
curl -O https://raw.githubusercontent.com/binbin1213/Mihomo-Gateway-Script/main/deploy-mihomo-optimized.sh
chmod +x deploy-mihomo-optimized.sh

# 运行部署（自动选择 Docker 或 Binary 模式）
sudo ./deploy-mihomo-optimized.sh
```

> **提示**：首次运行时，脚本会自动从 GitHub 下载配置模板（`config.yaml.tpl` 或 `config-region.yaml.tpl`）。如需使用代理加速，可在部署向导中启用 GitHub 代理选项。

## 部署模式

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| Docker | 使用官方镜像，容器隔离 | 所有 Linux 系统，**推荐** |
| Binary | 直接运行二进制，systemd 管理 | 固定服务器，性能优先 |

```bash
# 指定模式部署
sudo ./deploy-mihomo-optimized.sh --mode docker   # Docker 模式
sudo ./deploy-mihomo-optimized.sh --mode binary   # Binary 模式
```

## 部署向导

运行脚本后，按提示输入以下信息：

| 配置项 | 说明 | 示例 |
|--------|------|------|
| 物理网卡 | 连接局域网的网卡名称 | `eth0`、`ens33` |
| 默认网关 | 局域网网关 IP | `192.168.1.1` |
| 局域网网段 | CIDR 格式 | `192.168.1.0/24` |
| Mihomo IP | 旁路网关 IP（需未占用） | `192.168.1.98` |
| Mihomo 镜像 | Docker 镜像地址 | `metacubex/mihomo:latest` |
| 配置目录 | 配置文件存放位置 | `/opt/mihomo` |
| GitHub 代理 | 加速资源下载（可选） | `https://gh-proxy.com` |
| **AdGuardHome 集成** | 上游 DNS 过滤（可选） | `192.168.1.x` / 留空 |
| **配置模板类型** | 基础/地区分组 | `basic` / `region` |
| **地区分组策略** | 启用地区节点分组（仅 region 模板） | `yes` / `no` |
| Smart 策略 | 智能选择策略（实验性） | `yes` / `no` |
| 订阅链接 | 机场订阅地址 | `https://xxx` |
| 控制面板密钥 | API 访问密钥 | 自定义字符串 |
| 内置面板 | Web UI 选择 | `metacubexd` / `zashboard` / `none` |

## 配置模板对比

| 模板 | 说明 | 适用场景 |
|------|------|----------|
| `basic` | 基础模板，策略组简洁 | 入门使用，配置简单 |
| `region` | 地区分组模板，支持按地区选节点 | 多节点订阅，精细分流 |

**地区分组策略组（region 模板）：**

| 地区 | 手选 | 自动测速 | 故障转移 |
|------|------|----------|----------|
| 香港 | ✅ | ✅ | ✅ |
| 台湾 | ✅ | ✅ | ✅ |
| 日本 | ✅ | ✅ | ✅ |
| 新加坡 | ✅ | ✅ | ✅ |
| 韩国 | ✅ | ✅ | ✅ |
| 美国 | ✅ | ✅ | ✅ |
| 英国 | ✅ | ✅ | ✅ |
| 其他 | ✅ | ✅ | ✅ |

## AdGuardHome 集成说明

### 什么是 AdGuardHome 集成？

AdGuardHome 是一个网络范围的广告和追踪器屏蔽软件。本项目支持将其作为 Mihomo 的上游 DNS 服务器。

### 架构对比

**不使用 AdGuardHome（默认）：**
```
设备 → Mihomo → 公共DNS（223.5.5.5/119.29.29.29）
               ↓
         内置广告拦截（Block.list）
```

**使用 AdGuardHome：**
```
设备 → Mihomo → AdGuardHome → 公共DNS
               ↓              ↓
         内置拦截      额外过滤层
```

### 功能对比

| 功能 | Mihomo 内置 | + AdGuardHome |
|------|-------------|---------------|
| 广告拦截 | ✅ Block.list | ✅✅ 双重过滤 |
| 自定义规则 | ⚠️ 需手动编辑 | ✅ Web 界面 |
| 查询日志 | ❌ | ✅ 详细日志 |
| 全屋过滤 | ❌ 仅 Mihomo 设备 | ✅ 所有设备 |

### 如何选择？

**不需要 AdGuardHome：**
- 只用 Mihomo 网关的设备上网
- 对广告拦截要求不高
- 希望配置简单

**需要 AdGuardHome：**
- 家庭网络多设备需要过滤
- 需要精细控制每个设备的 DNS
- 需要 Web 界面管理规则
- 需要查看 DNS 查询日志

### 配置示例

部署时输入 AdGuardHome IP（如 `192.168.1.98`），生成的配置：

```yaml
# DNS 配置
nameserver:
  - 192.168.1.98    # AdGuardHome
  - 192.168.1.1    # 备用网关

# 规则配置
- IP-CIDR,192.168.1.98/32,DIRECT,no-resolve  # 访问 AdGuardHome 直连
```

### 注意事项

1. AdGuardHome 需要单独部署，脚本不自动安装
2. AdGuardHome IP 必须在局域网内且可访问
3. 启用后，所有 DNS 查询会多跳一跳，延迟略有增加
4. 不影响 Mihomo 自带的 Block.list 广告拦截功能

## 客户端配置

部署完成后，修改客户端网络设置：

```
网关: 192.168.1.98    # 你的 Mihomo IP
DNS:  192.168.1.98    # 你的 Mihomo IP
```

**Windows:**
```
设置 → 网络和 Internet → 以太网 → 编辑
```

**macOS:**
```
系统设置 → 网络 → 以太网 → 详情 → TCP/IP → 配置 IPv4
```

**Linux:**
```bash
sudo route add default gw 192.168.1.98
```

## 控制面板

访问 `http://<Mihomo IP>:19090/ui` 使用内置管理面板。

| 功能 | 说明 |
|------|------|
| 节点选择 | 切换代理节点 |
| 策略组 | 管理分流规则 |
| 连接测试 | 测速节点延迟 |
| 规则测试 | 查询域名匹配规则 |

**面板类型：**
- `metacubexd` - MetaCubeX 官方面板，功能全面
- `zashboard` - 第三方面板，界面简洁
- `none` - 不安装面板，仅使用 API

## 常用命令

```bash
# 试运行（不实际执行）
./deploy-mihomo-optimized.sh --dry-run

# 详细输出模式
./deploy-mihomo-optimized.sh --verbose

# 卸载
sudo ./deploy-mihomo-optimized.sh --uninstall
```

## Docker 模式管理

```bash
# 查看容器状态
docker ps | grep mihomo

# 查看日志
docker logs -f mihomo

# 重启容器
docker restart mihomo

# 停止容器
docker stop mihomo

# 进入容器
docker exec -it mihomo sh
```

## Binary 模式管理

```bash
# 查看服务状态
systemctl status mihomo

# 启动/停止/重启
systemctl start/stop/restart mihomo

# 查看日志
journalctl -u mihomo -f

# 开机自启
systemctl enable mihomo
```

## 配置文件位置

**Docker 模式：**
| 位置 | 说明 |
|------|------|
| `/opt/mihomo/` | 默认配置目录（宿主机） |
| `/volume1/docker/mihomo/` | DSM 系统配置目录 |
| `/root/.config/mihomo/` | 容器内配置目录 |

**Binary 模式：**
| 位置 | 说明 |
|------|------|
| `/etc/mihomo/` | 配置目录 |
| `/etc/mihomo/config.yaml` | 主配置文件 |
| `/usr/local/bin/mihomo` | 二进制文件 |
| `/etc/systemd/system/mihomo.service` | systemd 服务文件 |

## 故障排查

**容器/服务未启动：**
```bash
# Docker 模式
docker logs mihomo

# Binary 模式
journalctl -u mihomo -n 50
```

**客户端无法上网：**
1. 检查网关和 DNS 是否指向 Mihomo IP
2. 确认订阅链接有效，节点可用
3. 查看 Mihomo 日志确认规则加载

**控制面板无法访问：**
```bash
# 检查 API 端口
curl http://192.168.1.98:19090

# 检查密钥是否正确
curl -H "Authorization: Bearer <你的密钥>" http://192.168.1.98:19090/configs
```

## 特性说明

- ✅ **自动检测** - 智能识别网络配置和系统环境
- ✅ **配置备份** - 重新部署自动备份旧配置
- ✅ **健康检查** - 部署后验证服务状态和代理功能
- ✅ **安全加固** - 输入验证、文件校验和、权限检查
- ✅ **一键卸载** - 完整清理所有相关文件和服务

## 相关链接

- [Mihomo 官方文档](https://wiki.metacubex.one/)
- [Meta 规则集](https://github.com/MetaCubeX/meta-rules-dat)
- [metacubexd 面板](https://github.com/MetaCubeX/metacubexd)

## 许可证

MIT License
