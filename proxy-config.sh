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
readonly SCRIPT_URL="https://github.com/miauyo/proxy-config"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# 由本脚本管理的文件标记
readonly MARKER="# Managed by proxy-config.sh — do not edit manually"
readonly MARKER_START="# >>> proxy-config.sh managed block >>>"
readonly MARKER_END="# <<< proxy-config.sh managed block <<<"

# 默认备份目录 (用户级路径在 initialize() 中根据 REAL_HOME 计算)
readonly SYSTEM_BACKUP_DIR="/var/backups/proxy-config"
readonly SYSTEM_LOG_DIR="/var/log"

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
readonly DEFAULT_NO_PROXY="localhost,127.0.0.1,::1,.local,.internal,.svc,.cluster.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
NO_PROXY="$DEFAULT_NO_PROXY"
BACKUP_DIR=""
LOG_FILE=""
CONFIG_FILE=""
SKIP_VERIFY=false

# 统计计数器
declare -i STAT_CONFIGURED=0
declare -i STAT_SKIPPED=0
declare -i STAT_FAILED=0
declare -i STAT_BACKED_UP=0

# 模块调度表: 模块名 → 配置函数 + 描述
# 标准模块顺序 (用于列表展示和执行)
readonly MODULE_ORDER=("system" "shell" "apt" "dnf" "docker-daemon" "docker-client" \
                        "git" "npm" "pip" "curl" "wget" "snap" "containerd" "systemd")

declare -A TARGET_HANDLERS=(
    ["system"]="configure_system_environment"
    ["apt"]="configure_apt"
    ["dnf"]="configure_dnf"
    ["docker-daemon"]="configure_docker_daemon"
    ["docker-client"]="configure_docker_client"
    ["git"]="configure_git"
    ["npm"]="configure_npm"
    ["pip"]="configure_pip"
    ["curl"]="configure_curl"
    ["wget"]="configure_wget"
    ["snap"]="configure_snap"
    ["containerd"]="configure_containerd"
    ["systemd"]="configure_systemd"
    ["shell"]="configure_current_shell"
)

declare -A TARGET_DESCRIPTIONS=(
    ["system"]="系统环境变量 (/etc/profile.d, /etc/environment)"
    ["apt"]="APT 包管理器 (Debian/Ubuntu)"
    ["dnf"]="DNF/YUM 包管理器 (RHEL/Fedora)"
    ["docker-daemon"]="Docker 守护进程"
    ["docker-client"]="Docker 客户端"
    ["git"]="Git 全局代理"
    ["npm"]="npm 代理"
    ["pip"]="pip (Python) 代理"
    ["curl"]="curl 代理 (~/.curlrc)"
    ["wget"]="wget 代理 (/etc/wgetrc)"
    ["snap"]="Snap 代理"
    ["containerd"]="containerd 代理"
    ["systemd"]="systemd 全局环境代理"
    ["shell"]="当前 Shell 会话环境变量"
)

# 模块启用状态: 用户勾选 or --targets 控制
declare -A TARGET_ENABLED
# 模块可用性: 工具已安装则为 true
declare -A TARGET_AVAILABLE
# 用户通过 --targets 指定的列表（空=全部）
TARGETS_FILTER=""

#===============================================================================
# 工具函数 (必须在任何调用之前定义, curl|bash 管道模式下按序解析)
#===============================================================================

# 检查是否以 root 运行
is_root() { [[ $EUID -eq 0 ]]; }

# 检查命令是否存在
command_exists() { command -v "$1" &>/dev/null; }

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

# 真实用户检测 (sudo 环境下 $HOME 可能是 /root)
if [[ -n "${SUDO_USER:-}" ]] && is_root; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
    [[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"
else
    REAL_USER="$(whoami)"
    REAL_HOME="$HOME"
fi

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

    # 用户 home 目录下的文件不通过 sudo 写入，避免 root 属主问题
    local write_cmd="tee"
    if [[ "$file" != "${REAL_HOME}"* ]]; then
        write_cmd="sudo_wrap tee"
    fi
    if echo "$content" | $write_cmd "$file" > /dev/null 2>&1; then
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

    # 验证认证信息：防止注入到 shell 脚本中的特殊字符
    if [[ -n "$PROXY_USER" ]]; then
        if [[ "$PROXY_USER" =~ [\`\$\!\"\\] ]] || [[ -n "$PROXY_PASS" && "$PROXY_PASS" =~ [\`\$\!\"\\] ]]; then
            log_error "代理认证信息包含不安全的字符 (\` \$ ! \" \\)"
            log_error "请对用户名/密码进行 URL 编码后再使用"
            return 1
        fi
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
# 目标选择函数
#===============================================================================

# 列出所有可用模块
list_targets() {
    echo "可用模块列表:"
    echo ""
    local order=("${MODULE_ORDER[@]}")
    for t in "${order[@]}"; do
        local desc="${TARGET_DESCRIPTIONS[$t]:-$t}"
        printf "  %-16s — %s\n" "$t" "$desc"
    done
    echo ""
    echo "用法: --targets system,git,npm,docker-daemon"
}

# 初始化 TARGET_AVAILABLE 和 TARGET_ENABLED
init_targets() {
    for t in "${!TARGET_HANDLERS[@]}"; do
        TARGET_AVAILABLE[$t]=false
        TARGET_ENABLED[$t]=false
    done

    TARGET_AVAILABLE[system]=true
    TARGET_AVAILABLE[shell]=true

    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)
    if [[ "$pkg_mgr" == "apt" ]]; then TARGET_AVAILABLE[apt]=true; fi
    if [[ "$pkg_mgr" =~ ^(dnf|yum)$ ]]; then TARGET_AVAILABLE[dnf]=true; fi
    if command_exists dockerd || command_exists docker; then TARGET_AVAILABLE[docker-daemon]=true; fi
    if command_exists docker; then TARGET_AVAILABLE[docker-client]=true; fi
    if command_exists git; then TARGET_AVAILABLE[git]=true; fi
    if command_exists npm; then TARGET_AVAILABLE[npm]=true; fi
    if command_exists pip3 || command_exists pip; then TARGET_AVAILABLE[pip]=true; fi
    if command_exists curl; then TARGET_AVAILABLE[curl]=true; fi
    if command_exists wget; then TARGET_AVAILABLE[wget]=true; fi
    if command_exists snap; then TARGET_AVAILABLE[snap]=true; fi
    if command_exists containerd; then TARGET_AVAILABLE[containerd]=true; fi
    if command_exists systemctl; then TARGET_AVAILABLE[systemd]=true; fi

    if [[ -n "$TARGETS_FILTER" ]]; then
        IFS=',' read -ra wanted <<< "$TARGETS_FILTER"
        for t in "${wanted[@]}"; do
            t="${t//[[:space:]]/}"
            [[ -z "$t" ]] && continue
            if [[ -n "${TARGET_HANDLERS[$t]:-}" ]]; then
                if ${TARGET_AVAILABLE[$t]}; then
                    TARGET_ENABLED[$t]=true
                else
                    log_warn "模块 '$t' — 对应工具未安装，跳过"
                fi
            else
                log_warn "未知模块: '$t' — 使用 --list-targets 查看可用模块"
            fi
        done
    else
        for t in "${!TARGET_HANDLERS[@]}"; do
            if ${TARGET_AVAILABLE[$t]}; then
                TARGET_ENABLED[$t]=true
            fi
        done
    fi
}

# 交互模式下用户勾选模块 (TUI 方向键操作)
select_targets_interactive() {
    if [[ ! -t 0 ]]; then
        log_warn "终端不支持交互式选择，使用全部已安装模块"
        return 0
    fi

    local available_keys=()
    for t in "${MODULE_ORDER[@]}"; do
        if ${TARGET_AVAILABLE[$t]}; then
            available_keys+=("$t")
        fi
    done
    local total=${#available_keys[@]}

    if [[ $total -eq 0 ]]; then
        log_warn "没有检测到可配置的模块"
        return 0
    fi

    # 终端控制序列
    local ESC=$'\033'
    local CUU="${ESC}[A"       # cursor up
    local CUD="${ESC}[B"       # cursor down
    local CUF="${ESC}[C"       # cursor forward
    local EL="${ESC}[K"        # erase to end of line
    local REV="${ESC}[7m"      # reverse video
    local SGR0="${ESC}[0m"     # reset all attributes
    local DIM="${ESC}[2m"      # dim
    local GREEN="${ESC}[32m"   # green
    local HIDE_CURSOR="${ESC}[?25l"
    local SHOW_CURSOR="${ESC}[?25h"

    # 进入原始模式
    local saved_stty
    saved_stty=$(stty -g 2>/dev/null)
    stty -echo -icanon -ixon min 1 time 0 2>/dev/null
    trap 'stty "$saved_stty" 2>/dev/null; printf "${SHOW_CURSOR}\n"' RETURN
    printf '%s' "$HIDE_CURSOR"

    local cursor=0

    # 打印头部
    echo -e "\n${COLORS[bold]}选择要配置的模块:${COLORS[reset]}"
    echo -e "  ${COLORS[dim]}↑↓ 移动  ${COLORS[cyan]}空格${COLORS[reset]}${COLORS[dim]} 勾选/取消  ${COLORS[cyan]}回车${COLORS[reset]}${COLORS[dim]} 确认  ${COLORS[cyan]}q${COLORS[reset]}${COLORS[dim]} 全选退出${COLORS[reset]}"

    # 渲染函数 — 每次调用重绘全部 item
    _tui_render() {
        local i t desc mark line
        for ((i = 0; i < total; i++)); do
            t="${available_keys[$i]}"
            desc="${TARGET_DESCRIPTIONS[$t]:-$t}"

            if ${TARGET_ENABLED[$t]}; then
                mark="${GREEN}[✓]${SGR0}"
            else
                mark="${DIM}[ ]${SGR0}"
            fi

            # 构建整行
            if [[ $i -eq $cursor ]]; then
                line="${REV}  ${mark} ${desc} ${SGR0}${EL}"
            else
                line="  ${mark} ${desc}${EL}"
            fi

            printf '%s\r\n' "$line"
        done
        # 回到列表第一行
        printf "${CUU}%.0s" $(seq 1 $total)
    }

    _tui_render

    while true; do
        local key key2 key3
        IFS= read -s -r -n 1 key

        case "$key" in
            $'\033')
                read -s -r -n 1 -t 0.01 key2 2>/dev/null || true
                if [[ "$key2" == "[" ]]; then
                    read -s -r -n 1 -t 0.01 key3 2>/dev/null || true
                    case "$key3" in
                        A) [[ $cursor -gt 0 ]] && cursor=$((cursor - 1)) ;;
                        B) [[ $cursor -lt $((total - 1)) ]] && cursor=$((cursor + 1)) ;;
                    esac
                fi
                ;;
            " ")
                local ct="${available_keys[$cursor]}"
                ${TARGET_ENABLED[$ct]} && TARGET_ENABLED[$ct]=false || TARGET_ENABLED[$ct]=true
                ;;
            ""|$'\n') break ;;   # 回车确认
            q|Q) for ct in "${available_keys[@]}"; do TARGET_ENABLED[$ct]=true; done; break ;;
        esac
        _tui_render
    done

    # trap RETURN 恢复终端并显示光标
    local selected_count=0
    for t in "${available_keys[@]}"; do
        ${TARGET_ENABLED[$t]} && selected_count=$((selected_count + 1))
    done
    echo ""
    print_info "已选择 ${COLORS[bold]}${selected_count}${COLORS[reset]} / ${total} 个模块"
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
export ALL_PROXY="${proxy_url}"
export RSYNC_PROXY="${proxy_url}"
EOF
)
    write_file /etc/profile.d/proxy.sh "$proxy_script" "系统代理脚本 /etc/profile.d/proxy.sh"
    sudo_wrap chmod 644 /etc/profile.d/proxy.sh 2>/dev/null || true

    # 同时配置 /etc/environment (PAM 使用, 注意: pam_env.so 不支持引号)
    local env_vars
    env_vars=$(cat <<EOF
${MARKER}
HTTP_PROXY=${proxy_url}
HTTPS_PROXY=${proxy_url}
FTP_PROXY=${proxy_url}
NO_PROXY=${NO_PROXY}
http_proxy=${proxy_url}
https_proxy=${proxy_url}
ftp_proxy=${proxy_url}
no_proxy=${NO_PROXY}
ALL_PROXY=${proxy_url}
all_proxy=${proxy_url}
RSYNC_PROXY=${proxy_url}
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

    # DNF5 (Fedora 41+, RHEL 10+) 使用 drop-in 目录
    # DNF4 / YUM 编辑主配置文件
    local drop_in=""
    local legacy_conf=""

    if [[ "$pkg_manager" == "dnf" ]]; then
        # 检查是否存在 DNF5 drop-in 目录
        if [[ -d /etc/dnf/libdnf5.conf.d ]] || dnf --version 2>/dev/null | grep -q 'dnf5'; then
            drop_in="/etc/dnf/libdnf5.conf.d/99-proxy.conf"
        else
            legacy_conf="/etc/dnf/dnf.conf"
        fi
    else
        legacy_conf="/etc/yum.conf"
    fi

    local content
    content=$(cat <<EOF
${MARKER}
proxy=${proxy_url}
EOF
)

    if $REMOVE_MODE; then
        if [[ -n "$drop_in" ]]; then
            if [[ -f "$drop_in" ]]; then
                remove_file "$drop_in" "DNF5 代理配置"
            else
                log_info "DNF5 代理配置不存在，跳过"
                STAT_SKIPPED=$((STAT_SKIPPED + 1))
            fi
        fi
        if [[ -n "$legacy_conf" ]] && [[ -f "$legacy_conf" ]]; then
            local cleaned
            cleaned=$(grep -v '^proxy=' "$legacy_conf" 2>/dev/null || true)
            write_file "$legacy_conf" "$cleaned" "$legacy_conf (移除代理)"
        elif [[ -z "$drop_in" ]]; then
            log_info "$legacy_conf 不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    if [[ -n "$drop_in" ]]; then
        write_file "$drop_in" "$content" "DNF5 代理配置 (drop-in)"
    elif [[ -n "$legacy_conf" ]]; then
        local existing
        if [[ -f "$legacy_conf" ]]; then
            existing=$(cat "$legacy_conf")
            if grep -q '^proxy=' "$legacy_conf" 2>/dev/null; then
                existing=$(echo "$existing" | sed "s|^proxy=.*|proxy=${proxy_url}|")
            else
                existing+=$'\n'"$content"
            fi
        else
            existing="$content"
        fi
        write_file "$legacy_conf" "$existing" "DNF/YUM 代理配置"
    fi
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
Environment="http_proxy=${proxy_url}"
Environment="https_proxy=${proxy_url}"
Environment="no_proxy=${NO_PROXY}"
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

    local docker_config="${REAL_HOME}/.docker/config.json"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$docker_config" ]]; then
            if command_exists python3; then
                local new_json
                new_json=$(python3 - "$docker_config" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    cfg.pop('proxies', None)
    json.dump(cfg, sys.stdout, indent=2)
    print()
except Exception as e:
    print('ERROR:', str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
)
                if [[ -n "$new_json" ]] && [[ ! "$new_json" =~ ^ERROR: ]]; then
                    write_file "$docker_config" "$new_json" "Docker 客户端代理 (移除)"
                else
                    log_warn "Docker 客户端代理移除 — JSON 处理失败，跳过"
                    STAT_SKIPPED=$((STAT_SKIPPED + 1))
                fi
            elif command_exists jq; then
                local new_json
                new_json=$(jq 'del(.proxies)' "$docker_config" 2>/dev/null)
                if [[ -n "$new_json" ]] && [[ "$new_json" != "null" ]]; then
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
            new_json=$(python3 - "$docker_config" "$proxy_url" "$NO_PROXY" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
cfg['proxies'] = {
    'default': {
        'httpProxy': sys.argv[2],
        'httpsProxy': sys.argv[2],
        'noProxy': sys.argv[3]
    }
}
json.dump(cfg, sys.stdout, indent=2)
print()
PYEOF
)
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
            if [[ -n "$new_json" ]] && [[ "$new_json" != "null" ]]; then
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
        if git config --global --get http.proxyAuthMethod &>/dev/null; then
            git config --global --unset http.proxyAuthMethod 2>/dev/null || true
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
    # 认证代理需显式指定认证方式
    if [[ -n "$PROXY_USER" ]]; then
        git config --global http.proxyAuthMethod basic 2>/dev/null || true
    fi

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

    # 全局 pip 配置
    local pip_conf="/etc/pip.conf"

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
        for user_conf in "${REAL_HOME}/.config/pip/pip.conf" "${REAL_HOME}/.pip/pip.conf"; do
            if [[ -f "$user_conf" ]]; then
                local cleaned
                cleaned=$(grep -vE '^\s*proxy\s*=' "$user_conf" 2>/dev/null || true)
                if [[ -z "$(echo "$cleaned" | tr -d '[:space:]')" ]]; then
                    remove_file "$user_conf" "pip 用户级代理"
                else
                    write_file "$user_conf" "$cleaned" "pip 用户级代理 (移除代理)"
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

    local curlrc="${REAL_HOME}/.curlrc"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$curlrc" ]]; then
            # 移除代理行
            local cleaned
            cleaned=$(grep -vE '^[[:space:]]*(proxy|noproxy)[[:space:]]*=' "$curlrc" 2>/dev/null || true)
            if [[ -z "$(echo "$cleaned" | tr -d '[:space:]')" ]]; then
                remove_file "$curlrc" "curl 代理 (~/.curlrc)"
            else
                write_file "$curlrc" "$cleaned" "curl 代理 (移除 ~/.curlrc)"
            fi
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
        content=$(echo "$content" | grep -vE '^[[:space:]]*(proxy|noproxy)[[:space:]]*=' || true)
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
            # 移除管理的代理行 (含认证字段)
            cleaned=$(grep -vF "$MARKER" "$wgetrc" | grep -vE '^(https?_proxy|ftp_proxy|use_proxy|proxy_user|proxy_password)\s*=' || true)
            write_file "$wgetrc" "$cleaned" "wget 全局代理 (移除)"
            # 同时清理 wget2 配置
            if [[ -f /etc/wget2rc ]]; then
                local w2c
                w2c=$(grep -vF "$MARKER" /etc/wget2rc | grep -vE '^(https?_proxy|ftp_proxy|use_proxy|proxy_user|proxy_password)\s*=' || true)
                write_file /etc/wget2rc "$w2c" "wget2 全局代理 (移除)"
            fi
        else
            log_info "wget 全局配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    local content
    if [[ -f "$wgetrc" ]]; then
        content=$(cat "$wgetrc")
        # 移除旧的代理行和管理标记
        content=$(echo "$content" | grep -vF "$MARKER" | grep -vE '^(https?_proxy|ftp_proxy|use_proxy|proxy_user|proxy_password)\s*=' || true)
        content+=$'\n'"${MARKER}"$'\n'
    else
        content="${MARKER}"$'\n'
    fi
    content+="use_proxy = on"$'\n'
    content+="http_proxy = ${proxy_url}"$'\n'
    content+="https_proxy = ${proxy_url}"$'\n'
    content+="ftp_proxy = ${proxy_url}"
    # wget 不支持 URL 内嵌认证，需单独配置
    if [[ -n "$PROXY_USER" ]]; then
        content+=$'\n'"proxy_user = ${PROXY_USER}"
        [[ -n "$PROXY_PASS" ]] && content+=$'\n'"proxy_password = ${PROXY_PASS}"
    fi

    write_file "$wgetrc" "$content" "wget 全局代理"

    # wget2 兼容 (使用独立配置文件 /etc/wget2rc)
    if command_exists wget2 || (command_exists wget && wget --version 2>/dev/null | grep -qi wget2); then
        local wget2rc="/etc/wget2rc"
        local w2_content
        if [[ -f "$wget2rc" ]]; then
            w2_content=$(cat "$wget2rc")
            w2_content=$(echo "$w2_content" | grep -vF "$MARKER" | grep -vE '^(https?_proxy|ftp_proxy|use_proxy|proxy_user|proxy_password)\s*=' || true)
            w2_content+=$'\n'"${MARKER}"$'\n'
        else
            w2_content="${MARKER}"$'\n'
        fi
        w2_content+="use_proxy = on"$'\n'
        w2_content+="http_proxy = ${proxy_url}"$'\n'
        w2_content+="https_proxy = ${proxy_url}"$'\n'
        w2_content+="ftp_proxy = ${proxy_url}"
        if [[ -n "$PROXY_USER" ]]; then
            w2_content+=$'\n'"proxy_user = ${PROXY_USER}"
            [[ -n "$PROXY_PASS" ]] && w2_content+=$'\n'"proxy_password = ${PROXY_PASS}"
        fi
        write_file "$wget2rc" "$w2_content" "wget2 全局代理 (/etc/wget2rc)"
    fi
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
        # snapd 需重启才能让代理设置生效
        if ! $DRY_RUN && systemctl is-active --quiet snapd 2>/dev/null; then
            sudo_wrap systemctl restart snapd 2>/dev/null || log_warn "snapd 重启失败，请手动执行: sudo systemctl restart snapd"
        fi
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

    # containerd 通过 systemd drop-in 获取代理环境变量
    local containerd_svc="/etc/systemd/system/containerd.service.d/http-proxy.conf"
    local proxy_url
    proxy_url=$(build_proxy_url)

    if $REMOVE_MODE; then
        if [[ -f "$containerd_svc" ]]; then
            remove_file "$containerd_svc" "containerd systemd 代理"
            if ! $DRY_RUN; then
                sudo_wrap systemctl daemon-reload 2>/dev/null || true
                systemctl is-active --quiet containerd 2>/dev/null && sudo_wrap systemctl restart containerd 2>/dev/null || true
            fi
        else
            log_info "containerd systemd 代理配置不存在，跳过"
            STAT_SKIPPED=$((STAT_SKIPPED + 1))
        fi
        return 0
    fi

    if ! systemctl is-active --quiet containerd 2>/dev/null && ! systemctl list-unit-files containerd.service 2>/dev/null | grep -q containerd; then
        log_info "containerd 服务未安装，跳过"
        return 2
    fi

    local content
    content=$(cat <<EOF
${MARKER}
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=${NO_PROXY}"
Environment="http_proxy=${proxy_url}"
Environment="https_proxy=${proxy_url}"
Environment="no_proxy=${NO_PROXY}"
EOF
)
    write_file "$containerd_svc" "$content" "containerd systemd 代理"

    if ! $DRY_RUN; then
        sudo_wrap systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload 失败"
        sudo_wrap systemctl restart containerd 2>/dev/null || log_warn "containerd 重启失败，请手动重启"
    fi
}

#---------------------------------------------------------------------------
# 13. systemd 全局环境代理
#---------------------------------------------------------------------------
configure_systemd() {
    if ! command_exists systemctl; then
        return 2
    fi

    print_header "systemd 全局环境"
    log_warn "这将影响本机所有 systemd 服务 (含数据库、缓存等本地服务)"
    log_warn "如仅需 Docker/containerd 代理，请使用 --targets docker-daemon,containerd"

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
    # 管道模式 (curl|bash): 尝试从 /dev/tty 重新打开终端
    if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]]; then
            # 重定向 stdin 到真实终端
            exec 0</dev/tty 2>/dev/null || {
                log_error "无法打开终端 /dev/tty"
                log_error "请使用命令行模式: curl ... | sudo bash -s -- --proxy <URL>"
                exit 1
            }
        else
            log_error "交互模式需要终端输入 (stdin 不是 TTY 且 /dev/tty 不可用)"
            log_error "请使用命令行模式: curl ... | sudo bash -s -- --proxy <URL>"
            exit 1
        fi
    fi

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
    init_targets

    echo ""
    print_info "检测已安装的应用..."

    local detect_count=0
    local detect_list=()

    local order=("${MODULE_ORDER[@]}")
    for t in "${order[@]}"; do
        local desc="${TARGET_DESCRIPTIONS[$t]:-$t}"
        if ${TARGET_AVAILABLE[$t]}; then
            local mark="${COLORS[green]}✓${COLORS[reset]}"
            if ${TARGET_ENABLED[$t]}; then
                detect_list+=("$mark $desc")
                detect_count=$((detect_count + 1))
            else
                detect_list+=("${COLORS[yellow]}✗${COLORS[reset]} $desc ${COLORS[dim]}(已跳过)${COLORS[reset]}")
            fi
        else
            detect_list+=("${COLORS[dim]}✗${COLORS[reset]} $desc ${COLORS[dim]}(未安装)${COLORS[reset]}")
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

    local order=("${MODULE_ORDER[@]}")

    for t in "${order[@]}"; do
        # 跳过未启用的模块
        if ! ${TARGET_ENABLED[$t]:-false}; then
            continue
        fi

        local handler="${TARGET_HANDLERS[$t]:-}"
        if [[ -z "$handler" ]]; then
            continue
        fi

        total=$((total + 1))
        local rc=0
        $handler || rc=$?

        case $rc in
            0) ;; # 成功或失败已在模块内计入
            2) skipped=$((skipped + 1)) ;;  # 模块未安装
        esac
    done
}

#===============================================================================
# 代理连通性测试
#===============================================================================
verify_connectivity() {
    if $DRY_RUN || $REMOVE_MODE; then return 0; fi
    if ${SKIP_VERIFY:-false}; then
        print_info "连通性测试已跳过 (--skip-verify)"
        return 0
    fi
    if ! command_exists curl; then return 0; fi

    local proxy_url
    proxy_url=$(build_proxy_url)

    echo ""
    print_info "代理连通性测试..."

    # 临时关闭 set -e，curl 失败不应导致脚本退出
    set +e
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 5 --proxy "$proxy_url" "http://www.gstatic.com/generate_204" 2>/dev/null || true)
    set -e

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        log_success "代理连通性测试通过 (gstatic.com → ${http_code})"
        return 0
    fi

    # 区分: 代理不可达 vs 代理可达但目标不可达
    set +e
    local proxy_reachable
    proxy_reachable=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 3 --proxy "$proxy_url" "http://www.gstatic.com/generate_204" 2>/dev/null || true)
    set -e

    if [[ -z "$proxy_reachable" ]] || [[ "$proxy_reachable" == "000" ]]; then
        log_warn "代理连通性测试失败 — 无法连接到代理服务器 ${proxy_url}"
        print_info "请检查:"
        print_info "  1. 代理地址和端口是否正确"
        print_info "  2. 本机能否 ping 通代理服务器"
        print_info "  3. 代理服务器防火墙是否放行"
    else
        log_warn "代理服务器可达 (HTTP ${proxy_reachable})，但外网连通性异常"
        print_info "代理配置已写入，可能是代理本身限制了外网访问"
    fi
    print_info "可跳过此测试: --skip-verify"
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
    if [[ $STAT_BACKED_UP -gt 0 ]]; then
        echo -e "  ${COLORS[dim]}备份目录: ${BACKUP_DIR}${COLORS[reset]}"
        echo -e "  ${COLORS[dim]}清理旧备份: find ${BACKUP_DIR} -name '*.bak' -mtime +30 -delete${COLORS[reset]}"
    fi
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

  --backup-dir <DIR>     备份目录 (默认: /var/backups/proxy-config
                         或 ~/.local/share/proxy-config/backups)

  --log-file <FILE>      日志文件路径 (默认: 自动选择)

  --targets, -t <LIST>   仅配置指定模块 (逗号分隔)
                         示例: --targets git,npm,docker-daemon
                         使用 --list-targets 查看所有可用模块

  --list-targets         列出所有可用模块

  --no-color             禁用彩色输出

  --skip-verify          跳过末尾的代理连通性测试

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
            --targets|-t)
                TARGETS_FILTER="$2"
                shift 2
                ;;
            --list-targets)
                init_targets
                list_targets
                exit 0
                ;;
            --skip-verify)
                SKIP_VERIFY=true
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
                if [[ -z "$NO_PROXY" ]] || [[ "$NO_PROXY" == "$DEFAULT_NO_PROXY" ]]; then
                    NO_PROXY="$value"
                fi
                ;;
            DRY_RUN)    DRY_RUN=$( [[ "$value" =~ ^[Tt] ]] && echo true || echo false) ;;
            REMOVE)     REMOVE_MODE=$( [[ "$value" =~ ^[Tt] ]] && echo true || echo false) ;;
        esac
    done < "$CONFIG_FILE"
}

#===============================================================================
# 初始化
#===============================================================================
initialize() {
    # 计算用户级路径 (基于真实用户 HOME，不是 root 的 HOME)
    local user_backup_dir="${REAL_HOME}/.local/share/proxy-config/backups"
    local user_log_dir="${REAL_HOME}/.local/share/proxy-config"

    # 确定备份目录
    if [[ -z "$BACKUP_DIR" ]]; then
        if is_root && [[ -z "${SUDO_USER:-}" ]]; then
            BACKUP_DIR="$SYSTEM_BACKUP_DIR"
        else
            BACKUP_DIR="$user_backup_dir"
        fi
    fi

    # 确定日志文件
    if [[ -z "$LOG_FILE" ]]; then
        if is_root && [[ -z "${SUDO_USER:-}" ]]; then
            LOG_FILE="${SYSTEM_LOG_DIR}/${SCRIPT_NAME}.log"
        else
            LOG_FILE="${user_log_dir}/${SCRIPT_NAME}.log"
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

    # 检测应用并初始化目标
    detect_applications

    # 交互模式下让用户勾选模块
    if $INTERACTIVE; then
        select_targets_interactive
    fi

    # 执行配置模块
    run_all_configurations

    # 打印总结
    print_summary

    # 连通性测试 (在总结之后)
    verify_connectivity

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
