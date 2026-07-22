# proxy-config — Linux 全局代理自动配置脚本

生产就绪的 Linux 代理配置工具，一键配置系统全局代理、Docker 代理及所有常用开发工具代理。

## 功能概览

| 组件 | 配置方式 | 需要 root |
|------|----------|-----------|
| **系统环境变量** | `/etc/profile.d/proxy.sh` + `/etc/environment` | ✅ |
| **APT** (Debian/Ubuntu) | `/etc/apt/apt.conf.d/99proxy` | ✅ |
| **DNF/YUM** (RHEL/Fedora) | `/etc/dnf/dnf.conf` 或 `/etc/yum.conf` | ✅ |
| **Docker 守护进程** | systemd drop-in + 自动重启服务 | ✅ |
| **Docker 客户端** | `~/.docker/config.json` (JSON 合并) | ❌ |
| **systemd 全局环境** | `/etc/systemd/system.conf.d/proxy.conf` | ✅ |
| **Git** | `git config --global http.proxy` | ❌ |
| **npm** | `npm config set proxy` | ❌ |
| **pip** (Python) | `/etc/pip.conf` + 用户级 `pip.conf` | ✅/❌ |
| **curl** | `~/.curlrc` | ❌ |
| **wget** | `/etc/wgetrc` | ✅ |
| **Snap** | `snap set system proxy` | ✅ |
| **containerd** | `/etc/containerd/config.toml` | ✅ |
| **当前 Shell** | 直接 export 环境变量 | ❌ |

## 快速开始

### 交互模式（推荐）

```bash
sudo ./proxy-config.sh
```

按提示输入代理服务器地址即可。

### 命令行模式

```bash
# 配置代理
sudo ./proxy-config.sh --proxy http://10.0.0.10:1082

# 使用 SOCKS5 代理
sudo ./proxy-config.sh --proxy socks5://192.168.1.1:1080

# 带认证的代理
sudo ./proxy-config.sh --proxy http://user:pass@proxy.example.com:8080

# 自定义 NO_PROXY 排除列表
sudo ./proxy-config.sh --proxy http://10.0.0.10:1082 \
    --no-proxy "localhost,127.0.0.1,.internal,10.0.0.0/8"
```

### 模拟运行（查看将要执行的操作）

```bash
sudo ./proxy-config.sh --dry-run --proxy http://10.0.0.10:1082
```

### 移除所有代理配置

```bash
sudo ./proxy-config.sh --remove
```

### 使用配置文件

```bash
sudo ./proxy-config.sh --config proxy.conf
```

配置文件示例见 `proxy-config.conf.example`。

## 支持的发行版

| 发行版 | 包管理器 | 测试状态 |
|--------|----------|----------|
| Debian 10+ | apt | ✅ |
| Ubuntu 20.04+ | apt | ✅ |
| RHEL/CentOS 7 | yum | ✅ |
| RHEL/Rocky/Alma 8+ | dnf | ✅ |
| Fedora 36+ | dnf | ✅ |
| Arch Linux | pacman | ✅ (通过环境变量) |
| openSUSE | zypper | ✅ (通过环境变量) |
| Alpine | apk | ⚠️ (通过环境变量) |

## 特性

### 🔒 生产就绪
- **自动备份**: 修改前自动备份所有配置文件（带时间戳）
- **模拟运行**: `--dry-run` 模式预览所有操作
- **幂等操作**: 可安全重复执行，不会产生重复配置
- **错误处理**: 严格的错误检查和清晰的错误消息
- **日志记录**: 同时输出到终端和日志文件

### 🎯 智能检测
- 自动识别 Linux 发行版和包管理器
- 检测已安装的应用，仅配置存在的组件
- 跳过不适用的配置（如非 Debian 系统跳过 APT）

### 🎨 用户体验
- 彩色终端输出（支持 `--no-color` 禁用）
- 交互式引导模式和命令行模式
- 执行后显示完整配置总结
- 可选的代理连通性测试

### 🔧 运维友好
- 所有被修改的配置均带有管理标记
- 使用 `--remove` 一键清除所有代理配置
- 备份文件带有时间戳，可追溯
- 单个脚本文件，易于分发和审查

## 选项参考

```
用法: sudo proxy-config.sh [选项]

选项:
  --proxy, -p <URL>      代理地址
  --no-proxy <LIST>      NO_PROXY 排除列表
  --remove, -r           移除所有代理配置
  --dry-run, -n          模拟运行
  --backup-dir <DIR>     备份目录
  --log-file <FILE>      日志文件路径
  --no-color             禁用彩色输出
  --non-interactive      非交互模式
  --config, -c <FILE>    从配置文件读取
  --version, -v          版本信息
  --help, -h             帮助信息
```

## 配置的文件清单

执行后，脚本会修改以下位置（视系统环境而定）：

| 文件/命令 | 用途 |
|-----------|------|
| `/etc/profile.d/proxy.sh` | 所有用户的 shell 代理环境变量 |
| `/etc/environment` | PAM 会话代理环境变量 |
| `/etc/apt/apt.conf.d/99proxy` | APT 包管理器代理 |
| `/etc/dnf/dnf.conf` | DNF 包管理器代理 |
| `/etc/yum.conf` | YUM 包管理器代理 |
| `/etc/systemd/system/docker.service.d/http-proxy.conf` | Docker 守护进程代理 |
| `~/.docker/config.json` | Docker 客户端代理 |
| `~/.gitconfig` | Git 全局代理 |
| `~/.npmrc` | npm 代理 |
| `/etc/pip.conf` | pip 全局代理 |
| `~/.curlrc` | curl 代理配置 |
| `/etc/wgetrc` | wget 全局代理 |
| `/etc/systemd/system.conf.d/proxy.conf` | systemd 全局环境代理 |
| snap 系统设置 | Snap 包管理器代理 |

## 备份与恢复

所有被修改的文件在修改前都会备份到：

- 系统文件: `/var/backups/proxy-config/`
- 用户文件: `~/.local/share/proxy-config/backups/`

备份文件格式: `<原路径>.<时间戳>.bak`

如需恢复，将备份文件复制回原位置即可：

```bash
sudo cp /var/backups/proxy-config/etc/environment.20260722_140311.bak /etc/environment
```

## 日志

日志文件位置：

- root 执行: `/var/log/proxy-config.log`
- 普通用户: `~/.local/share/proxy-config/proxy-config.log`

## 常见问题

### Q: 执行后当前终端仍无法连接代理？

执行以下命令使代理立即生效：

```bash
source /etc/profile.d/proxy.sh
```

或直接打开新的终端窗口。

### Q: Docker 容器构建时无法拉取镜像？

Docker daemon 代理已自动配置并重启。如果仍有问题：

```bash
sudo systemctl show docker --property Environment
```

确认输出中包含 `HTTP_PROXY` 和 `HTTPS_PROXY`。

### Q: 如何在 CI/CD 中使用？

```bash
# 非交互模式，适合自动化脚本
sudo ./proxy-config.sh \
    --proxy "$PROXY_SERVER" \
    --no-proxy "$NO_PROXY_LIST" \
    --non-interactive
```

### Q: 如何只配置特定应用？

目前脚本采用"全量配置"策略，会自动检测已安装的应用并配置所有支持的组件。如需选择性配置，可以编辑脚本中的 `run_all_configurations` 函数，注释掉不需要的模块。

## 许可

MIT License
