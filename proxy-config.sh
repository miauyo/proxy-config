#!/usr/bin/env bash
#===============================================================================
# proxy-config.sh — Linux 全局代理自动配置脚本
#===============================================================================
# 版本: 1.0.0
# 许可: MIT
#
# 功能:
#   - 交互式或命令行方式配置 Linux 系统的全局代理
#   - 支持配置: 系统环境变量、APT、Docker、Git、npm、pip、curl、
#     wget、snap、containerd、systemd、DNF/YUM 等
#   - 支持代理移除 (--remove)
#   - 支持模拟运行 (--dry-run)
#   - 自动备份被修改的配置文件
#   - 检测已安装的应用，仅配置存在的组件
#   - 支持认证代理 (user:pass@host:port)
#
# 用法:
#   sudo ./proxy-config.sh                          # 交互模式
#   sudo ./proxy-config.sh --proxy http://10.0.0.10:1082  # 命令行模式
#   sudo ./proxy-config.sh --remove                 # 移除所有代理配置
#   sudo ./proxy-config.sh --dry-run --proxy http://10.0.0.10:1082
#===============================================================================

set -euo pipefail

#===============================================================================
# 常量定义
#===============================================================================
readonly SCRIPT_NAME="proxy-config"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_URL="https://github.com/example/proxy-config"

# 由本脚本管理的文件标记
readonly MARKER="# Managed by proxy-config.sh — do not edit manually"
readonly MARKER_START="# >>> proxy-config.sh managed block >>>"
readonly MARKER_END="# <<< proxy-config.sh managed block <<<"

# 默认备份目录
readonly SYSTEM_BACKUP_DIR="/var/backups/proxy-config"
readonly USER_BACKUP_DIR="${HOME}/.local/share/proxy-config/backups"

# 日志文件
readonly SYSTEM_LOG_DIR="/var/log"
readonly USER_LOG_DIR="${HOME}/.local/share/proxy-config"

#===============================================================================
# 颜色定义
#===============================================================================
declare -A COLORS
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    COLORS=(
        [reset]="\033[0m"
        [bold]="\033[1m"
        [dim]="\033[2m"
        [red]="\033[31m"
        [green]="\033[32m"
        [yellow]="\033[33m"
        [blue]="\033[34m"
        [magenta]="\033[35m"
        [cyan]="\033[36m"
        [white]="\033[37m"
    )
else
    # 无颜色模式
    for key in reset bold dim red green yellow blue magenta cyan white; do
        COLORS[$key]=""
    done
fi

#===============================================================================
# 全局状态变量
#===============================================================================
DRY_RUN=false
REMOVE_MODE=false
INTERACTIVE=true
PROXY_URL=""
PROXY_HOST=""
PROXY_PORT=""
PROXY_PROTO="http"
PROXY_USER=""
PROXY_PASS=""
NO_PROXY="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
BACKUP_DIR=""
LOG_FILE=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONFIG_FILE=""

# 统计计数器
declare -i STAT_CONFIGURED=0
declare -i STAT_SKIPPED=0
declare -i STAT_FAILED=0
declare -i STAT_BACKED_UP=0

#===============================================================================
# 工具函数
#===============================================================================

# 输出信息
print_info()    { echo -e "${COLORS[blue]}[INFO]${COLORS[reset]}    $*"; }
print_success() { echo -e "${COLORS[green]}[OK]${COLORS[reset]}      $*"; }
print_warn()    { echo -e "${COLORS[yellow]}[WARN]${COLORS[reset]}    $*" >&2; }
print_error()   { echo -e "${COLORS[red]}[ERROR]${COLORS[reset]}   $*" >&2; }
print_header()  { echo -e "\n${COLORS[bold]}${COLORS[cyan]}━━━ $* ━━━${COLORS[reset]}"; }
print_dryrun()  { echo -e "${COLORS[dim]}[DRY-RUN]${COLORS[reset]}  $*"; }

# 记录日志 (同时写入终端和日志文件)
log_to_file() {
    if [[ -n "$LOG_FILE" ]] && [[ -d "$(dirname "$LOG_FILE")" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()    { print_info "$@";    log_to_file "[INFO] $*"; }
log_success() { print_success "$@"; log_to_file "[OK] $*"; }
log_warn()    { print_warn "$@";    log_to_file "[WARN] $*"; }
log_error()   { print_error "$@";   log_to_file "[ERROR] $*"; }

# 检查是否以 root 运行
is_root() { [[ $EUID -eq 0 ]]; }

# 检查命令是否存在
command_exists() { command -v "$1" &>/dev/null; }

# 获取适合当前用户的 sudo 包装器
sudo_wrap() {
    if is_root; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        log_error "需要 root 权限执行: $*"
        log_error "请使用 sudo 运行此脚本，或切换到 root 用户"
        return 1
    fi
}

# 创建目录（带 sudo 感知）
ensure_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then return 0; fi
    if $DRY_RUN; then
        print_dryrun "创建目录: $dir"
        return 0
    fi
    if is_root || [[ "$dir" == "$HOME"* ]]; then
        mkdir -p "$dir"
    else
        sudo_wrap mkdir -p "$dir"
    fi
}

# 备份文件
backup_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then return 0; fi

    local backup_path="${BACKUP_DIR}/${file}${TIMESTAMP}.bak"
    local backup_dir
    backup_dir=$(dirname "$backup_path")

    if $DRY_RUN; then
        print_dryrun "备份: $file → $backup_path"
        return 0
    fi

    ensure_dir "$backup_dir"
    if cp "$file" "$backup_path" 2>/dev/null; then
        STAT_BACKED_UP=$((STAT_BACKED_UP + 1))
        log_info "已备份: $file → $backup_path"
        return 0
    else
        log_error "无法备份: $file"
        return 1
    fi
}

# 写入文件（带备份和 dry-run 支持）
write_file() {
    local file="$1"
    local content="$2"
    local desc="${3:-$file}"

    if [[ -f "$file" ]]; then
        local existing
        existing=$(cat "$file" 2>/dev/null || true)
        if [[ "$existing" == "$content" ]]; then
            log_info "$desc — 已是最新，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
            return 0
        fi
    fi

    if $DRY_RUN; then
        print_dryrun "写入: $desc"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    backup_file "$file"

    local dir
    dir=$(dirname "$file")
    ensure_dir "$dir"

    if echo "$content" | sudo_wrap tee "$file" > /dev/null 2>&1; then
        log_success "$desc — 配置完成"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    else
        log_error "$desc — 写入失败"
        STAT_FAILED=$((STAT_FAILED + 1))
        return 1
    fi
}

# 删除文件（带备份和 dry-run 支持）
remove_file() {
    local file="$1"
    local desc="${2:-$file}"

    if [[ ! -f "$file" ]]; then
        log_info "$desc — 文件不存在，跳过"
        STAT_SKIPPED=$((STAT_SKIPPED + 1))
        return 0
    fi

    if $DRY_RUN; then
        print_dryrun "删除: $desc"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    backup_file "$file"
    if sudo_wrap rm "$file"; then
        log_success "$desc — 已移除"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    else
        log_error "$desc — 删除失败"
        STAT_FAILED=$((STAT_FAILED + 1))
        return 1
    fi
}

# 检查文件是否由本脚本管理
is_managed_by_us() {
    local file="$1"
    [[ -f "$file" ]] && grep -qF "$MARKER" "$file" 2>/dev/null
}

# 验证代理 URL 格式
validate_proxy_url() {
    local url="$1"

    if [[ -z "$url" ]]; then
        log_error "代理 URL 不能为空"
        return 1
    fi

    # 基本格式检查: [protocol://][user:pass@]host[:port]
    if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://(.+)$ ]]; then
        PROXY_PROTO="${BASH_REMATCH[1]}"
        url="${BASH_REMATCH[2]}"
    else
        PROXY_PROTO="http"
    fi

    # 提取认证信息
    if [[ "$url" =~ ^([^@]+)@(.+)$ ]]; then
        local auth="${BASH_REMATCH[1]}"
        url="${BASH_REMATCH[2]}"
        if [[ "$auth" =~ ^([^:]+):(.+)$ ]]; then
            PROXY_USER="${BASH_REMATCH[1]}"
            PROXY_PASS="${BASH_REMATCH[2]}"
        else
            PROXY_USER="$auth"
            PROXY_PASS=""
        fi
    fi

    # 提取 host 和 port
    if [[ "$url" =~ ^([^:]+):([0-9]+)$ ]]; then
        PROXY_HOST="${BASH_REMATCH[1]}"
        PROXY_PORT="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^([^:]+)$ ]]; then
        PROXY_HOST="${BASH_REMATCH[1]}"
        PROXY_PORT=""
    else
        log_error "无法解析代理地址: $url"
        return 1
    fi

    # 验证 host
    if [[ -z "$PROXY_HOST" ]]; then
        log_error "代理主机地址不能为空"
        return 1
    fi

    # 验证 hostname 格式: 允许 IPv4、IPv6 (括号)、标准主机名
    if [[ "$PROXY_HOST" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        : # IPv4 — 通过
    elif [[ "$PROXY_HOST" =~ ^\[[0-9a-fA-F:]+\]$ ]]; then
        : # IPv6 — 通过
    elif [[ "$PROXY_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        : # 标准主机名 — 通过
    else
        log_error "无效的主机名或 IP 地址: $PROXY_HOST"
        return 1
    fi

    # 验证 port
    if [[ -n "$PROXY_PORT" ]]; then
        if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] || [[ "$PROXY_PORT" -lt 1 ]] || [[ "$PROXY_PORT" -gt 65535 ]]; then
            log_error "无效端口号: $PROXY_PORT (有效范围: 1-65535)"
            return 1
        fi
    fi

    # 验证 protocol
    case "$PROXY_PROTO" in
        http|https|socks4|socks5|socks4a|socks5h) ;;
        *)
            log_error "不支持的代理协议: $PROXY_PROTO (支持: http, https, socks4, socks5)"
            return 1
            ;;
    esac

    return 0
}

# 构建完整代理 URL
build_proxy_url() {
    local url=""
    if [[ -n "$PROXY_USER" ]]; then
        url="${PROXY_PROTO}://${PROXY_USER}"
        [[ -n "$PROXY_PASS" ]] && url+=":${PROXY_PASS}"
        url+="@${PROXY_HOST}"
    else
        url="${PROXY_PROTO}://${PROXY_HOST}"
    fi
    [[ -n "$PROXY_PORT" ]] && url+=":${PROXY_PORT}"
    echo "$url"
}

#===============================================================================
# 系统检测函数
#===============================================================================

# 检测 Linux 发行版
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-unknown}"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# 获取发行版家族
get_distro_family() {
    local distro
    distro=$(detect_distro)
    case "$distro" in
        debian|ubuntu|linuxmint|pop|elementary|kali|raspbian|parrot|deepin|uos) echo "debian" ;;
        rhel|centos|fedora|rocky|alma|ol|amzn|sangoma|scientific)             echo "rhel" ;;
        arch|manjaro|endeavouros|garuda|artix)                                echo "arch" ;;
        opensuse*|sles|sled)                                                  echo "suse" ;;
        alpine)                                                               echo "alpine" ;;
        *)                                                                    echo "unknown" ;;
    esac
}

# 检查包管理器
detect_pkg_manager() {
    if command_exists apt; then        echo "apt"
    elif command_exists dnf; then      echo "dnf"
    elif command_exists yum; then      echo "yum"
    elif command_exists pacman; then   echo "pacman"
    elif command_exists zypper; then   echo "zypper"
    elif command_exists apk; then      echo "apk"
    else                               echo "none"
    fi
}

#===============================================================================
# 配置模块 — 每个函数负责一个应用的代理配置
# 返回值: 0=成功, 1=失败, 2=跳过
#===============================================================================

#---------------------------------------------------------------------------
# 1. 系统环境变量 — /etc/environment 和 /etc/profile.d/proxy.sh
#---------------------------------------------------------------------------
configure_system_environment() {
    print_header "系统环境变量"

    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        # 移除 /etc/profile.d/proxy.sh
        if [[ -f /etc/profile.d/proxy.sh ]]; then
            if is_managed_by_us /etc/profile.d/proxy.sh; then
                remove_file /etc/profile.d/proxy.sh "系统代理脚本 /etc/profile.d/proxy.sh"
            else
                log_warn "/etc/profile.d/proxy.sh 并非由本脚本管理，跳过删除"
                STAT_SKIPPED=$((STAT_SKIPPED + 1))
            fi
        else
            log_info "系统代理脚本不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi

        # 清理 /etc/environment 中的代理变量
        if [[ -f /etc/environment ]] && grep -qE '^(HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|NO_PROXY|http_proxy|https_proxy|ftp_proxy|no_proxy)=' /etc/environment 2>/dev/null; then
            local env_content
            env_content=$(grep -vE '^(HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|NO_PROXY|http_proxy|https_proxy|ftp_proxy|no_proxy)=' /etc/environment 2>/dev/null || true)
            write_file /etc/environment "$env_content" "/etc/environment (移除代理变量)"
        else
            log_info "/etc/environment 无代理变量，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    # 配置模式 — 创建/更新 proxy.sh
    local proxy_script
    proxy_script=$(cat <<EOF
${MARKER}
# 系统全局代理环境变量
# 创建时间: $(date)
# 应用于所有用户的 shell 会话

export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export ftp_proxy="${proxy_url}"
export no_proxy="${NO_PROXY}"

export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export FTP_PROXY="${proxy_url}"
export NO_PROXY="${NO_PROXY}"
EOF
)
    write_file /etc/profile.d/proxy.sh "$proxy_script" "系统代理脚本 /etc/profile.d/proxy.sh"
    sudo_wrap chmod 644 /etc/profile.d/proxy.sh 2>/dev/null || true

    # 同时配置 /etc/environment (PAM 使用)
    local env_vars
    env_vars=$(cat <<EOF
${MARKER}
HTTP_PROXY="${proxy_url}"
HTTPS_PROXY="${proxy_url}"
FTP_PROXY="${proxy_url}"
NO_PROXY="${NO_PROXY}"
http_proxy="${proxy_url}"
https_proxy="${proxy_url}"
ftp_proxy="${proxy_url}"
no_proxy="${NO_PROXY}"
EOF
)

    # 对于 /etc/environment，追加或替换代理变量
    if [[ -f /etc/environment ]]; then
        local current_env
        current_env=$(cat /etc/environment)
        # 移除旧的代理行
        current_env=$(echo "$current_env" | grep -vE '^(HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|NO_PROXY|http_proxy|https_proxy|ftp_proxy|no_proxy)=' || true)
        current_env+=$'\n'"$env_vars"
        write_file /etc/environment "$current_env" "/etc/environment"
    else
        write_file /etc/environment "$env_vars" "/etc/environment"
    fi
}

#---------------------------------------------------------------------------
# 2. APT 包管理器 (Debian/Ubuntu)
#---------------------------------------------------------------------------
configure_apt() {
    if [[ "$(detect_pkg_manager)" != "apt" ]]; then
        return 2
    fi

    print_header "APT 包管理器"

    local apt_conf="/etc/apt/apt.conf.d/99proxy"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$apt_conf" ]]; then
            remove_file "$apt_conf" "APT 代理配置"
        else
            log_info "APT 代理配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    content=$(cat <<EOF
${MARKER}
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
EOF
)
    write_file "$apt_conf" "$content" "APT 代理配置"
}

#---------------------------------------------------------------------------
# 3. DNF / YUM 包管理器 (RHEL/Fedora)
#---------------------------------------------------------------------------
configure_dnf() {
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    if [[ "$pkg_manager" != "dnf" ]] && [[ "$pkg_manager" != "yum" ]]; then
        return 2
    fi

    print_header "DNF/YUM 包管理器"

    local proxy_url
    proxy_url=$(build_proxy_url)
    local conf_file

    if [[ "$pkg_manager" == "dnf" ]]; then
        conf_file="/etc/dnf/dnf.conf"
    else
        conf_file="/etc/yum.conf"
    fi

    if $REMOVE_MODE; then
        if [[ -f "$conf_file" ]]; then
            local cleaned
            cleaned=$(grep -v '^proxy=' "$conf_file" 2>/dev/null || true)
            write_file "$conf_file" "$cleaned" "$conf_file (移除代理)"
        else
            log_info "$conf_file 不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    # 读取现有配置，替换或追加 proxy 行
    local content
    if [[ -f "$conf_file" ]]; then
        content=$(cat "$conf_file")
        if grep -q '^proxy=' "$conf_file" 2>/dev/null; then
            content=$(echo "$content" | sed "s|^proxy=.*|proxy=${proxy_url}|")
        else
            content+=$'\n'"${MARKER}"$'\n'"proxy=${proxy_url}"
        fi
    else
        content="${MARKER}"$'\n'"proxy=${proxy_url}"
    fi

    write_file "$conf_file" "$content" "DNF/YUM 代理配置"
}

#---------------------------------------------------------------------------
# 4. Docker Daemon 代理
#---------------------------------------------------------------------------
configure_docker_daemon() {
    if ! command_exists dockerd && ! command_exists docker; then
        return 2
    fi

    print_header "Docker 守护进程"

    local docker_conf_dir="/etc/systemd/system/docker.service.d"
    local docker_conf="${docker_conf_dir}/http-proxy.conf"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$docker_conf" ]]; then
            remove_file "$docker_conf" "Docker 守护进程代理配置"

            # 如果目录为空则删除
            if [[ -d "$docker_conf_dir" ]] && [[ -z "$(ls -A "$docker_conf_dir" 2>/dev/null)" ]]; then
                sudo_wrap rmdir "$docker_conf_dir" 2>/dev/null || true
            fi

            # 重载 systemd 和 Docker
            if ! $DRY_RUN; then
                sudo_wrap systemctl daemon-reload 2>/dev/null || true
                if systemctl is-active --quiet docker 2>/dev/null; then
                    sudo_wrap systemctl restart docker 2>/dev/null || log_warn "Docker 重启失败，请手动重启"
                fi
            fi
        else
            log_info "Docker 守护进程代理配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    content=$(cat <<EOF
${MARKER}
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=${NO_PROXY}"
EOF
)
    write_file "$docker_conf" "$content" "Docker 守护进程代理"

    # 重载 systemd 并重启 Docker
    if ! $DRY_RUN; then
        sudo_wrap systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload 失败"
        if systemctl is-active --quiet docker 2>/dev/null; then
            if sudo_wrap systemctl restart docker 2>/dev/null; then
                log_success "Docker 服务已重启"
            else
                log_warn "Docker 重启失败，请手动执行: sudo systemctl restart docker"
            fi
        fi
    fi
}

#---------------------------------------------------------------------------
# 5. Docker Client 代理 (~/.docker/config.json)
#---------------------------------------------------------------------------
configure_docker_client() {
    if ! command_exists docker; then
        return 2
    fi

    print_header "Docker 客户端"

    local docker_config="${HOME}/.docker/config.json"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$docker_config" ]]; then
            # 使用 python3 或 jq 或手动处理 JSON 移除 proxies 键
            if command_exists python3; then
                local new_json
                new_json=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$docker_config'))
    cfg.pop('proxies', None)
    json.dump(cfg, sys.stdout, indent=2)
    print()
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
                if [[ -n "$new_json" ]] && [[ ! "$new_json" =~ ^ERROR: ]]; then
                    write_file "$docker_config" "$new_json" "Docker 客户端代理 (移除)"
                else
                    log_warn "Docker 客户端代理移除 — JSON 处理失败，跳过"
                    STAT_SKIPPED=$((STAT_SKIPPED + 1))
                fi
            elif command_exists jq; then
                local new_json
                new_json=$(jq 'del(.proxies)' "$docker_config" 2>/dev/null)
                if [[ -n "$new_json" ]]; then
                    write_file "$docker_config" "$new_json" "Docker 客户端代理 (移除)"
                else
                    log_warn "Docker 客户端代理移除 — jq 处理失败，跳过"
                    STAT_SKIPPED=$((STAT_SKIPPED + 1))
                fi
            else
                log_warn "需要 python3 或 jq 来编辑 Docker 客户端配置，跳过"
                STAT_SKIPPED=$((STAT_SKIPPED + 1))
            fi
        else
            log_info "Docker 客户端配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    # 构建新的 proxies 对象
    local proxies_json
    proxies_json=$(cat <<EOF
{
    "proxies": {
        "default": {
            "httpProxy": "${proxy_url}",
            "httpsProxy": "${proxy_url}",
            "noProxy": "${NO_PROXY}"
        }
    }
}
EOF
)

    # 合并到现有配置
    if [[ -f "$docker_config" ]]; then
        local new_json
        if command_exists python3; then
            new_json=$(python3 -c "
import json, sys
try:
    with open('$docker_config') as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
cfg['proxies'] = {
    'default': {
        'httpProxy': '${proxy_url}',
        'httpsProxy': '${proxy_url}',
        'noProxy': '${NO_PROXY}'
    }
}
json.dump(cfg, sys.stdout, indent=2)
print()
" 2>/dev/null)
            if [[ -n "$new_json" ]]; then
                write_file "$docker_config" "$new_json" "Docker 客户端代理"
            else
                log_error "Docker 客户端代理配置 — JSON 处理失败"
                STAT_FAILED=$((STAT_FAILED + 1))
            fi
        elif command_exists jq; then
            new_json=$(jq --arg http "$proxy_url" --arg https "$proxy_url" --arg no "$NO_PROXY" \
                '.proxies.default.httpProxy = $http | .proxies.default.httpsProxy = $https | .proxies.default.noProxy = $no' \
                "$docker_config" 2>/dev/null)
            if [[ -n "$new_json" ]]; then
                write_file "$docker_config" "$new_json" "Docker 客户端代理"
            else
                log_error "Docker 客户端代理配置 — jq 处理失败"
                STAT_FAILED=$((STAT_FAILED + 1))
            fi
        else
            log_warn "需要 python3 或 jq 来编辑 Docker 客户端配置，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
    else
        # 创建新文件
        write_file "$docker_config" "$proxies_json" "Docker 客户端代理"
    fi
}

#---------------------------------------------------------------------------
# 6. Git 代理
#---------------------------------------------------------------------------
configure_git() {
    if ! command_exists git; then
        return 2
    fi

    print_header "Git"

    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        local changed=false
        if git config --global --get http.proxy &>/dev/null; then
            if $DRY_RUN; then
                print_dryrun "git config --global --unset http.proxy"
            else
                git config --global --unset http.proxy
            fi
            changed=true
        fi
        if git config --global --get https.proxy &>/dev/null; then
            if $DRY_RUN; then
                print_dryrun "git config --global --unset https.proxy"
            else
                git config --global --unset https.proxy
            fi
            changed=true
        fi
        if $changed; then
            log_success "Git 代理 — 已移除"
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        else
            log_info "Git 代理 — 未设置，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    if $DRY_RUN; then
        print_dryrun "git config --global http.proxy \"${proxy_url}\""
        print_dryrun "git config --global https.proxy \"${proxy_url}\""
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    local ok=true
    git config --global http.proxy "$proxy_url" || ok=false
    git config --global https.proxy "$proxy_url" || ok=false

    if $ok; then
        log_success "Git 代理 — 配置完成"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
    else
        log_error "Git 代理 — 配置失败"
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
}

#---------------------------------------------------------------------------
# 7. npm 代理
#---------------------------------------------------------------------------
configure_npm() {
    if ! command_exists npm; then
        return 2
    fi

    print_header "npm"

    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        local changed=false
        for key in proxy https-proxy noproxy; do
            if npm config get "$key" &>/dev/null && [[ "$(npm config get "$key" 2>/dev/null)" != "null" ]]; then
                if ! $DRY_RUN; then
                    npm config delete "$key" 2>/dev/null || true
                fi
                changed=true
            fi
        done
        if $changed; then
            log_success "npm 代理 — 已移除"
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        else
            log_info "npm 代理 — 未设置，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    if $DRY_RUN; then
        print_dryrun "npm config set proxy \"${proxy_url}\""
        print_dryrun "npm config set https-proxy \"${proxy_url}\""
        print_dryrun "npm config set noproxy \"${NO_PROXY}\""
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    local ok=true
    npm config set proxy "$proxy_url" 2>/dev/null || ok=false
    npm config set https-proxy "$proxy_url" 2>/dev/null || ok=false
    npm config set noproxy "$NO_PROXY" 2>/dev/null || ok=false

    if $ok; then
        log_success "npm 代理 — 配置完成"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
    else
        log_error "npm 代理 — 配置失败"
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
}

#---------------------------------------------------------------------------
# 8. pip 代理
#---------------------------------------------------------------------------
configure_pip() {
    if ! command_exists pip3 && ! command_exists pip; then
        return 2
    fi

    print_header "pip (Python)"

    local proxy_url
    proxy_url=$(build_proxy_url)

    # pip 配置文件路径优先级
    local pip_conf=""
    if [[ -d /etc/pip.conf ]]; then
        : # /etc/pip.conf 是目录不是文件的情况
    fi

    # 全局配置
    pip_conf="/etc/pip.conf"

    if $REMOVE_MODE; then
        # 移除全局 pip 配置中的代理
        if [[ -f "$pip_conf" ]]; then
            local cleaned
            cleaned=$(grep -vE '^\s*proxy\s*=' "$pip_conf" 2>/dev/null || true)
            if [[ -z "$(echo "$cleaned" | tr -d '[:space:]')" ]]; then
                remove_file "$pip_conf" "pip 全局代理配置"
            else
                write_file "$pip_conf" "$cleaned" "pip 全局代理配置 (移除代理)"
            fi
        else
            log_info "pip 全局配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi

        # 也清理用户级配置
        for user_conf in "${HOME}/.config/pip/pip.conf" "${HOME}/.pip/pip.conf"; do
            if [[ -f "$user_conf" ]]; then
                local cleaned
                cleaned=$(grep -vE '^\s*proxy\s*=' "$user_conf" 2>/dev/null || true)
                if [[ -z "$(echo "$cleaned" | tr -d '[:space:]')" ]]; then
                    rm "$user_conf" 2>/dev/null || true
                else
                    echo "$cleaned" > "$user_conf"
                fi
            fi
        done
        return 0
    fi

    # pip.conf 内容
    local content
    if [[ -f "$pip_conf" ]]; then
        content=$(cat "$pip_conf")
        if grep -qE '^\s*proxy\s*=' "$pip_conf" 2>/dev/null; then
            content=$(echo "$content" | sed "s|^\s*proxy\s*=.*|proxy = ${proxy_url}|")
        else
            content+=$'\n'"${MARKER}"$'\n'"proxy = ${proxy_url}"
        fi
    else
        content=$(cat <<EOF
[global]
${MARKER}
proxy = ${proxy_url}
EOF
)
    fi

    write_file "$pip_conf" "$content" "pip 全局代理"
}

#---------------------------------------------------------------------------
# 9. curl 代理 (~/.curlrc)
#---------------------------------------------------------------------------
configure_curl() {
    if ! command_exists curl; then
        return 2
    fi

    print_header "curl"

    local curlrc="${HOME}/.curlrc"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$curlrc" ]]; then
            # 移除代理行
            local cleaned
            cleaned=$(grep -vE '^(proxy|noproxy)=' "$curlrc" 2>/dev/null || true)
            if [[ -z "$(echo "$cleaned" | tr -d '[:space:]')" ]]; then
                rm "$curlrc" 2>/dev/null || true
                log_success "curl 代理 — 已移除 (~/.curlrc 已删除)"
            else
                echo "$cleaned" > "$curlrc"
                log_success "curl 代理 — 已从 ~/.curlrc 移除"
            fi
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        else
            log_info "curl 配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    if [[ -f "$curlrc" ]]; then
        content=$(cat "$curlrc")
        # 移除旧的代理行
        content=$(echo "$content" | grep -vE '^(proxy|noproxy)=' || true)
        content+=$'\n'"${MARKER}"$'\n'
        content+="proxy = \"${proxy_url}\""$'\n'
        content+="noproxy = \"${NO_PROXY}\""
    else
        content=$(cat <<EOF
${MARKER}
proxy = "${proxy_url}"
noproxy = "${NO_PROXY}"
EOF
)
    fi

    write_file "$curlrc" "$content" "curl 代理 (~/.curlrc)"
}

#---------------------------------------------------------------------------
# 10. wget 代理 (/etc/wgetrc)
#---------------------------------------------------------------------------
configure_wget() {
    if ! command_exists wget; then
        return 2
    fi

    print_header "wget"

    local wgetrc="/etc/wgetrc"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$wgetrc" ]]; then
            local cleaned
            # 移除我们管理的代理行和注释代理行
            cleaned=$(grep -vF "$MARKER" "$wgetrc" | grep -vE '^(https?_proxy|ftp_proxy|use_proxy)\s*=.*#.*proxy-config' || true)
            write_file "$wgetrc" "$cleaned" "wget 全局代理 (移除)"
        else
            log_info "wget 全局配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    if [[ -f "$wgetrc" ]]; then
        content=$(cat "$wgetrc")
        # 移除旧的代理行
        content=$(echo "$content" | grep -vE '^(https?_proxy|ftp_proxy|use_proxy)\s*=' || true)
        content+=$'\n'"${MARKER}"$'\n'
    else
        content="${MARKER}"$'\n'
    fi
    content+="use_proxy = on"$'\n'
    content+="http_proxy = ${proxy_url}"$'\n'
    content+="https_proxy = ${proxy_url}"$'\n'
    content+="ftp_proxy = ${proxy_url}"

    write_file "$wgetrc" "$content" "wget 全局代理"
}

#---------------------------------------------------------------------------
# 11. snap 代理
#---------------------------------------------------------------------------
configure_snap() {
    if ! command_exists snap; then
        return 2
    fi

    print_header "Snap"

    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if $DRY_RUN; then
            print_dryrun "snap unset system proxy.http"
            print_dryrun "snap unset system proxy.https"
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
            return 0
        fi
        local ok=true
        sudo_wrap snap unset system proxy.http 2>/dev/null || ok=false
        sudo_wrap snap unset system proxy.https 2>/dev/null || ok=false
        if $ok; then
            log_success "Snap 代理 — 已移除"
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        else
            log_warn "Snap 代理 — 移除可能失败（snapd 可能未运行）"
            STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        fi
        return 0
    fi

    if $DRY_RUN; then
        print_dryrun "snap set system proxy.http=\"${proxy_url}\""
        print_dryrun "snap set system proxy.https=\"${proxy_url}\""
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    local ok=true
    sudo_wrap snap set system proxy.http="$proxy_url" 2>/dev/null || ok=false
    sudo_wrap snap set system proxy.https="$proxy_url" 2>/dev/null || ok=false

    if $ok; then
        log_success "Snap 代理 — 配置完成"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
    else
        log_warn "Snap 代理 — 配置可能失败（snapd 可能未运行）"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
    fi
}

#---------------------------------------------------------------------------
# 12. containerd 代理
#---------------------------------------------------------------------------
configure_containerd() {
    if ! command_exists containerd; then
        return 2
    fi

    print_header "containerd"

    local containerd_conf="/etc/containerd/config.toml"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if [[ ! -f "$containerd_conf" ]]; then
        log_info "containerd 配置文件不存在，跳过"
        return 2
    fi

    if $REMOVE_MODE; then
        # 移除 proxy 相关 TOML section
        if grep -qF "$MARKER" "$containerd_conf" 2>/dev/null; then
            local cleaned
            cleaned=$(sed "/$MARKER_START/,/$MARKER_END/d" "$containerd_conf" 2>/dev/null || true)
            write_file "$containerd_conf" "$cleaned" "containerd 代理 (移除)"

            if ! $DRY_RUN; then
                sudo_wrap systemctl restart containerd 2>/dev/null || log_warn "containerd 重启失败，请手动重启"
            fi
        else
            log_info "containerd 代理未由本脚本管理，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    # 检查是否已有我们的配置
    if grep -qF "$MARKER" "$containerd_conf" 2>/dev/null; then
        # 更新现有配置块中的代理 URL
        local updated
        updated=$(sed -E "/$MARKER_START/,/$MARKER_END/ s|(HTTP_PROXY|HTTPS_PROXY|NO_PROXY) = \".*\"|\"${proxy_url}\"|g" "$containerd_conf")
        write_file "$containerd_conf" "$updated" "containerd 代理 (更新)"
    else
        # 追加新的配置块
        local proxy_block
        proxy_block=$(cat <<EOF

${MARKER_START}
${MARKER}
[plugins."io.containerd.grpc.v1.cri".registry.mirrors]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io"]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io".tls]
        insecure_skip_verify = false
${MARKER_END}
EOF
)
        local content
        content=$(cat "$containerd_conf")
        content+="$proxy_block"
        write_file "$containerd_conf" "$content" "containerd 代理"
    fi

    # containerd 本身通过 systemd 环境变量获取代理，通过 Docker daemon 的代理配置即可
    # 这里主要是确保配置存在
    log_info "containerd 通过 Docker daemon 环境变量获取代理，已由 Docker 配置覆盖"
}

#---------------------------------------------------------------------------
# 13. systemd 全局环境代理
#---------------------------------------------------------------------------
configure_systemd() {
    if ! command_exists systemctl; then
        return 2
    fi

    print_header "systemd 全局环境"

    local systemd_conf_dir="/etc/systemd/system.conf.d"
    local systemd_conf="${systemd_conf_dir}/proxy.conf"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$systemd_conf" ]]; then
            remove_file "$systemd_conf" "systemd 全局代理"
            if ! $DRY_RUN; then
                sudo_wrap systemctl daemon-reload 2>/dev/null || true
            fi
        else
            log_info "systemd 全局代理配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    content=$(cat <<EOF
${MARKER}
[Manager]
DefaultEnvironment="HTTP_PROXY=${proxy_url}"
DefaultEnvironment="HTTPS_PROXY=${proxy_url}"
DefaultEnvironment="NO_PROXY=${NO_PROXY}"
DefaultEnvironment="http_proxy=${proxy_url}"
DefaultEnvironment="https_proxy=${proxy_url}"
DefaultEnvironment="no_proxy=${NO_PROXY}"
EOF
)
    write_file "$systemd_conf" "$content" "systemd 全局代理"

    if ! $DRY_RUN; then
        sudo_wrap systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload 失败"
    fi
}

#---------------------------------------------------------------------------
# 14. 当前 shell 会话的环境变量
#---------------------------------------------------------------------------
configure_current_shell() {
    print_header "当前 Shell 会话"

    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        for var in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
            unset "$var" 2>/dev/null || true
        done
        log_success "当前 Shell — 代理环境变量已清除"
        STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
        return 0
    fi

    # 设置当前 shell 的变量
    export http_proxy="$proxy_url"
    export https_proxy="$proxy_url"
    export ftp_proxy="$proxy_url"
    export no_proxy="$NO_PROXY"
    export HTTP_PROXY="$proxy_url"
    export HTTPS_PROXY="$proxy_url"
    export FTP_PROXY="$proxy_url"
    export NO_PROXY="$NO_PROXY"

    log_success "当前 Shell — 代理环境变量已设置（仅本会话有效，新终端需 source /etc/profile.d/proxy.sh）"
    STAT_CONFIGURED=$((STAT_CONFIGURED + 1))
}

#===============================================================================
# 交互模式
#===============================================================================
run_interactive() {
    echo -e "${COLORS[bold]}${COLORS[cyan]}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       Linux 全局代理配置工具 v${SCRIPT_VERSION}                   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${COLORS[reset]}"

    # 代理 URL
    echo ""
    echo -e "${COLORS[bold]}请输入代理服务器地址:${COLORS[reset]}"
    echo -e "  格式: [protocol://][user:pass@]host[:port]"
    echo -e "  示例:"
    echo -e "    http://10.0.0.10:1082"
    echo -e "    socks5://192.168.1.1:1080"
    echo -e "    http://user:pass@proxy.example.com:8080"
    echo ""

    while true; do
        read -r -p "  代理地址: " PROXY_URL
        if validate_proxy_url "$PROXY_URL"; then
            break
        fi
        echo -e "  ${COLORS[red]}请重新输入有效的代理地址${COLORS[reset]}"
    done

    # NO_PROXY 配置
    echo ""
    echo -e "${COLORS[bold]}NO_PROXY 排除列表 (当前默认):${COLORS[reset]}"
    echo -e "  ${COLORS[dim]}${NO_PROXY}${COLORS[reset]}"
    echo ""
    read -r -p "  是否修改? [y/N]: " modify_no_proxy
    if [[ "$modify_no_proxy" =~ ^[Yy]$ ]]; then
        read -r -p "  新的 NO_PROXY 列表: " custom_no_proxy
        if [[ -n "$custom_no_proxy" ]]; then
            NO_PROXY="$custom_no_proxy"
        fi
    fi

    # 确认
    local full_url
    full_url=$(build_proxy_url)
    echo ""
    echo -e "${COLORS[bold]}═══════════════════════════════════════════════════════${COLORS[reset]}"
    echo -e "  ${COLORS[bold]}代理地址:${COLORS[reset]} ${COLORS[green]}${full_url}${COLORS[reset]}"
    echo -e "  ${COLORS[bold]}排除列表:${COLORS[reset]} ${COLORS[dim]}${NO_PROXY}${COLORS[reset]}"
    echo -e "  ${COLORS[bold]}运行模式:${COLORS[reset]} $($DRY_RUN && echo "${COLORS[yellow]}模拟运行${COLORS[reset]}" || echo "${COLORS[green]}实际配置${COLORS[reset]}")"
    echo -e "${COLORS[bold]}═══════════════════════════════════════════════════════${COLORS[reset]}"
    echo ""

    if ! $DRY_RUN; then
        read -r -p "  确认开始配置? [Y/n]: " confirm
        if [[ -n "$confirm" ]] && [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${COLORS[yellow]}已取消${COLORS[reset]}"
            exit 0
        fi
    fi
}

#===============================================================================
# 检测已安装的应用
#===============================================================================
detect_applications() {
    echo ""
    print_info "检测已安装的应用..."

    local detect_count=0
    local detect_list=()

    local apps=(
        "系统环境变量:true"
        "当前Shell:true"
        "APT:$( [[ "$(detect_pkg_manager)" == "apt" ]] && echo true || echo false )"
        "DNF/YUM:$( [[ "$(detect_pkg_manager)" =~ ^(dnf|yum)$ ]] && echo true || echo false )"
        "Docker 守护进程:$( command_exists dockerd || command_exists docker && echo true || echo false )"
        "Docker 客户端:$( command_exists docker && echo true || echo false )"
        "Git:$( command_exists git && echo true || echo false )"
        "npm:$( command_exists npm && echo true || echo false )"
        "pip:$( command_exists pip3 || command_exists pip && echo true || echo false )"
        "curl:$( command_exists curl && echo true || echo false )"
        "wget:$( command_exists wget && echo true || echo false )"
        "Snap:$( command_exists snap && echo true || echo false )"
        "containerd:$( command_exists containerd && echo true || echo false )"
        "systemd:$( command_exists systemctl && echo true || echo false )"
    )

    for app in "${apps[@]}"; do
        local name="${app%%:*}"
        local installed="${app##*:}"
        if [[ "$installed" == "true" ]]; then
            detect_list+=("${COLORS[green]}✓${COLORS[reset]} $name")
            detect_count=$((detect_count + 1))
        else
            detect_list+=("${COLORS[dim]}✗${COLORS[reset]} $name ${COLORS[dim]}(未安装)${COLORS[reset]}")
        fi
    done

    for line in "${detect_list[@]}"; do
        echo -e "  $line"
    done

    echo ""
    print_info "将配置 ${COLORS[bold]}${detect_count}${COLORS[reset]} 项"
}

#===============================================================================
# 运行所有配置模块
#===============================================================================
run_all_configurations() {
    local total=0
    local skipped=0

    log_info "开始配置... (代理: $(build_proxy_url))"
    log_info "NO_PROXY: ${NO_PROXY}"

    # 按顺序执行每个模块
    local modules=(
        "configure_system_environment"
        "configure_apt"
        "configure_dnf"
        "configure_docker_daemon"
        "configure_docker_client"
        "configure_git"
        "configure_npm"
        "configure_pip"
        "configure_curl"
        "configure_wget"
        "configure_snap"
        "configure_containerd"
        "configure_systemd"
        "configure_current_shell"
    )

    for module in "${modules[@]}"; do
        total=$((total + 1))
        local rc=0
        $module || rc=$?

        case $rc in
            0) ;; # 成功或失败已在模块内计入
            2) skipped=$((skipped + 1)) ;;  # 模块未安装，由这里计入
        esac
    done
}

#===============================================================================
# 打印执行总结
#===============================================================================
print_summary() {
    echo ""
    echo -e "${COLORS[bold]}${COLORS[cyan]}╔══════════════════════════════════════════════════════╗${COLORS[reset]}"
    echo -e "${COLORS[bold]}${COLORS[cyan]}║              配  置  总  结                          ║${COLORS[reset]}"
    echo -e "${COLORS[bold]}${COLORS[cyan]}╚══════════════════════════════════════════════════════╝${COLORS[reset]}"
    echo ""
    echo -e "  ${COLORS[green]}已配置:${COLORS[reset]} ${STAT_CONFIGURED}"
    echo -e "  ${COLORS[yellow]}已跳过:${COLORS[reset]} ${STAT_SKIPPED}"
    echo -e "  ${COLORS[red]}失败:${COLORS[reset]}   ${STAT_FAILED}"
    echo -e "  ${COLORS[blue]}备份:${COLORS[reset]}   ${STAT_BACKED_UP}"
    echo ""

    if $DRY_RUN; then
        echo -e "  ${COLORS[yellow]}⚠  这是模拟运行 — 未对系统做任何实际更改${COLORS[reset]}"
        echo ""
    fi

    if [[ $STAT_FAILED -eq 0 ]]; then
        echo -e "  ${COLORS[green]}✓ 所有配置已完成${COLORS[reset]}"
    else
        echo -e "  ${COLORS[red]}✗ 部分配置失败，请检查日志: ${LOG_FILE}${COLORS[reset]}"
    fi

    if ! $DRY_RUN && ! $REMOVE_MODE; then
        echo ""
        echo -e "  ${COLORS[bold]}提示:${COLORS[reset]} 新终端窗口将自动应用代理设置"
        echo -e "  如需在当前终端立即生效，请执行:"
        echo -e "    ${COLORS[cyan]}source /etc/profile.d/proxy.sh${COLORS[reset]}"
        echo ""

        # 验证连通性 (可选的快速测试)
        if command_exists curl; then
            echo -e "  ${COLORS[dim]}快速连通性测试...${COLORS[reset]}"
            if curl -s --max-time 5 --proxy "$(build_proxy_url)" "http://httpbin.org/ip" &>/dev/null; then
                echo -e "  ${COLORS[green]}✓ 代理连通性测试通过${COLORS[reset]}"
            else
                echo -e "  ${COLORS[yellow]}⚠ 代理连通性测试失败 — 请检查代理服务器是否可达${COLORS[reset]}"
            fi
        fi
    fi

    if $REMOVE_MODE; then
        echo ""
        echo -e "  ${COLORS[bold]}提示:${COLORS[reset]} 代理配置已移除，新终端将不再使用代理"
    fi
}

#===============================================================================
# CLI 参数解析
#===============================================================================
print_usage() {
    cat <<EOF
用法: sudo $0 [选项]

选项:
  --proxy, -p <URL>      设置代理地址
                         格式: [protocol://][user:pass@]host[:port]
                         示例: http://10.0.0.10:1082
                               socks5://user:pass@proxy:1080

  --no-proxy <LIST>      NO_PROXY 排除列表 (逗号分隔)
                         默认: ${NO_PROXY}

  --remove, -r           移除所有代理配置

  --dry-run, -n          模拟运行 — 仅显示将要执行的操作，不做实际更改

  --backup-dir <DIR>     备份目录 (默认: 系统文件 ${SYSTEM_BACKUP_DIR}
                         用户文件 ${USER_BACKUP_DIR})

  --log-file <FILE>      日志文件路径 (默认: 自动选择)

  --no-color             禁用彩色输出

  --non-interactive      非交互模式 (与 --proxy 一起使用)

  --config, -c <FILE>    从配置文件读取参数

  --version, -v          显示版本信息

  --help, -h             显示此帮助信息

配置文件格式 (与 --config 配合使用):
  PROXY_URL=http://10.0.0.10:1082
  NO_PROXY=localhost,127.0.0.1,::1,.local
  # 注释行
EOF
}

print_version() {
    echo "proxy-config.sh v${SCRIPT_VERSION}"
    echo "Linux 全局代理自动配置工具"
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proxy|-p)
                PROXY_URL="$2"
                INTERACTIVE=false
                shift 2
                ;;
            --no-proxy)
                NO_PROXY="$2"
                shift 2
                ;;
            --remove|-r)
                REMOVE_MODE=true
                INTERACTIVE=false
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --no-color)
                NO_COLOR=1
                # 立即清除颜色
                for key in reset bold dim red green yellow blue magenta cyan white; do
                    COLORS[$key]=""
                done
                shift
                ;;
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --config|-c)
                CONFIG_FILE="$2"
                INTERACTIVE=false
                shift 2
                ;;
            --version|-v)
                print_version
                exit 0
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            -*)
                print_error "未知选项: $1"
                print_usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # 位置参数作为代理 URL
    if [[ ${#positional[@]} -gt 0 ]] && [[ -z "$PROXY_URL" ]]; then
        PROXY_URL="${positional[0]}"
        INTERACTIVE=false
    fi
}

# 加载配置文件
load_config_file() {
    if [[ -z "$CONFIG_FILE" ]]; then
        return 0
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi

    log_info "加载配置文件: $CONFIG_FILE"

    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            PROXY_URL)
                if [[ -z "$PROXY_URL" ]]; then
                    PROXY_URL="$value"
                fi
                ;;
            NO_PROXY)
                if [[ -z "$NO_PROXY" ]] || [[ "$NO_PROXY" == "localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12" ]]; then
                    NO_PROXY="$value"
                fi
                ;;
            DRY_RUN)    DRY_RUN=true ;;
            REMOVE)     REMOVE_MODE=true ;;
        esac
    done < "$CONFIG_FILE"
}

#===============================================================================
# 初始化
#===============================================================================
initialize() {
    # 确定备份目录
    if [[ -z "$BACKUP_DIR" ]]; then
        if is_root; then
            BACKUP_DIR="$SYSTEM_BACKUP_DIR"
        else
            BACKUP_DIR="$USER_BACKUP_DIR"
        fi
    fi

    # 确定日志文件
    if [[ -z "$LOG_FILE" ]]; then
        if is_root; then
            LOG_FILE="${SYSTEM_LOG_DIR}/${SCRIPT_NAME}.log"
        else
            LOG_FILE="${USER_LOG_DIR}/${SCRIPT_NAME}.log"
        fi
    fi

    # 创建必要的目录
    if ! $DRY_RUN; then
        ensure_dir "$BACKUP_DIR"
        ensure_dir "$(dirname "$LOG_FILE")"
    fi

    log_to_file "========== proxy-config.sh v${SCRIPT_VERSION} 开始 =========="
    log_to_file "时间: $(date)"
    log_to_file "用户: $(whoami)"
    log_to_file "发行版: $(detect_distro) ($(get_distro_family))"
    log_to_file "包管理器: $(detect_pkg_manager)"
    log_to_file "模式: $($DRY_RUN && echo '模拟运行' || echo '实际配置')"
    log_to_file "$($REMOVE_MODE && echo '操作: 移除代理' || echo '操作: 配置代理')"

    if ! $DRY_RUN && ! is_root && [[ "$REMOVE_MODE" == "true" || "$INTERACTIVE" == "false" ]]; then
        log_warn "建议以 root 身份运行以配置系统级代理"
        log_warn "将以当前用户权限运行（仅能配置用户级组件）"
    fi
}

#===============================================================================
# 主函数
#===============================================================================
main() {
    # 解析参数
    parse_args "$@"

    # 加载配置文件
    load_config_file

    # 初始化
    initialize

    # 运行模式判断
    if $INTERACTIVE; then
        # 交互模式
        run_interactive
    elif $REMOVE_MODE; then
        # 移除模式 — 不需要代理 URL
        echo -e "${COLORS[bold]}${COLORS[yellow]}╔══════════════════════════════════════════════════════╗${COLORS[reset]}"
        echo -e "${COLORS[bold]}${COLORS[yellow]}║         移  除  所  有  代  理  配  置                ║${COLORS[reset]}"
        echo -e "${COLORS[bold]}${COLORS[yellow]}╚══════════════════════════════════════════════════════╝${COLORS[reset]}"
        echo ""
        if ! $DRY_RUN; then
            read -r -p "  确认移除所有代理配置? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${COLORS[yellow]}已取消${COLORS[reset]}"
                exit 0
            fi
        fi
    else
        # 命令行模式 — 必须提供代理 URL
        if [[ -z "$PROXY_URL" ]]; then
            print_error "请指定代理地址 (--proxy <URL>) 或使用交互模式"
            print_usage
            exit 1
        fi

        if ! validate_proxy_url "$PROXY_URL"; then
            exit 1
        fi

        echo -e "${COLORS[bold]}${COLORS[cyan]}╔══════════════════════════════════════════════════════╗${COLORS[reset]}"
        echo -e "${COLORS[bold]}${COLORS[cyan]}║       Linux 全局代理配置工具 v${SCRIPT_VERSION}                   ║${COLORS[reset]}"
        echo -e "${COLORS[bold]}${COLORS[cyan]}╚══════════════════════════════════════════════════════╝${COLORS[reset]}"
        echo ""
        echo -e "  ${COLORS[bold]}代理:${COLORS[reset]} ${COLORS[green]}$(build_proxy_url)${COLORS[reset]}"
        echo -e "  ${COLORS[bold]}排除:${COLORS[reset]} ${COLORS[dim]}${NO_PROXY}${COLORS[reset]}"
        echo -e "  ${COLORS[bold]}模式:${COLORS[reset]} $($DRY_RUN && echo "${COLORS[yellow]}模拟运行${COLORS[reset]}" || echo "${COLORS[green]}实际配置${COLORS[reset]}")"
        echo ""
    fi

    # 检测应用
    detect_applications

    # 执行所有配置模块
    run_all_configurations

    # 打印总结
    print_summary

    log_to_file "========== proxy-config.sh 结束 =========="

    # 返回状态
    if [[ $STAT_FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

#===============================================================================
# 入口
#===============================================================================
main "$@"
