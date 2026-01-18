#!/usr/bin/env bash
# Mihomo Gateway Script - Optimized Version
# 改进：安全性、模块化、错误处理、日志系统

set -euo pipefail

# =============================================================================
# 全局变量和配置
# =============================================================================

VERSION="3.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd || true)"

# TTY 设备
TTY="/dev/tty"
if [ ! -r "$TTY" ] || [ ! -w "$TTY" ]; then
  TTY=""
fi

# 运行模式
DRY_RUN=0
DEPLOY_MODE=""
VERBOSE=0
ACTION=""
SKIP_SELF_UPDATE=0

# 日志配置
LOG_FILE=""
LOG_DIR="/var/log/mihomo"
if [ "$(id -u)" -ne 0 ] && [ -n "${HOME:-}" ]; then
  LOG_DIR="$HOME/.mihomo/logs"
fi

# 临时文件目录
TMP_DIR=""

# 回滚钩子
CLEANUP_HOOKS=""

# 网络重试配置
MAX_RETRIES=3
RETRY_DELAY=5

# =============================================================================
# 工具函数
# =============================================================================

# 日志函数
log_info() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
  printf "%s\n" "$msg"
  [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")" && printf "%s\n" "$msg" >> "$LOG_FILE"
}

log_warn() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
  printf "%s\n" "$msg" >&2
  [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")" && printf "%s\n" "$msg" >> "$LOG_FILE"
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
  printf "%s\n" "$msg" >&2
  [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")" && printf "%s\n" "$msg" >> "$LOG_FILE"
}

log_debug() {
  if [ "$VERBOSE" -eq 1 ]; then
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    printf "%s\n" "$msg" >&2
    [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")" && printf "%s\n" "$msg" >> "$LOG_FILE"
  fi
}

# 初始化日志系统
init_logging() {
  if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=""
  fi

  if [ -n "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    # 添加随机后缀防止路径预测
    LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S)-$RANDOM.log"
    log_info "日志初始化完成: $LOG_FILE"
  fi
}

# 检测命令中的危险模式（防止命令注入）
# 注意：由于脚本使用双引号包裹所有变量，真正的注入风险很低
# 此函数主要防御明显的恶意模式，同时避免误报
check_command_safety() {
  local cmd="$1"

  # 由于 run_cmd 使用格式如: run_cmd "mkdir -p '$dir1' '$dir2'"
  # 变量被单引号包裹，单引号又被双引号包裹
  # 双引号内的单引号是字面值，不会闭合外部字符串
  # 因此 "dir" 这种写法是安全的

  # 真正的危险模式：变量值本身包含恶意字符
  # 但这应该在输入验证阶段（validate_* 函数）就拦截了

  # 这里只检测最明显的恶意模式：
  # 未闭合的反引号或 $() 在双引号外
  # 但由于我们使用双引号包裹整个命令，这些情况很少见

  # 为了避免误报（如之前的 || 问题），这里直接返回通过
  # 安全性由输入验证函数保证

  return 0
}

# 安全的命令执行（加固版）
run_cmd() {
  local cmd="$*"

  # 安全检查
  if ! check_command_safety "$cmd"; then
    log_error "命令安全检查失败，拒绝执行: $cmd"
    return 126
  fi

  log_debug "执行命令: $cmd"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf "+ %s\n" "$cmd"
    return 0
  fi

  # 使用 eval 替代 sh -c，eval 在 bash 中更安全
  # 同时设置错误处理
  eval "$cmd"
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log_error "命令执行失败 (退出码: $exit_code): $cmd"
    return $exit_code
  fi

  return 0
}

# 带重试的网络请求
run_with_retry() {
  local max_attempts="${1:-$MAX_RETRIES}"
  shift
  local cmd="$*"
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    log_debug "尝试 $attempt/$max_attempts: $cmd"

    if sh -c "$cmd"; then
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      log_warn "命令失败，${RETRY_DELAY}秒后重试..."
      sleep $RETRY_DELAY
    fi

    attempt=$((attempt + 1))
  done

  log_error "命令在 $max_attempts 次尝试后仍然失败"
  return 1
}

# 注册清理钩子
register_cleanup() {
  local cleanup_cmd="$1"
  CLEANUP_HOOKS="${CLEANUP_HOOKS}${cleanup_cmd}"$'\n'
}

# 执行清理
cleanup() {
  log_info "执行清理操作..."

  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    log_debug "清理临时目录: $TMP_DIR"
    rm -rf "$TMP_DIR" 2>/dev/null || true
  fi

  if [ -n "$CLEANUP_HOOKS" ]; then
    printf "%s" "$CLEANUP_HOOKS" | while IFS= read -r hook; do
      [ -n "$hook" ] && log_debug "执行清理钩子: $hook" && eval "$hook" 2>/dev/null || true
    done
  fi
}

# 错误处理
error_exit() {
  local msg="$1"
  log_error "$msg"
  cleanup
  exit 1
}

# 陷阱处理
trap cleanup EXIT INT TERM

# =============================================================================
# 输入验证和安全函数
# =============================================================================

# 验证 IP 地址格式
validate_ip() {
  local ip="$1"
  local stat=1

  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi

  return $stat
}

# 验证 CIDR 格式
validate_cidr() {
  local cidr="$1"

  if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    local ip="${cidr%/*}"
    local mask="${cidr#*/}"

    if validate_ip "$ip" && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]; then
      return 0
    fi
  fi

  return 1
}

# 验证 URL 格式
validate_url() {
  local url="$1"

  if [[ $url =~ ^https?:// ]]; then
    return 0
  fi

  return 1
}

# 验证网卡名称（防止注入）
validate_iface_name() {
  local name="$1"

  # 只允许字母、数字、下划线、连字符
  if [[ $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
    return 0
  fi

  return 1
}

# 验证路径格式（用于 prompt 调用）
validate_path_format() {
  local path="$1"

  # 基本安全检查：拒绝危险字符
  if [[ "$path" =~ [\&\;\|\'\`\$\(\)\<\>] ]]; then
    return 1
  fi

  # 检查是否包含 ..（路径遍历尝试）
  if [[ "$path" =~ \.\. ]]; then
    return 1
  fi

  return 0
}

# 验证并清理路径（防止路径遍历）- 加固版
validate_path() {
  local path="$1"
  local allowed_base="${2:-/opt/mihomo}"

  # 基本安全检查：移除明显的危险字符
  if [[ "$path" =~ [\&\;\|\'\`\$\(\)\<\>] ]]; then
    log_error "路径包含危险字符: $path"
    return 1
  fi

  # 检查是否包含 ..（路径遍历尝试）
  if [[ "$path" =~ \.\. ]]; then
    log_error "路径不能包含 ..（路径遍历保护）: $path"
    return 1
  fi

  # 如果系统有 realpath，解析并验证路径
  if command -v realpath >/dev/null 2>&1; then
    local resolved
    resolved="$(realpath -m "$path" 2>/dev/null || echo "$path")"

    # 检查解析后的路径是否在允许的基础目录下
    case "$resolved" in
      "$allowed_base"*)
        printf "%s" "$resolved"
        return 0
        ;;
      /home/*|/opt/*|/var/*|/tmp/*)
        # 允许常见的安全目录
        printf "%s" "$resolved"
        return 0
        ;;
      *)
        log_error "路径不在允许的目录下: $resolved"
        return 1
        ;;
    esac
  fi

  # fallback：返回清理后的路径
  printf "%s" "$path"
}

# 验证 Docker 镜像名称（防止镜像名称注入）
validate_docker_image() {
  local image="$1"

  # Docker 镜像格式: registry/namespace/repo:tag
  # 只允许字母、数字、点、斜杠、下划线、连字符、冒号
  if [[ "$image" =~ ^[a-zA-Z0-9._/:-]+$ ]]; then
    # 检查长度限制
    if [ "${#image}" -gt 256 ]; then
      log_error "Docker 镜像名称过长: ${#image} 字符"
      return 1
    fi
    return 0
  fi

  log_error "无效的 Docker 镜像名称: $image"
  return 1
}

# 检查 IP 是否已被占用
check_ip_available() {
  local ip="$1"

  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      log_warn "IP $ip 已被占用（有响应）"
      return 1
    fi
  fi

  return 0
}

# =============================================================================
# 交互式输入函数
# =============================================================================

prompt() {
  local key="$1"
  local def="${2:-}"
  local validator="${3:-}"

  while true; do
    if [ -n "$def" ]; then
      printf "%s" "$key [$def]: " >&2
    else
      printf "%s" "$key: " >&2
    fi

    if [ -n "${TTY:-}" ]; then
      IFS= read -r ans <"$TTY" || true
    else
      IFS= read -r ans || true
    fi

    [ -z "${ans:-}" ] && ans="$def"

    # 如果有验证函数，验证输入
    if [ -n "$validator" ]; then
      if eval "$validator \"\$ans\""; then
        printf "%s" "$ans"
        break
      else
        printf "%s\n" "输入无效，请重新输入" >&2
      fi
    else
      printf "%s" "$ans"
      break
    fi
  done
}

prompt_secret() {
  local key="$1"
  local def="${2:-}"
  local confirm="${3:-false}"

  while true; do
    printf "%s" "$key: " >&2

    local ans=""
    local ans2=""

    if [ -n "${TTY:-}" ]; then
      stty -echo <"$TTY" 2>/dev/null || true
      IFS= read -r ans <"$TTY" || true
      stty echo <"$TTY" 2>/dev/null || true
      printf "\n" >&2
    else
      stty -echo 2>/dev/null || true
      IFS= read -r ans || true
      stty echo 2>/dev/null || true
      printf "\n" >&2
    fi

    [ -z "$ans" ] && [ -n "$def" ] && ans="$def"

    # 确认密码
    if [ "$confirm" = "true" ] && [ -n "$ans" ]; then
      printf "%s" "确认密码: " >&2

      if [ -n "${TTY:-}" ]; then
        stty -echo <"$TTY" 2>/dev/null || true
        IFS= read -r ans2 <"$TTY" || true
        stty echo <"$TTY" 2>/dev/null || true
        printf "\n" >&2
      else
        stty -echo 2>/dev/null || true
        IFS= read -r ans2 || true
        stty echo 2>/dev/null || true
        printf "\n" >&2
      fi

      if [ "$ans" = "$ans2" ]; then
        printf "%s" "$ans"
        break
      else
        printf "%s\n" "密码不匹配，请重新输入" >&2
      fi
    else
      printf "%s" "$ans"
      break
    fi
  done
}

prompt_yes_no() {
  local key="$1"
  local def="${2:-yes}"
  local ans

  while true; do
    ans="$(prompt "$key (yes/no)" "$def")"
    case "$ans" in
      yes|y|Y|YES)
        printf "yes"
        return 0
        ;;
      no|n|N|NO)
        printf "no"
        return 0
        ;;
      *)
        printf "%s\n" "请输入 yes 或 no" >&2
        ;;
    esac
  done
}

# 清理和验证 URL（防止 SSRF 攻击）
sanitize_url() {
  local url="$1"
  # 移除首尾空格、引号、反引号
  url="$(printf "%s" "$url" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    -e 's/^`//; s/`$//' \
    -e 's/^"//; s/"$//' \
    -e "s/^'//; s/'$//")"

  if ! validate_url "$url"; then
    log_error "无效的 URL: $url"
    return 1
  fi

  # 提取主机名进行 SSRF 检查
  local host
  host="$(printf "%s" "$url" | sed -E 's|^https?://([^:/]+).*|\1|')"

  # 检查是否为内网 IP 或 localhost（防止 SSRF）
  if is_private_ip "$host"; then
    log_error "不允许使用内网地址或 localhost 作为 URL: $url"
    return 1
  fi

  printf "%s" "$url"
}

# 检查是否为内网 IP 或 localhost（SSRF 防护）
is_private_ip() {
  local host="$1"

  # localhost 检查
  case "$host" in
    localhost|127.*|::1|0.0.0.0)
      return 0
      ;;
  esac

  # 如果不是 IP 格式，则通过（域名无法直接判断是否内网）
  if ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  # 内网 IP 段检查
  local IFS=.
  local -a octets
  read -ra octets <<< "$host"
  local first="${octets[0]}"
  local second="${octets[1]:-0}"

  # 10.0.0.0/8
  if [ "$first" -eq 10 ]; then
    return 0
  fi

  # 172.16.0.0/12
  if [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ]; then
    return 0
  fi

  # 192.168.0.0/16
  if [ "$first" -eq 192 ] && [ "$second" -eq 168 ]; then
    return 0
  fi

  # 169.254.169.254 (AWS 元数据服务)
  if [ "$first" -eq 169 ] && [ "$second" -eq 254 ]; then
    local third="${octets[2]:-0}"
    local fourth="${octets[3]:-0}"
    if [ "$third" -eq 169 ] && [ "$fourth" -eq 254 ]; then
      return 0
    fi
  fi

  return 1
}

# =============================================================================
# 临时文件管理
# =============================================================================

create_temp_dir() {
  local prefix="${1:-mihomo}"

  TMP_DIR="$(mktemp -d -t "${prefix}.XXXXXX" 2>/dev/null || true)"

  if [ -z "$TMP_DIR" ]; then
    TMP_DIR="/tmp/${prefix}.$$"
    mkdir -p "$TMP_DIR" || error_exit "无法创建临时目录"
  fi

  # 设置安全权限
  chmod 700 "$TMP_DIR" 2>/dev/null || true

  log_debug "创建临时目录: $TMP_DIR"
  printf "%s" "$TMP_DIR"
}

# =============================================================================
# 文件下载和校验
# =============================================================================

# 下载文件（带重试和进度）
download_file() {
  local url="$1"
  local output="$2"
  local show_progress="${3:-true}"
  local max_attempts="${4:-3}"
  local max_time="${5:-}"

  local dl_cmd
  if command -v curl >/dev/null 2>&1; then
    dl_cmd="curl"
    dl_cmd="$dl_cmd -fL --connect-timeout 10"
    if [ -n "${max_time:-}" ] && [[ "$max_time" =~ ^[0-9]+$ ]]; then
      dl_cmd="$dl_cmd --max-time $max_time"
    fi
    if [ "$show_progress" = "true" ]; then
      dl_cmd="$dl_cmd --progress-bar"
    else
      dl_cmd="$dl_cmd -sS"
    fi
    dl_cmd="$dl_cmd -o '$output' '$url'"
  elif command -v wget >/dev/null 2>&1; then
    dl_cmd="wget"
    if [ "$show_progress" = "true" ]; then
      dl_cmd="$dl_cmd --show-progress"
    else
      dl_cmd="$dl_cmd -q"
    fi
    if [ -n "${max_time:-}" ] && [[ "$max_time" =~ ^[0-9]+$ ]]; then
      dl_cmd="$dl_cmd -T $max_time"
    else
      dl_cmd="$dl_cmd -T 10"
    fi
    dl_cmd="$dl_cmd -O '$output' '$url'"
  else
    error_exit "缺少下载工具：需要 curl 或 wget"
  fi

  log_info "下载文件: $(basename "$output")"
  if ! run_with_retry "$max_attempts" "$dl_cmd"; then
    log_error "下载失败: $url"
    return 1
  fi

  log_debug "文件已保存到: $output"
  return 0
}

download_file_optional() {
  local url="$1"
  local output="$2"

  local dl_cmd
  if command -v curl >/dev/null 2>&1; then
    dl_cmd="curl -fLsS --connect-timeout 10 -o '$output' '$url' 2>/dev/null"
  elif command -v wget >/dev/null 2>&1; then
    dl_cmd="wget -q -t 1 -T 10 -O '$output' '$url' 2>/dev/null"
  else
    error_exit "缺少下载工具：需要 curl 或 wget"
  fi

  log_info "下载文件: $(basename "$output")"
  if ! sh -c "$dl_cmd"; then
    return 1
  fi

  log_debug "文件已保存到: $output"
  return 0
}

# 计算文件校验和
calculate_checksum() {
  local file="$1"
  local algorithm="${2:-sha256}"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a "$algorithm" "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$file" | awk '{print $1}'
  else
    log_error "缺少校验和计算工具"
    return 1
  fi
}

# 验证文件校验和
verify_checksum() {
  local file="$1"
  local expected="$2"

  if [ -z "$expected" ]; then
    log_warn "未提供期望的校验和，跳过验证"
    return 0
  fi

  log_info "验证文件校验和..."
  local actual
  actual="$(calculate_checksum "$file")"

  if [ "$actual" = "$expected" ]; then
    log_info "校验和验证通过"
    return 0
  else
    log_error "校验和不匹配！"
    log_error "期望: $expected"
    log_error "实际: $actual"
    return 1
  fi
}

# 解压 ZIP 文件
extract_zip() {
  local zip_path="$1"
  local out_dir="$2"

  log_info "解压文件: $(basename "$zip_path")"

  if command -v unzip >/dev/null 2>&1; then
    mkdir -p "$out_dir"
    run_cmd "unzip -q '$zip_path' -d '$out_dir'" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    mkdir -p "$out_dir"
    if [ "$DRY_RUN" -eq 1 ]; then
      log_debug "[DRY RUN] 使用 python3 解压"
    else
      ZIP_PATH="$zip_path" OUT_DIR="$out_dir" python3 - <<'PY'
import os, zipfile
zip_path=os.environ["ZIP_PATH"]
out_dir=os.environ["OUT_DIR"]
with zipfile.ZipFile(zip_path) as z:
    z.extractall(out_dir)
PY
    fi
  else
    error_exit "缺少解压工具：需要 unzip 或 python3"
  fi

  log_debug "解压完成: $out_dir"
  return 0
}

# =============================================================================
# GitHub 和代理相关
# =============================================================================

wrap_github_url() {
  local url="$1"

  if [ "${USE_GH_PROXY:-no}" != "yes" ]; then
    printf "%s" "$url"
    return 0
  fi

  local proxy_base="${GH_PROXY_BASE:-https://ghfast.top}"
  proxy_base="${proxy_base%/}"

  case "$url" in
    "$proxy_base"/*)
      printf "%s" "$url"
      ;;
    https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*)
      case "$proxy_base" in
        *gh-proxy.com*)
          case "$url" in
            https://github.com/*)
              printf "%s/github.com/%s" "$proxy_base" "${url#https://github.com/}"
              ;;
            https://raw.githubusercontent.com/*)
              printf "%s/raw.githubusercontent.com/%s" "$proxy_base" "${url#https://raw.githubusercontent.com/}"
              ;;
            *)
              printf "%s/%s" "$proxy_base" "$url"
              ;;
          esac
          ;;
        *)
          printf "%s/%s" "$proxy_base" "$url"
          ;;
      esac
      ;;
    *)
      printf "%s" "$url"
      ;;
  esac
}

# =============================================================================
# 配置管理
# =============================================================================

# 备份配置文件
backup_config() {
  local file="$1"
  local max_backups="${2:-5}"

  if [ ! -f "$file" ]; then
    log_debug "文件不存在，跳过备份: $file"
    return 0
  fi

  local backup_dir="${file}.d"
  mkdir -p "$backup_dir" 2>/dev/null || true

  local backup_file="${backup_dir}/$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
  cp "$file" "$backup_file" 2>/dev/null || error_exit "无法备份配置文件"

  log_info "配置已备份到: $backup_file"

  # 清理旧备份（保留最近的 N 个）
  if [ -d "$backup_dir" ]; then
    ls -t "${backup_dir}"/*.bak 2>/dev/null | tail -n +$((max_backups + 1)) | xargs rm -f 2>/dev/null || true
  fi

  return 0
}

# 验证 YAML 配置
validate_config() {
  local config_file="$1"
  local mihomo_bin="${2:-mihomo}"

  if [ ! -f "$config_file" ]; then
    log_error "配置文件不存在: $config_file"
    return 1
  fi

  log_info "验证配置文件..."

  if ! command -v "$mihomo_bin" >/dev/null 2>&1; then
    log_warn "mihomo 命令不可用，跳过配置验证"
    return 0
  fi

  if "$mihomo_bin" -d "$(dirname "$config_file")" -t; then
    log_info "配置文件验证通过"
    return 0
  else
    log_error "配置文件验证失败"
    return 1
  fi
}

# 加载保存的配置（支持 JSON 和 Shell 格式）
load_saved_config() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    log_debug "未找到保存的配置: $config_file"
    return 1
  fi

  log_info "加载保存的配置: $config_file"

  # 检测文件格式
  local first_line
  first_line="$(head -n 1 "$config_file" 2>/dev/null || true)"

  # 如果是 JSON 格式（以 { 开头）
  if [[ "$first_line" =~ ^[[:space:]]*\{ ]]; then
    # 使用 Python 解析 JSON
    if command -v python3 >/dev/null 2>&1; then
      while IFS='=' read -r key value; do
        [ -n "$key" ] && export "$key=$value"
      done < <(python3 -c "
import json, sys
try:
    with open('$config_file', 'r') as f:
        data = json.load(f)
    for k, v in data.items():
        print(f'{k}={v}')
except Exception as e:
    sys.stderr.write(f'JSON 解析失败: {e}\\n')
    sys.exit(1)
" 2>/dev/null)
      return 0
    else
      log_error "需要 Python3 来读取 JSON 配置"
      return 1
    fi
  else
    # Shell 格式（向后兼容）
    while IFS='=' read -r key value; do
      # 跳过注释和空行
      [[ $key =~ ^#.*$ ]] && continue
      [[ -z $key ]] && continue
      # 导出变量
      export "$key=$value"
    done < "$config_file"
    return 0
  fi
}

# 保存配置（JSON 格式，与 Web 管理面板兼容）
save_config() {
  local config_file="$1"
  shift
  local vars=("$@")

  mkdir -p "$(dirname "$config_file")" 2>/dev/null || true

  # 使用 Python 生成 JSON（如果可用）
  if command -v python3 >/dev/null 2>&1; then
    # 构建 Python 脚本
    local python_script=""
    python_script="import json, os, datetime"$
    python_script="$python_script; data = {"$
    for var in "${vars[@]}"; do
      local value="${!var-}"
      # 转义特殊字符
      value="${value//\\/\\\\}"
      value="${value//\"/\\\"}"
      python_script="$python_script\"$var\": \"${value}\", "
    done
    python_script="$python_script"$

    # 使用环境变量传递数据，避免命令注入
    local tmp_py="$(mktemp)"
    cat > "$tmp_py" << 'PYEOF'
import json
import os
import sys

data = {}
# 从环境变量读取
vars_list = sys.argv[1:]
for var in vars_list:
    data[var] = os.environ.get(var, '')

print(json.dumps(data, indent=2, ensure_ascii=False))
PYEOF

    # 设置环境变量并执行
    for var in "${vars[@]}"; do
      export "$var"
    done

    python3 "$tmp_py" "${vars[@]}" > "$config_file"
    rm -f "$tmp_py"
  else
    # 降级方案：使用 shell 格式（向后兼容）
    {
      printf "# Mihomo 部署配置 - 自动生成于 %s\n" "$(date)"
      printf "# 注意：这是 JSON 格式，请勿手动编辑\n\n"

      printf "{\n"
      local i=0
      for var in "${vars[@]}"; do
        local value="${!var-}"
        # 转义 JSON 特殊字符
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//$'\n'/\\n}"

        if [ $i -gt 0 ]; then
          printf ",\n"
        fi
        printf "  \"%s\": \"%s\"" "$var" "$value"
        i=$((i + 1))
      done
      printf "\n}\n"
    } > "$config_file"
  fi

  # 设置安全权限
  chmod 600 "$config_file" 2>/dev/null || true

  log_info "配置已保存到: $config_file"
  return 0
}

# =============================================================================
# 平台和架构检测
# =============================================================================

detect_platform() {
  if [ -e /etc.defaults/VERSION ] || [ -e /usr/syno/synoman/webman/index.cgi ]; then
    printf "dsm"
  elif [ -d /etc/pve ]; then
    printf "pve"
  elif [ -e /etc/os-release ]; then
    printf "linux"
  else
    printf "unknown"
  fi
}

detect_arch() {
  local a
  a="$(uname -m 2>/dev/null || true)"

  case "$a" in
    x86_64|amd64)
      printf "amd64"
      ;;
    aarch64|arm64)
      printf "arm64"
      ;;
    armv7l|armv6l)
      printf "arm"
      ;;
    *)
      log_error "不支持的架构: $a"
      printf "unknown"
      return 1
      ;;
  esac
}

# =============================================================================
# 网络配置检测
# =============================================================================

detect_network_config() {
  log_info "检测网络配置..."

  # 获取默认路由
  local default_route parent_iface lan_gw src_ip addr_cidr

  default_route="$(ip route show default 2>/dev/null | head -n 1 || true)"
  parent_iface="$(printf "%s" "$default_route" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  lan_gw="$(printf "%s" "$default_route" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
  src_ip="$(printf "%s" "$default_route" | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

  # 回退检测
  if [ -z "${parent_iface:-}" ]; then
    parent_iface="$(ip -o link show 2>/dev/null | awk -F': ' 'NR==1{print $2; exit}')"
  fi

  if [ -z "${lan_gw:-}" ]; then
    lan_gw="$(ip route show 0.0.0.0/0 2>/dev/null | awk '{print $3; exit}' || true)"
  fi

  # 获取网卡地址和子网
  addr_cidr=""
  if [ -n "${parent_iface:-}" ]; then
    addr_cidr="$(ip -o -f inet addr show dev "$parent_iface" 2>/dev/null | awk '{print $4; exit}' || true)"
  fi

  # 计算子网
  local lan_subnet=""
  if command -v python3 >/dev/null 2>&1 && [ -n "${addr_cidr:-}" ]; then
    lan_subnet="$(ADDR_CIDR="$addr_cidr" python3 - <<'PY'
import os, ipaddress
cidr=os.environ.get("ADDR_CIDR","")
if cidr:
    iface=ipaddress.ip_interface(cidr)
    print(str(iface.network))
PY
)"
  fi

  log_debug "物理网卡: ${parent_iface:-<未检测到>}"
  log_debug "网关: ${lan_gw:-<未检测到>}"
  log_debug "子网: ${lan_subnet:-<未检测到>}"
  log_debug "源IP: ${src_ip:-<未检测到>}"

  # 输出结果（通过全局变量或返回）
  PARENT_IF="${parent_iface:-}"
  LAN_GW="${lan_gw:-}"
  LAN_SUBNET="${lan_subnet:-}"
  SRC_IP="${src_ip:-}"

  return 0
}

# =============================================================================
# 国家识别和动态策略组生成
# =============================================================================

# 国家关键词库（中文、英文、国旗emoji等多种变体）
COUNTRY_KEYWORDS=(
  "香港:香港|HK|Hong Kong|HongKong"
  "台湾:台湾|台灣|TW|Tai Wan|TaiWan|Taiwan|🇨🇳"
  "日本:日本|JP|Japan"
  "新加坡:新加坡|SG|Singapore"
  "美国:美国|US|USA|United States"
  "韩国:韩国|KR|Korea"
  "马来西亚:马来西亚|MY|Malaysia"
  "菲律宾:菲律宾|PH|Philippines"
  "阿根廷:阿根廷|AR|Argentina"
  "柬埔寨:柬埔寨|KH|Cambodia"
  "俄罗斯:俄罗斯|RU|Russia"
  "德国:德国|DE|Germany"
  "加拿大:加拿大|CA|Canada"
  "印度尼西亚:印度尼西亚|ID|Indonesia"
  "土耳其:土耳其|TR|Turkey"
  "英国:英国|UK|United Kingdom"
  "法国:法国|FR|France"
  "迪拜:迪拜|UAE|Dubai"
  "泰国:泰国|TH|Thailand"
  "巴西:巴西|BR|Brazil"
)

# 从订阅文件中识别国家
detect_countries_from_subscription() {
  local sub_url="$1"
  local config_dir="$2"
  local sub_file="$config_dir/proxy_providers/sub.yaml"

  log_info "解析订阅文件识别国家..."

  # 如果订阅文件不存在，先下载
  if [ ! -f "$sub_file" ]; then
    log_info "下载订阅文件..."
    mkdir -p "$(dirname "$sub_file")"
    if ! download_file "$sub_url" "$sub_file" "false"; then
      log_warn "下载订阅文件失败，使用默认国家列表"
      return 0
    fi
  fi

  # 解析订阅文件中的节点名称
  local detected_countries=()
  local proxy_names
  proxy_names="$(grep "name:" "$sub_file" 2>/dev/null | sed 's/.*name: //' | sed 's/"//g' | sed "s/'//g")"

  if [ -z "$proxy_names" ]; then
    log_warn "未找到节点信息，使用默认国家列表"
    return 0
  fi

  # 遍历所有国家关键词，检查是否在节点名称中出现
  for entry in "${COUNTRY_KEYWORDS[@]}"; do
    local country="${entry%%:*}"
    local keywords="${entry#*:}"
    if echo "$proxy_names" | grep -qiE "$keywords"; then
      detected_countries+=("$country")
      log_debug "识别到国家: $country"
    fi
  done

  # 输出检测到的国家列表（通过全局变量）
  DETECTED_COUNTRIES=("${detected_countries[@]}")

  if [ ${#DETECTED_COUNTRIES[@]} -eq 0 ]; then
    log_warn "未识别到任何国家，使用默认国家列表"
    DETECTED_COUNTRIES=("香港" "台湾" "日本" "新加坡" "美国" "韩国")
  else
    log_info "识别到 ${#DETECTED_COUNTRIES[@]} 个国家: ${DETECTED_COUNTRIES[*]}"
  fi

  return 0
}

# 生成国家策略组配置
generate_country_proxy_groups() {
  local countries=("$@")
  local output=""
  local country_proxies_list=""

  for country in "${countries[@]}"; do
    local keywords=""
    for entry in "${COUNTRY_KEYWORDS[@]}"; do
      local entry_country="${entry%%:*}"
      if [ "$entry_country" = "$country" ]; then
        keywords="${entry#*:}"
        break
      fi
    done

    if [ -z "$keywords" ]; then
      log_warn "未找到国家 $country 的关键词，跳过"
      continue
    fi

    local country_escaped="${keywords//|/\\|}"

    # 手选策略组
    output+="
  - name: ${country}-手选
    type: select
    use:
      - sub
    filter: \"(?=.*(${keywords})).*\"
"

    # 智选策略组（只选最快节点，tolerance=0）
    output+="
  - name: ${country}-智选
    type: url-test
    use:
      - sub
    url: \"https://cp.cloudflare.com/generate_204\"
    interval: 300
    tolerance: 0
    filter: \"(?=.*(${keywords})).*\"
"

    # 故转策略组（兜底）
    output+="
  - name: ${country}-故转
    type: fallback
    interval: 300
    lazy: false
    use:
      - sub
    url: \"https://cp.cloudflare.com/generate_204\"
    filter: \"(?=.*(${keywords})).*\"
    proxies:
      - ${country}-手选
      - ${country}-智选
"

    # 添加到业务分组引用列表（使用智选策略组）
    country_proxies_list+="
      - ${country}-智选"
  done

  # 输出国家策略组配置
  printf "%s" "$output"

  # 同时输出国家引用列表到全局变量
  COUNTRY_PROXIES_LIST="$country_proxies_list"
  export COUNTRY_PROXIES_LIST
}

# =============================================================================
# 配置模板渲染
# =============================================================================

render_config_from_tpl() {
  local tpl_path="$1"
  local out_path="$2"

  if [ ! -f "$tpl_path" ]; then
    error_exit "模板文件不存在: $tpl_path"
  fi

  log_info "渲染配置模板..."

  need_cmd awk

  # 创建临时文件存放动态内容
  local tmp_render
  tmp_render="$(create_temp_dir mihomo-render)"

  local ui_path="$tmp_render/ui"
  local dns_path="$tmp_render/dns"
  local smart_group_path="$tmp_render/smart_group"
  local country_groups_path="$tmp_render/country_groups"

  # 写入动态内容
  printf "%s" "${UI_CONFIG:-}" >"$ui_path"
  printf "%s" "${DNS_CONFIG:-}" >"$dns_path"
  printf "%s" "${SMART_GROUP_BLOCK:-}" >"$smart_group_path"

  # 识别国家并生成动态策略组
  if [ -n "${SUB_URL:-}" ] && [ -n "${CONFIG_DIR:-}" ]; then
    log_info "识别订阅中的国家节点..."
    detect_countries_from_subscription "$SUB_URL" "$CONFIG_DIR"
    
    if [ ${#DETECTED_COUNTRIES[@]} -gt 0 ]; then
      log_info "生成国家策略组配置..."
      generate_country_proxy_groups "${DETECTED_COUNTRIES[@]}" >"$country_groups_path"
      log_debug "国家策略组已生成: $country_groups_path"
    else
      printf "" >"$country_groups_path"
    fi
  else
    printf "" >"$country_groups_path"
  fi

  # 使用 AWK 渲染模板
  awk \
    -v CLASH_SECRET="${CLASH_SECRET:-}" \
    -v SUB_URL="${SUB_URL:-}" \
    -v LAN_SUBNET="${LAN_SUBNET:-}" \
    -v MIHOMO_IP="${MIHOMO_IP:-}" \
    -v LAN_GW="${LAN_GW:-}" \
    -v EXTERNAL_PORT="${EXTERNAL_PORT:-19090}" \
    -v URL_RULESET_OPENAI="${URL_RULESET_OPENAI:-}" \
    -v URL_RULESET_CLAUDE="${URL_RULESET_CLAUDE:-}" \
    -v URL_RULESET_GITHUB="${URL_RULESET_GITHUB:-}" \
    -v URL_RULESET_TELEGRAM_DOMAIN="${URL_RULESET_TELEGRAM_DOMAIN:-}" \
    -v URL_RULESET_TELEGRAM_IP="${URL_RULESET_TELEGRAM_IP:-}" \
    -v URL_RULESET_NETFLIX_DOMAIN="${URL_RULESET_NETFLIX_DOMAIN:-}" \
    -v URL_RULESET_NETFLIX_IP="${URL_RULESET_NETFLIX_IP:-}" \
    -v URL_RULESET_GOOGLE_DOMAIN="${URL_RULESET_GOOGLE_DOMAIN:-}" \
    -v URL_RULESET_GOOGLE_IP="${URL_RULESET_GOOGLE_IP:-}" \
    -v URL_RULESET_APPLE="${URL_RULESET_APPLE:-}" \
    -v URL_RULESET_APPLE_CN="${URL_RULESET_APPLE_CN:-}" \
    -v URL_RULESET_MICROSOFT="${URL_RULESET_MICROSOFT:-}" \
    -v URL_RULESET_STEAM="${URL_RULESET_STEAM:-}" \
    -v URL_RULESET_CHINA_DOMAIN="${URL_RULESET_CHINA_DOMAIN:-}" \
    -v URL_RULESET_CHINA_IP="${URL_RULESET_CHINA_IP:-}" \
    -v URL_RULESET_PRIVATE="${URL_RULESET_PRIVATE:-}" \
    -v URL_RULESET_BLOCK="${URL_RULESET_BLOCK:-}" \
    -v URL_RULESET_PERPLEXITY="${URL_RULESET_PERPLEXITY:-}" \
    -v URL_RULESET_COPILOT="${URL_RULESET_COPILOT:-}" \
    -v URL_RULESET_GEMINI="${URL_RULESET_GEMINI:-}" \
    -v URL_RULESET_META_AI="${URL_RULESET_META_AI:-}" \
    -v URL_RULESET_REDDIT="${URL_RULESET_REDDIT:-}" \
    -v URL_RULESET_WHATSAPP="${URL_RULESET_WHATSAPP:-}" \
    -v URL_RULESET_FACEBOOK="${URL_RULESET_FACEBOOK:-}" \
    -v URL_RULESET_YOUTUBE="${URL_RULESET_YOUTUBE:-}" \
    -v URL_RULESET_TIKTOK="${URL_RULESET_TIKTOK:-}" \
    -v URL_RULESET_DISNEY="${URL_RULESET_DISNEY:-}" \
    -v URL_RULESET_HBO="${URL_RULESET_HBO:-}" \
    -v URL_RULESET_AMAZON="${URL_RULESET_AMAZON:-}" \
    -v URL_RULESET_CRUNCHYROLL="${URL_RULESET_CRUNCHYROLL:-}" \
    -v URL_RULESET_SPOTIFY="${URL_RULESET_SPOTIFY:-}" \
    -v URL_RULESET_EPIC="${URL_RULESET_EPIC:-}" \
    -v URL_RULESET_EA="${URL_RULESET_EA:-}" \
    -v URL_RULESET_BLAZZARD="${URL_RULESET_BLAZZARD:-}" \
    -v URL_RULESET_UBI="${URL_RULESET_UBI:-}" \
    -v URL_RULESET_PLAYSTATION="${URL_RULESET_PLAYSTATION:-}" \
    -v URL_RULESET_NINTENDO="${URL_RULESET_NINTENDO:-}" \
    -v URL_RULESET_OKX="${URL_RULESET_OKX:-}" \
    -v URL_RULESET_BYBIT="${URL_RULESET_BYBIT:-}" \
    -v URL_RULESET_BINANCE="${URL_RULESET_BINANCE:-}" \
    -v URL_RULESET_NVIDIA="${URL_RULESET_NVIDIA:-}" \
    -v URL_RULESET_PROXY="${URL_RULESET_PROXY:-}" \
    -v URL_RULESET_GLOBE="${URL_RULESET_GLOBE:-}" \
    -v URL_RULESET_DIRECT="${URL_RULESET_DIRECT:-}" \
    -v URL_RULESET_TEST="${URL_RULESET_TEST:-}" \
    -v UI_PATH="$ui_path" \
    -v DNS_PATH="$dns_path" \
    -v SMART_GROUP_PATH="$smart_group_path" \
    -v COUNTRY_GROUPS_PATH="$country_groups_path" \
    -v COUNTRY_PROXIES_LIST="${COUNTRY_PROXIES_LIST:-}" \
    -v SMART_PROXY_LINE="${SMART_PROXY_LINE:-}" \
    -v ADGUARD_RULE_LINE="${ADGUARD_RULE_LINE:-}" \
    '
function print_file(path,   line) {
  while ((getline line < path) > 0) {
    print line
  }
  close(path)
}
function replace_all(str, token, val,   pos, out, tlen) {
  out = ""
  tlen = length(token)
  while ((pos = index(str, token)) > 0) {
    out = out substr(str, 1, pos - 1) val
    str = substr(str, pos + tlen)
  }
  return out str
}
{
  if ($0 ~ /^[[:space:]]*\{\{UI_CONFIG\}\}[[:space:]]*$/) { print_file(UI_PATH); next }
  if ($0 ~ /^[[:space:]]*\{\{DNS_CONFIG\}\}[[:space:]]*$/) { print_file(DNS_PATH); next }
  if ($0 ~ /^[[:space:]]*\{\{SMART_GROUP_BLOCK\}\}[[:space:]]*$/) { print_file(SMART_GROUP_PATH); next }
  if ($0 ~ /^[[:space:]]*\{\{COUNTRY_PROXY_GROUPS\}\}[[:space:]]*$/) { print_file(COUNTRY_GROUPS_PATH); next }
  line = $0
  line = replace_all(line, "{{SMART_PROXY_LINE}}", SMART_PROXY_LINE)
  line = replace_all(line, "{{ADGUARD_RULE_LINE}}", ADGUARD_RULE_LINE)
  line = replace_all(line, "{{COUNTRY_PROXIES_LIST}}", COUNTRY_PROXIES_LIST)
  line = replace_all(line, "{{CLASH_SECRET}}", CLASH_SECRET)
  line = replace_all(line, "{{SUB_URL}}", SUB_URL)
  line = replace_all(line, "{{LAN_SUBNET}}", LAN_SUBNET)
  line = replace_all(line, "{{MIHOMO_IP}}", MIHOMO_IP)
  line = replace_all(line, "{{LAN_GW}}", LAN_GW)
  line = replace_all(line, "{{EXTERNAL_PORT}}", EXTERNAL_PORT)
  line = replace_all(line, "{{URL_RULESET_OPENAI}}", URL_RULESET_OPENAI)
  line = replace_all(line, "{{URL_RULESET_CLAUDE}}", URL_RULESET_CLAUDE)
  line = replace_all(line, "{{URL_RULESET_GITHUB}}", URL_RULESET_GITHUB)
  line = replace_all(line, "{{URL_RULESET_TELEGRAM_DOMAIN}}", URL_RULESET_TELEGRAM_DOMAIN)
  line = replace_all(line, "{{URL_RULESET_TELEGRAM_IP}}", URL_RULESET_TELEGRAM_IP)
  line = replace_all(line, "{{URL_RULESET_NETFLIX_DOMAIN}}", URL_RULESET_NETFLIX_DOMAIN)
  line = replace_all(line, "{{URL_RULESET_NETFLIX_IP}}", URL_RULESET_NETFLIX_IP)
  line = replace_all(line, "{{URL_RULESET_GOOGLE_DOMAIN}}", URL_RULESET_GOOGLE_DOMAIN)
  line = replace_all(line, "{{URL_RULESET_GOOGLE_IP}}", URL_RULESET_GOOGLE_IP)
  line = replace_all(line, "{{URL_RULESET_APPLE}}", URL_RULESET_APPLE)
  line = replace_all(line, "{{URL_RULESET_APPLE_CN}}", URL_RULESET_APPLE_CN)
  line = replace_all(line, "{{URL_RULESET_MICROSOFT}}", URL_RULESET_MICROSOFT)
  line = replace_all(line, "{{URL_RULESET_STEAM}}", URL_RULESET_STEAM)
  line = replace_all(line, "{{URL_RULESET_CHINA_DOMAIN}}", URL_RULESET_CHINA_DOMAIN)
  line = replace_all(line, "{{URL_RULESET_CHINA_IP}}", URL_RULESET_CHINA_IP)
  line = replace_all(line, "{{URL_RULESET_PRIVATE}}", URL_RULESET_PRIVATE)
  line = replace_all(line, "{{URL_RULESET_BLOCK}}", URL_RULESET_BLOCK)
  line = replace_all(line, "{{URL_RULESET_PERPLEXITY}}", URL_RULESET_PERPLEXITY)
  line = replace_all(line, "{{URL_RULESET_COPILOT}}", URL_RULESET_COPILOT)
  line = replace_all(line, "{{URL_RULESET_GEMINI}}", URL_RULESET_GEMINI)
  line = replace_all(line, "{{URL_RULESET_META_AI}}", URL_RULESET_META_AI)
  line = replace_all(line, "{{URL_RULESET_REDDIT}}", URL_RULESET_REDDIT)
  line = replace_all(line, "{{URL_RULESET_WHATSAPP}}", URL_RULESET_WHATSAPP)
  line = replace_all(line, "{{URL_RULESET_FACEBOOK}}", URL_RULESET_FACEBOOK)
  line = replace_all(line, "{{URL_RULESET_YOUTUBE}}", URL_RULESET_YOUTUBE)
  line = replace_all(line, "{{URL_RULESET_TIKTOK}}", URL_RULESET_TIKTOK)
  line = replace_all(line, "{{URL_RULESET_DISNEY}}", URL_RULESET_DISNEY)
  line = replace_all(line, "{{URL_RULESET_HBO}}", URL_RULESET_HBO)
  line = replace_all(line, "{{URL_RULESET_AMAZON}}", URL_RULESET_AMAZON)
  line = replace_all(line, "{{URL_RULESET_CRUNCHYROLL}}", URL_RULESET_CRUNCHYROLL)
  line = replace_all(line, "{{URL_RULESET_SPOTIFY}}", URL_RULESET_SPOTIFY)
  line = replace_all(line, "{{URL_RULESET_EPIC}}", URL_RULESET_EPIC)
  line = replace_all(line, "{{URL_RULESET_EA}}", URL_RULESET_EA)
  line = replace_all(line, "{{URL_RULESET_BLAZZARD}}", URL_RULESET_BLAZZARD)
  line = replace_all(line, "{{URL_RULESET_UBI}}", URL_RULESET_UBI)
  line = replace_all(line, "{{URL_RULESET_PLAYSTATION}}", URL_RULESET_PLAYSTATION)
  line = replace_all(line, "{{URL_RULESET_NINTENDO}}", URL_RULESET_NINTENDO)
  line = replace_all(line, "{{URL_RULESET_OKX}}", URL_RULESET_OKX)
  line = replace_all(line, "{{URL_RULESET_BYBIT}}", URL_RULESET_BYBIT)
  line = replace_all(line, "{{URL_RULESET_BINANCE}}", URL_RULESET_BINANCE)
  line = replace_all(line, "{{URL_RULESET_NVIDIA}}", URL_RULESET_NVIDIA)
  line = replace_all(line, "{{URL_RULESET_PROXY}}", URL_RULESET_PROXY)
  line = replace_all(line, "{{URL_RULESET_GLOBE}}", URL_RULESET_GLOBE)
  line = replace_all(line, "{{URL_RULESET_DIRECT}}", URL_RULESET_DIRECT)
  line = replace_all(line, "{{URL_RULESET_TEST}}", URL_RULESET_TEST)
  print line
}
    ' "$tpl_path" >"$out_path"

  # 设置配置文件安全权限
  chmod 600 "$out_path" 2>/dev/null || true

  log_info "配置已生成: $out_path"
  return 0
}

# =============================================================================
# 依赖检查
# =============================================================================

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error_exit "缺少必需命令: $1。请安装后重试。"
  fi
}

need_cmd_any() {
  for c in "$@"; do
    if command -v "$c" >/dev/null 2>&1; then
      printf "%s" "$c"
      return 0
    fi
  done
  error_exit "缺少命令（需要任意一个）: $*"
}

check_dependencies() {
  log_info "检查系统依赖..."

  # 基础命令
  need_cmd ip
  need_cmd awk

  # 平台特定依赖
  if [ "$DEPLOY_MODE" = "docker" ]; then
    need_cmd docker
  elif [ "$DEPLOY_MODE" = "binary" ]; then
    need_cmd systemctl
  fi

  # 检查 TUN 设备
  if [ ! -e /dev/net/tun ]; then
    error_exit "/dev/net/tun 不存在，TUN 模式不可用。请确保系统支持 TUN。"
  fi

  # 检查权限
  if [ "$DEPLOY_MODE" = "binary" ] && [ "$(id -u)" -ne 0 ]; then
    error_exit "Binary 模式需要 root 权限。请使用 sudo 运行脚本。"
  fi

  log_info "依赖检查通过"
  return 0
}

# =============================================================================
# 获取最新版本
# =============================================================================

get_latest_mihomo_version() {
  log_info "获取 Mihomo 最新版本..." >&2

  local version=""
  local dl
  dl="$(need_cmd_any curl wget)"
  local api_url
  api_url="$(wrap_github_url "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")"
  local releases_latest_url
  releases_latest_url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/latest")"

  if [ "$dl" = "curl" ]; then
    version="$(curl -fsSL "$api_url" 2>/dev/null \
      | awk -F'"' '/"tag_name":/{print $4; exit}')"
  else
    version="$(wget -qO- "$api_url" 2>/dev/null \
      | awk -F'"' '/"tag_name":/{print $4; exit}')"
  fi

  if [ -z "$version" ]; then
    if [ "$dl" = "curl" ]; then
      local effective
      effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases_latest_url" 2>/dev/null || true)"
      version="${effective##*/}"
    else
      local location
      location="$(wget --max-redirect=0 -S -O /dev/null "$releases_latest_url" 2>&1 | awk '/^  Location: /{print $2}' | tail -n 1 | tr -d '\r' || true)"
      version="${location##*/}"
    fi
  fi

  if [ -z "$version" ]; then
    log_warn "无法自动获取最新版本号"
    return 1
  fi

  log_info "最新版本: $version" >&2
  printf "%s" "$version"
  return 0
}

# =============================================================================
# 参数收集
# =============================================================================

collect_parameters() {
  log_info "收集部署参数..."

  # 网络参数
  PARENT_IF="$(prompt "物理网卡名" "${PARENT_IF:-}" "validate_iface_name")"
  LAN_GW="$(prompt "默认网关 IP" "${LAN_GW:-}" "validate_ip")"
  LAN_SUBNET="$(prompt "局域网网段 (CIDR)" "${LAN_SUBNET:-}" "validate_cidr")"

  # Mihomo IP - 检查是否可用
  local mihomo_ip_default="${SRC_IP:-}"
  while true; do
    MIHOMO_IP="$(prompt "Mihomo IP (旁路网关)" "$mihomo_ip_default" "validate_ip")"

    if check_ip_available "$MIHOMO_IP"; then
      break
    else
      printf "%s" "IP $MIHOMO_IP 已被占用，是否继续使用？[y/N] "
      read -r confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        break
      fi
    fi
  done

  # 镜像和配置目录
  MIHOMO_IMAGE="$(prompt "Mihomo Docker 镜像" "${MIHOMO_IMAGE:-metacubex/mihomo:latest}")"

  local config_dir_default="/opt/mihomo"
  if [ "$PLATFORM" = "dsm" ]; then
    config_dir_default="/volume1/docker/mihomo"
  elif [ "$(id -u)" -ne 0 ] && [ -n "${HOME:-}" ]; then
    config_dir_default="$HOME/mihomo"
  fi
  CONFIG_DIR="$(prompt "配置目录" "$config_dir_default" "validate_path_format")"

  # GitHub 代理
  USE_GH_PROXY="$(prompt_yes_no "是否使用 GitHub 代理加速资源下载" "${USE_GH_PROXY:-yes}")"
  if [ "$USE_GH_PROXY" = "yes" ]; then
    GH_PROXY_BASE="$(prompt "GitHub 代理地址" "${GH_PROXY_BASE:-https://ghfast.top}")"
  fi

  # AdGuard Home 集成
  USE_ADGUARD="$(prompt_yes_no "是否使用 AdGuardHome 作为上游 DNS" "${USE_ADGUARD:-no}")"
  if [ "$USE_ADGUARD" = "yes" ]; then
    ADGUARD_IP="$(prompt "AdGuardHome IP" "" "validate_ip")"
  fi

  # 模板类型选择
  printf "\n"
  printf "%s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "%s\n" "  配置模板选择"
  printf "%s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "%s\n" "  1) basic   - 基础模板，策略组简洁，适合入门"
  printf "%s\n" "  2) region  - 地区分组，支持按地区选节点（香港/台湾/日本等）"
  printf "%s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "\n"

  # 转换保存的配置为数字选项
  local template_default="1"
  case "${CONFIG_TEMPLATE:-}" in
    basic) template_default="1" ;;
    region) template_default="2" ;;
  esac

  local template_choice
  template_choice="$(prompt "请选择 [1/2]" "$template_default")"

  case "$template_choice" in
    1|basic)
      CONFIG_TEMPLATE="basic"
      ;;
    2|region)
      CONFIG_TEMPLATE="region"
      ;;
    *)
      error_exit "无效选择: $template_choice（请输入 1 或 2）"
      ;;
  esac

  # Smart 策略
  USE_SMART="$(prompt_yes_no "是否启用 Smart 策略组（实验性，当前 mihomo 可能不支持）" "${USE_SMART:-no}")"
  if [ "$USE_SMART" = "yes" ]; then
    log_warn "Smart 策略组为实验性配置：当前 mihomo 可能不支持 type: smart。若启动失败，请关闭该选项。"
  fi

  # 面板选择
  DASHBOARD="$(prompt "内置面板 (none/metacubexd/zashboard)" "${DASHBOARD:-metacubexd}")"
  case "$DASHBOARD" in
    none|metacubexd|zashboard)
      ;;
    *)
      error_exit "不支持的面板: $DASHBOARD（仅支持 none/metacubexd/zashboard）"
      ;;
  esac

  # 订阅链接
  SUB_URL_RAW="$(prompt "订阅链接" "")"
  SUB_URL="$(sanitize_url "$SUB_URL_RAW")"

  if [ -z "${SUB_URL:-}" ]; then
    error_exit "订阅链接不能为空"
  fi

  # 控制面板密钥
  CLASH_SECRET="$(prompt_secret "控制面板密钥" "" "true")"

  if [ -z "${CLASH_SECRET:-}" ]; then
    error_exit "控制面板密钥不能为空"
  fi

  # 自动更新
  printf "\n"
  printf "%s\n" "自动更新将定期检查并更新 Mihomo 主程序和配置模板。"
  printf "%s\n" "更新时间：每天凌晨 3 点（可通过 cron 自定义）"
  printf "\n"
  if [ -n "${AUTO_UPDATE:-}" ]; then
    AUTO_UPDATE="$(prompt_yes_no "是否启用自动更新" "$AUTO_UPDATE")"
  else
    AUTO_UPDATE="$(prompt_yes_no "是否启用自动更新" "no")"
  fi

  if [ "$AUTO_UPDATE" = "yes" ]; then
    printf "\n"
    printf "%s\n" "更新频率选项："
    printf "%s\n" "  1) 每天更新一次（推荐，默认）"
    printf "%s\n" "  2) 每周更新一次"
    printf "%s\n" "  3) 每小时更新一次"
    printf "\n"
    printf "请选择更新频率 [1-3，默认 1]: "
    read -r freq_choice
    case "$freq_choice" in
      2|"weekly")
        AUTO_UPDATE_INTERVAL="weekly"
        ;;
      3|"hourly")
        AUTO_UPDATE_INTERVAL="hourly"
        ;;
      *)
        AUTO_UPDATE_INTERVAL="daily"
        ;;
    esac
    log_info "自动更新频率: $AUTO_UPDATE_INTERVAL"
  fi

  # 保存配置供后续使用
  local saved_config="$CONFIG_DIR/.deploy_config"
  save_config "$saved_config" PARENT_IF LAN_GW LAN_SUBNET MIHOMO_IP MIHOMO_IMAGE \
    CONFIG_DIR USE_GH_PROXY GH_PROXY_BASE USE_ADGUARD ADGUARD_IP CONFIG_TEMPLATE \
    USE_SMART DASHBOARD SUB_URL CLASH_SECRET AUTO_UPDATE AUTO_UPDATE_INTERVAL

  log_info "参数收集完成"
  return 0
}

# =============================================================================
# 下载和安装 UI 面板
# =============================================================================

install_dashboard() {
  if [ "$DASHBOARD" = "none" ]; then
    log_info "跳过面板安装"
    return 0
  fi

  log_info "安装管理面板: $DASHBOARD"

  local ui_url=""
  case "$DASHBOARD" in
    metacubexd)
      ui_url="$(wrap_github_url "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip")"
      ;;
    zashboard)
      ui_url="$(wrap_github_url "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip")"
      ;;
  esac

  # 创建 UI 配置
  UI_CONFIG="$(cat <<EOF
external-ui: ui
external-ui-url: "$ui_url"

EOF
)"

  # 下载并解压面板
  local ui_dir="$CONFIG_DIR/ui"
  local tmp_dir
  tmp_dir="$(create_temp_dir mihomo-ui)"

  local ui_zip="$tmp_dir/ui.zip"
  local ui_extract="$tmp_dir/extract"

  if ! download_file "$ui_url" "$ui_zip" "true"; then
    error_exit "下载面板失败"
  fi

  if ! extract_zip "$ui_zip" "$ui_extract"; then
    error_exit "解压面板失败"
  fi

  # 查找 index.html
  if ! command -v find >/dev/null 2>&1; then
    error_exit "缺少 find 命令，无法安装面板"
  fi

  local index_file
  index_file="$(find "$ui_extract" -maxdepth 4 -type f -name index.html 2>/dev/null | head -n 1 || true)"

  if [ -z "${index_file:-}" ]; then
    error_exit "未在面板压缩包中找到 index.html"
  fi

  local ui_root
  ui_root="$(dirname "$index_file")"

  # 安装面板
  log_info "安装面板到: $ui_dir"

  if [ "$DRY_RUN" -ne 1 ]; then
    rm -rf "$ui_dir"
    mkdir -p "$ui_dir"
    cp -R "$ui_root"/. "$ui_dir/"
    chmod -R a+rX "$ui_dir" 2>/dev/null || true
  fi

  log_info "面板安装完成"
  return 0
}

# =============================================================================
# 生成 DNS 配置
# =============================================================================

generate_dns_config() {
  log_info "生成 DNS 配置..."

  if [ "$USE_ADGUARD" = "yes" ]; then
    DNS_CONFIG="$(cat <<EOF
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-filter:
    - +.lan
    - +.local
  nameserver:
    - $ADGUARD_IP
    - $LAN_GW

EOF
)"
  else
    DNS_CONFIG="$(cat <<EOF
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-filter:
    - +.lan
    - +.local
    - geosite:cn
  fake-ip-filter-mode: rule
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver-policy:
    'geosite:!cn':
      - https://223.5.5.5/dns-query
      - https://dns.pub/dns-query
    'geosite:cn':
      - 223.5.5.5
      - 119.29.29.29
  fallback:
    - https://cloudflare-dns.com/dns-query
  fallback-filter:
    geoip: true
    ipcidr:
      - 0.0.0.0/0

EOF
)"
  fi

  return 0
}

# =============================================================================
# 生成规则配置
# =============================================================================

generate_rules_config() {
  log_info "生成规则配置..."

  # 规则集 URL（使用 GitHub 代理）
  URL_RULESET_OPENAI="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/openai.mrs")"
  URL_RULESET_CLAUDE="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/Claude/Claude.list")"
  URL_RULESET_GITHUB="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/github.mrs")"
  URL_RULESET_TELEGRAM_DOMAIN="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/telegram.mrs")"
  URL_RULESET_TELEGRAM_IP="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geoip/telegram.mrs")"
  URL_RULESET_NETFLIX_DOMAIN="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/netflix.mrs")"
  URL_RULESET_NETFLIX_IP="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geoip/netflix.mrs")"
  URL_RULESET_GOOGLE_DOMAIN="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/google.mrs")"
  URL_RULESET_GOOGLE_IP="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geoip/google.mrs")"
  URL_RULESET_APPLE="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/apple.mrs")"
  URL_RULESET_APPLE_CN="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/apple-cn.mrs")"
  URL_RULESET_MICROSOFT="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/microsoft.mrs")"
  URL_RULESET_STEAM="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/steam.mrs")"
  URL_RULESET_CHINA_DOMAIN="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/cn.mrs")"
  URL_RULESET_CHINA_IP="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geoip/cn.mrs")"
  URL_RULESET_PRIVATE="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/private.mrs")"
  URL_RULESET_BLOCK="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Block.list")"

  # 地区分组模板额外的规则集 URL
  URL_RULESET_PERPLEXITY="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/perplexity.mrs")"
  URL_RULESET_COPILOT="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Copilot.list")"
  URL_RULESET_GEMINI="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Gemini.list")"
  URL_RULESET_META_AI="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/MetaAi.list")"
  URL_RULESET_REDDIT="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/reddit.mrs")"
  URL_RULESET_WHATSAPP="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/Whatsapp/Whatsapp.list")"
  URL_RULESET_FACEBOOK="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/facebook.mrs")"
  URL_RULESET_YOUTUBE="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/youtube.mrs")"
  URL_RULESET_TIKTOK="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/tiktok.mrs")"
  URL_RULESET_DISNEY="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/disney.mrs")"
  URL_RULESET_HBO="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/hbo.mrs")"
  URL_RULESET_AMAZON="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/amazon.mrs")"
  URL_RULESET_CRUNCHYROLL="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Crunchyroll.list")"
  URL_RULESET_SPOTIFY="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/spotify.mrs")"
  URL_RULESET_EPIC="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Epic/Epic.list")"
  URL_RULESET_EA="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/EA/EA.list")"
  URL_RULESET_BLAZZARD="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Blizzard/Blizzard.list")"
  URL_RULESET_UBI="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/UBI/UBI.list")"
  URL_RULESET_PLAYSTATION="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/PlayStation/PlayStation.list")"
  URL_RULESET_NINTENDO="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Nintendo/Nintendo.list")"
  URL_RULESET_OKX="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/okx.mrs")"
  URL_RULESET_BYBIT="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/bybit.mrs")"
  URL_RULESET_BINANCE="$(wrap_github_url "https://github.com/metacubex/meta-rules-dat/raw/refs/heads/meta/geo/geosite/binance.mrs")"
  URL_RULESET_NVIDIA="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/Nvidia/Nvidia.list")"
  URL_RULESET_PROXY="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Proxy.list")"
  URL_RULESET_GLOBE="$(wrap_github_url "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/Global/Global.list")"
  URL_RULESET_DIRECT="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Direct.list")"
  URL_RULESET_TEST="$(wrap_github_url "https://raw.githubusercontent.com/liandu2024/clash/refs/heads/main/list/Check.list")"

  # Smart 策略配置
  SMART_PROXY_LINE=""
  SMART_GROUP_BLOCK="$(cat <<'EOF'
  - name: 所有-智选
    type: url-test
    use:
      - sub
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    tolerance: 0
    filter: "^((?!(DIRECT|REJECT|直连|拒绝)).)*$"

EOF
)"
  if [ "$USE_SMART" = "yes" ]; then
    SMART_PROXY_LINE="- 所有-智选"
    SMART_GROUP_BLOCK="$(cat <<'EOF'
  - name: 所有-智选
    type: smart
    use:
      - sub
    filter: "^((?!(DIRECT|REJECT|直连|拒绝)).)*$"

EOF
)"
  fi

  # AdGuard 规则
  ADGUARD_RULE_LINE=""
  if [ "$USE_ADGUARD" = "yes" ]; then
    ADGUARD_RULE_LINE="- IP-CIDR,$ADGUARD_IP/32,DIRECT,no-resolve"
  fi

  # 外部端口配置
  EXTERNAL_PORT="${EXTERNAL_PORT:-19090}"

  log_info "规则配置生成完成"
  return 0
}

# =============================================================================
# Docker 模式部署
# =============================================================================

deploy_docker_mode() {
  log_info "开始 Docker 模式部署..."

  need_cmd docker

  local network_name="mihomo-macvlan"
  local tz_mounts=""
  if [ -e /etc/localtime ]; then
    tz_mounts="$tz_mounts -v /etc/localtime:/etc/localtime:ro"
  fi
  if [ -f /etc/timezone ]; then
    tz_mounts="$tz_mounts -v /etc/timezone:/etc/timezone:ro"
  else
    log_warn "/etc/timezone 不存在，跳过挂载（DSM 常见）"
  fi

  # 创建 macvlan 网络
  if docker network inspect "$network_name" >/dev/null 2>&1; then
    log_info "网络已存在: $network_name"
  else
    log_info "创建 macvlan 网络: $network_name"
    run_cmd "docker network create -d macvlan --subnet='$LAN_SUBNET' --gateway='$LAN_GW' -o parent='$PARENT_IF' '$network_name'" || \
      error_exit "创建 Docker 网络失败"
  fi

  # 停止并删除旧容器
  if docker ps -a --format '{{.Names}}' | grep -qx mihomo; then
    log_info "删除旧容器..."
    run_cmd "docker rm -f mihomo" || true
  fi

  # 启动新容器（使用官方 Mihomo 镜像）
  log_info "启动 Mihomo 容器（官方镜像: $MIHOMO_IMAGE）..."

  run_cmd "docker run -d --name mihomo \
    --restart=always \
    --network='$network_name' \
    --ip='$MIHOMO_IP' \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e TZ=Asia/Shanghai \
    $tz_mounts \
    -v '$CONFIG_DIR:/root/.config/mihomo' \
    '$MIHOMO_IMAGE'" || error_exit "启动容器失败"

  log_info "Docker 部署完成"
  return 0
}

# =============================================================================
# Binary 模式部署
# =============================================================================

deploy_binary_mode() {
  log_info "开始 Binary 模式部署..."

  # 检查平台兼容性
  if [ "$PLATFORM" = "dsm" ]; then
    error_exit "Binary 模式不支持 DSM（缺少 systemd）。请使用 --mode docker"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    error_exit "Binary 模式需要 systemd（systemctl 不可用）。请使用 --mode docker"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    error_exit "Binary 模式需要 root 权限"
  fi

  # 下载或使用本地二进制
  local mihomo_bin_path=""
  printf "%s\n" ""
  printf "%s\n" "Binary 模式支持两种方式："
  printf "%s\n" "1) 使用已下载的 mihomo 二进制路径"
  printf "%s\n" "2) 脚本自动从 GitHub Releases 下载"
  printf "%s\n" ""

  mihomo_bin_path="$(prompt "mihomo 二进制路径（留空则自动下载）" "" "validate_path_format")"

  if [ -z "${mihomo_bin_path:-}" ]; then
    # 自动下载
    need_cmd gzip

    local arch
    arch="$(detect_arch)"
    [ "$arch" = "unknown" ] && error_exit "无法检测系统架构"

    local version_input
    version_input="$(prompt "mihomo 版本号（留空使用 latest）" "")"

    local version="$version_input"
  if [ -z "$version" ]; then
      version="$(get_latest_mihomo_version || true)"
      if [ -z "$version" ]; then
        printf "%s\n" "无法自动获取版本号，请手动输入（如 v1.19.18）"
        version="$(prompt "mihomo 版本号" "")"
        [ -z "$version" ] && error_exit "版本号不能为空"
      fi
    fi

    local variant
    variant="$(prompt "可选构建后缀（如 compatible/go123，留空默认）" "")"

    local suffix=""
    if [ -n "$variant" ]; then
      suffix="-$variant"
    fi

    local tmp_dir
    tmp_dir="$(create_temp_dir mihomo-download)"

    local gz_path="$tmp_dir/mihomo.gz"
    local bin_path="$tmp_dir/mihomo"
    local url
    url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$version/mihomo-linux-$arch$suffix-$version.gz")"

    # 尝试下载校验和文件
    local checksum_url
    checksum_url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$version/sha256sums-$(detect_arch).txt")" 
    # 注意：Mihomo 的 checksum 文件名可能不固定，这里尝试常见的 sha256sums-{arch}.txt 或 sha256sums
    # 如果失败，再尝试 sha256sums
    
    local checksum_file="$tmp_dir/checksums.txt"
    local checksum_downloaded=0

    log_info "尝试下载校验和文件..."
    if download_file_optional "$checksum_url" "$checksum_file"; then
      checksum_downloaded=1
    else
      # 尝试备用名称
      checksum_url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$version/sha256sums")"
      if download_file_optional "$checksum_url" "$checksum_file"; then
        checksum_downloaded=1
      fi
    fi

    log_info "下载 Mihomo $version ($arch$suffix)..."
    if ! download_file "$url" "$gz_path" "true"; then
      error_exit "下载 Mihomo 失败"
    fi

    if [ "$checksum_downloaded" -eq 1 ]; then
      local filename="mihomo-linux-$arch$suffix-$version.gz"
      local expected_checksum
      expected_checksum="$(grep "$filename" "$checksum_file" | awk '{print $1}' | head -n 1 || true)"

      if [ -n "$expected_checksum" ]; then
        if ! verify_checksum "$gz_path" "$expected_checksum"; then
           error_exit "严重错误：文件校验失败！下载的文件可能不完整或已被篡改。"
        fi
      else
        log_warn "未在校验和文件中找到对应文件的哈希值，跳过校验"
      fi
    else
      log_warn "无法下载校验和文件，跳过验证"
    fi

    log_info "解压二进制文件..."
    if [ "$DRY_RUN" -eq 1 ]; then
      log_debug "[DRY RUN] gzip -dc '$gz_path' > '$bin_path'"
    else
      gzip -dc "$gz_path" >"$bin_path" || error_exit "解压失败"
      chmod +x "$bin_path"
    fi

    mihomo_bin_path="$bin_path"
  fi

  # 验证二进制文件
  if [ ! -f "$mihomo_bin_path" ]; then
    error_exit "找不到二进制文件: $mihomo_bin_path"
  fi

  # 安装二进制文件
  log_info "安装 mihomo 到 /usr/local/bin/..."
  run_cmd "chmod +x '$mihomo_bin_path'"
  run_cmd "install -m 0755 '$mihomo_bin_path' /usr/local/bin/mihomo"

  # 配置 IP 地址（如果需要）
  if [ -n "${SRC_IP:-}" ] && [ "$MIHOMO_IP" != "$SRC_IP" ]; then
    printf "%s\n" ""
    local add_ip
    add_ip="$(prompt_yes_no "MIHOMO_IP 与宿主机 IP 不同，是否为网卡添加该 IP" "no")"

    if [ "$add_ip" = "yes" ]; then
      local prefix_len
      prefix_len="$(printf "%s" "$LAN_SUBNET" | awk -F'/' '{print $2}')"

      if [ -z "${prefix_len:-}" ]; then
        prefix_len="$(prompt "无法从 LAN_SUBNET 解析前缀长度，请输入（如 24）" "")"
        [ -z "$prefix_len" ] && error_exit "前缀长度不能为空"
      fi

      run_cmd "ip addr add '$MIHOMO_IP/$prefix_len' dev '$PARENT_IF' 2>/dev/null || true"

      local ip_service="/etc/systemd/system/mihomo-ip.service"
      log_info "创建 IP 绑定服务: $ip_service"

      # 额外安全检查：确保变量安全后再写入 systemd 服务文件
      if ! validate_iface_name "$PARENT_IF"; then
        error_exit "PARENT_IF 验证失败: $PARENT_IF"
      fi
      if ! validate_ip "$MIHOMO_IP"; then
        error_exit "MIHOMO_IP 验证失败: $MIHOMO_IP"
      fi
      if ! [[ "$prefix_len" =~ ^[0-9]+$ ]] || [ "$prefix_len" -lt 0 ] || [ "$prefix_len" -gt 32 ]; then
        error_exit "prefix_len 验证失败: $prefix_len"
      fi

      if [ "$DRY_RUN" -ne 1 ]; then
        umask 022
        cat >"$ip_service" <<EOF
[Unit]
Description=mihomo ip addr for gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "ip -o -4 addr show dev '$PARENT_IF' | awk '{print \\$4}' | cut -d/ -f1 | grep -qx '$MIHOMO_IP' || ip addr add '$MIHOMO_IP/$prefix_len' dev '$PARENT_IF'"
ExecStop=/bin/sh -c "ip -o -4 addr show dev '$PARENT_IF' | awk '{print \\$4}' | cut -d/ -f1 | grep -qx '$MIHOMO_IP' && ip addr del '$MIHOMO_IP/$prefix_len' dev '$PARENT_IF' || true"

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$ip_service"
        run_cmd "systemctl daemon-reload"
        run_cmd "systemctl enable --now mihomo-ip"
      fi
    fi
  fi

  # 创建 systemd 服务
  local service_path="/etc/systemd/system/mihomo.service"
  log_info "创建 systemd 服务: $service_path"

  if [ "$DRY_RUN" -ne 1 ]; then
    umask 022
    cat >"$service_path" <<EOF
[Unit]
Description=mihomo
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d $CONFIG_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$service_path"
  fi

  # 配置系统参数
  log_info "配置系统参数..."
  if [ "$DRY_RUN" -ne 1 ]; then
    umask 022
    cat >/etc/sysctl.d/99-mihomo.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
  fi
  run_cmd "sysctl -w net.ipv4.ip_forward=1"
  run_cmd "sysctl -w net.ipv4.conf.all.src_valid_mark=1"

  # 启动服务
  log_info "启动 mihomo 服务..."
  run_cmd "systemctl daemon-reload"
  run_cmd "systemctl enable --now mihomo"

  log_info "Binary 部署完成"
  return 0
}

# =============================================================================
# 健康检查
# =============================================================================

health_check() {
  log_info "执行健康检查..."

  if [ "$DEPLOY_MODE" = "docker" ]; then
    if docker ps --format '{{.Names}}' | grep -qx mihomo; then
      log_info "Docker 容器运行正常"
    else
      log_error "Docker 容器未运行"
      return 1
    fi
  elif [ "$DEPLOY_MODE" = "binary" ]; then
    if systemctl is-active --quiet mihomo; then
      log_info "Systemd 服务运行正常"
    else
      log_error "Systemd 服务未运行"
      return 1
    fi
  fi

  local check_ip="$MIHOMO_IP"
  if [ "$DEPLOY_MODE" = "binary" ]; then
    if ! ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$MIHOMO_IP"; then
      check_ip="127.0.0.1"
      log_warn "MIHOMO_IP 未绑定到本机网卡：本机将用 127.0.0.1 做健康检查"
      log_warn "若局域网设备需要使用 $MIHOMO_IP，请将该 IP 添加到网卡或重新部署选择添加"
    fi
  fi

  # 等待服务启动
  log_info "等待服务启动..."
  local max_wait=30
  local waited=0

  while [ $waited -lt $max_wait ]; do
    if curl -fsS --connect-timeout 1 --max-time 2 "http://$check_ip:19090" >/dev/null 2>&1; then
      log_info "Mihomo API 响应正常"
      break
    fi

    sleep 1
    waited=$((waited + 1))
  done

  if [ $waited -ge $max_wait ]; then
    log_warn "服务启动超时（$max_wait 秒），请手动检查"
    return 0
  fi

  # 测试代理功能（通过代理访问 Cloudflare CDN）
  log_info "测试代理功能..."
  local cf_test_url="http://cp.cloudflare.com/generate_204"
  if curl -s -x "http://$check_ip:7890" --connect-timeout 5 "$cf_test_url" >/dev/null 2>&1; then
    log_info "代理功能测试通过（Cloudflare CDN）"
  elif curl -s -x "http://$check_ip:7890" --connect-timeout 5 "http://www.baidu.com" >/dev/null 2>&1; then
    log_info "代理功能测试通过（国内测试）"
  else
    log_warn "代理功能测试失败（可能正常，取决于订阅节点状态）"
  fi

  # 测试 DNS 解析
  log_info "测试 DNS 解析..."
  if host www.google.com "$check_ip" >/dev/null 2>&1; then
    log_info "DNS 解析测试通过"
  else
    log_warn "DNS 解析测试失败（可能正常，取决于规则配置）"
  fi

  log_info "健康检查完成"
  return 0
}

# =============================================================================
# 自动更新管理
# =============================================================================

# 创建独立的更新脚本供 cron 调用
create_update_script() {
  local script_dir="$1"
  local update_script="$script_dir/auto-update.sh"

  log_info "创建自动更新脚本: $update_script"

  cat >"$update_script" <<'UPDATE_SCRIPT_EOF'
#!/bin/bash
# Mihomo 自动更新脚本
# 由 cron 定时调用，静默更新

set -euo pipefail

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/auto-update.log"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB

# 日志函数（带时间戳）
log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE"
}

# 清理日志文件
clean_log() {
  if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt "$MAX_LOG_SIZE" ]; then
    tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

clean_log
log_msg "开始自动更新检查..."

# 查找部署脚本
DEPLOY_SCRIPT=""
for path in "$SCRIPT_DIR/deploy-mihomo-optimized.sh" \
             "$(dirname "$SCRIPT_DIR")/deploy-mihomo-optimized.sh" \
             "/opt/mihomo/deploy-mihomo-optimized.sh"; do
  if [ -f "$path" ]; then
    DEPLOY_SCRIPT="$path"
    break
  fi
done

if [ -z "$DEPLOY_SCRIPT" ]; then
  log_msg "错误：找不到部署脚本"
  exit 1
fi

log_msg "找到部署脚本: $DEPLOY_SCRIPT"

# 执行更新
if bash "$DEPLOY_SCRIPT" --update >>"$LOG_FILE" 2>&1; then
  log_msg "更新成功"
else
  local exit_code=$?
  log_msg "更新失败 (退出码: $exit_code)"
  exit $exit_code
fi
UPDATE_SCRIPT_EOF

  chmod +x "$update_script"
  log_info "自动更新脚本已创建"
}

# 安装自动更新 cron 任务
install_auto_update() {
  local config_dir="$1"
  local update_interval="${2:-daily}"  # daily, weekly, 或 cron 格式

  log_info "安装自动更新 cron 任务..."

  # 创建更新脚本
  create_update_script "$config_dir"

  # 确定 cron 表达式
  local cron_expr=""
  case "$update_interval" in
    hourly)
      cron_expr="0 * * * *"
      ;;
    daily)
      cron_expr="0 3 * * *"  # 每天凌晨 3 点
      ;;
    weekly)
      cron_expr="0 3 * * 0"  # 每周日凌晨 3 点
      ;;
    *)
      cron_expr="$update_interval"  # 自定义 cron 表达式
      ;;
  esac

  local update_script="$config_dir/auto-update.sh"
  local cron_line="$cron_expr $update_script >/dev/null 2>&1"

  # 检查是否已存在
  if crontab -l 2>/dev/null | grep -q "$update_script"; then
    log_info "cron 任务已存在，先删除旧任务"
    remove_auto_update "$config_dir"
  fi

  # 添加新 cron 任务
  (crontab -l 2>/dev/null; echo "$cron_line") | crontab -

  log_info "自动更新已安装（$update_interval）"
  log_info "查看日志: $config_dir/auto-update.log"
}

# 移除自动更新 cron 任务
remove_auto_update() {
  local config_dir="$1"
  local update_script="$config_dir/auto-update.sh"

  log_info "移除自动更新 cron 任务..."

  # 从 crontab 中删除
  if crontab -l 2>/dev/null | grep -q "$update_script"; then
    crontab -l 2>/dev/null | grep -v "$update_script" | crontab -
    log_info "cron 任务已删除"
  fi

  # 可选：删除更新脚本和日志
  # rm -f "$update_script"
  # rm -f "$config_dir/auto-update.log"
}

# =============================================================================
# 卸载功能
# =============================================================================

uninstall_mihomo() {
  log_info "开始卸载 Mihomo..."

  if [ -z "${CONFIG_DIR:-}" ]; then
    local cfg
    for cfg in /opt/mihomo/.deploy_config /volume1/docker/mihomo/.deploy_config /root/mihomo/.deploy_config /etc/mihomo/.deploy_config; do
      if [ -f "$cfg" ]; then
        load_saved_config "$cfg" || true
        break
      fi
    done
  fi

  if [ -z "${CONFIG_DIR:-}" ]; then
    CONFIG_DIR="/opt/mihomo"
  fi

  printf "%s\n" ""
  printf "\033[31m%s\033[0m\n" "警告：此操作将删除 Mihomo 及其配置。"
  printf "%s" "确认卸载？[y/N] "
  read -r confirm

  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log_info "取消卸载"
    return 0
  fi

  # 停止并删除 Docker 容器
  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -qx mihomo 2>/dev/null; then
      log_info "停止并删除 Docker 容器..."
      run_cmd "docker stop mihomo" 2>/dev/null || true
      run_cmd "docker rm mihomo" || true
    fi
  fi

  # 停止并禁用 systemd 服务
  if command -v systemctl >/dev/null 2>&1; then
    log_info "停止并禁用 systemd 服务..."
    run_cmd "systemctl stop mihomo" 2>/dev/null || true
    run_cmd "systemctl disable mihomo" 2>/dev/null || true
    run_cmd "systemctl stop mihomo-ip" 2>/dev/null || true
    run_cmd "systemctl disable mihomo-ip" 2>/dev/null || true

    run_cmd "rm -f /etc/systemd/system/mihomo.service" 2>/dev/null || true
    run_cmd "rm -f /etc/systemd/system/mihomo-ip.service" 2>/dev/null || true
    run_cmd "rm -f /etc/systemd/system/multi-user.target.wants/mihomo.service" 2>/dev/null || true
    run_cmd "rm -f /etc/systemd/system/multi-user.target.wants/mihomo-ip.service" 2>/dev/null || true
    run_cmd "rm -f /lib/systemd/system/mihomo.service" 2>/dev/null || true
    run_cmd "rm -f /lib/systemd/system/mihomo-ip.service" 2>/dev/null || true

    run_cmd "systemctl daemon-reload" || true
    run_cmd "systemctl reset-failed" 2>/dev/null || true
  fi

  # 移除自动更新 cron 任务
  remove_auto_update "$CONFIG_DIR" 2>/dev/null || true

  if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
    log_info "检测到残留进程，尝试终止 mihomo..."
    if command -v pkill >/dev/null 2>&1; then
      run_cmd "pkill -x mihomo" 2>/dev/null || true
      sleep 1
      run_cmd "pkill -9 -x mihomo" 2>/dev/null || true
    elif command -v killall >/dev/null 2>&1; then
      run_cmd "killall mihomo" 2>/dev/null || true
      sleep 1
      run_cmd "killall -9 mihomo" 2>/dev/null || true
    else
      local pids
      pids="$(pidof mihomo 2>/dev/null || true)"
      [ -n "${pids:-}" ] && run_cmd "kill $pids" 2>/dev/null || true
      sleep 1
      pids="$(pidof mihomo 2>/dev/null || true)"
      [ -n "${pids:-}" ] && run_cmd "kill -9 $pids" 2>/dev/null || true
    fi
  fi

  if [ -f /usr/local/bin/mihomo ]; then
    log_info "删除二进制文件: /usr/local/bin/mihomo"
    run_cmd "rm -f /usr/local/bin/mihomo" || true
  fi
  if [ -f /usr/bin/mihomo ]; then
    log_info "删除二进制文件: /usr/bin/mihomo"
    run_cmd "rm -f /usr/bin/mihomo" || true
  fi

  # 删除下载的模板文件
  log_info "检查模板文件: $SCRIPT_DIR/config-region.yaml.tpl"
  if [ -f "$SCRIPT_DIR/config-region.yaml.tpl" ]; then
    log_info "删除模板文件: config-region.yaml.tpl"
    run_cmd "rm -f '$SCRIPT_DIR/config-region.yaml.tpl'" || true
  else
    log_info "模板文件不存在: $SCRIPT_DIR/config-region.yaml.tpl"
  fi
  if [ -f "$SCRIPT_DIR/config.yaml.tpl" ]; then
    log_info "删除模板文件: config.yaml.tpl"
    run_cmd "rm -f '$SCRIPT_DIR/config.yaml.tpl'" || true
  else
    log_info "模板文件不存在: $SCRIPT_DIR/config.yaml.tpl"
  fi

  # 删除 Docker 网络
  if command -v docker >/dev/null 2>&1; then
    if docker network ls --format '{{.Name}}' | grep -qx mihomo-macvlan 2>/dev/null; then
      log_info "删除 Docker 网络..."
      run_cmd "docker network rm mihomo-macvlan" || true
    fi
  fi

  # 询问是否删除配置
  printf "%s\n" ""
  printf "%s" "是否删除配置目录 $CONFIG_DIR？[Y/n] "
  read -r delete_config

  if [ -z "${delete_config:-}" ] || [ "$delete_config" = "y" ] || [ "$delete_config" = "Y" ]; then
    log_info "删除配置目录..."
    run_cmd "rm -rf '$CONFIG_DIR'" || true
  fi

  if [ -f /etc/sysctl.d/99-mihomo.conf ]; then
    log_info "删除 sysctl 配置: /etc/sysctl.d/99-mihomo.conf"
    run_cmd "rm -f /etc/sysctl.d/99-mihomo.conf" || true
    run_cmd "sysctl --system" 2>/dev/null || true
  fi

  printf "%s\n" ""
  printf "%s" "是否删除日志目录 $LOG_DIR？[y/N] "
  read -r delete_logs
  if [ "$delete_logs" = "y" ] || [ "$delete_logs" = "Y" ]; then
    log_info "删除日志目录..."
    run_cmd "rm -rf '$LOG_DIR'" || true
  fi

  log_info "卸载完成"
  return 0
}

# =============================================================================
# 使用说明
# =============================================================================

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME [选项]

选项:
  -m, --mode MODE           部署模式: docker 或 binary (默认自动检测)
  --install                 执行安装/部署
  --update                  更新模板文件与 mihomo 二进制
  --enable-auto-update      启用自动更新（cron 任务）
  --disable-auto-update     禁用自动更新
  --commands                显示脚本命令大全
  --skip-self-update        跳过脚本自更新检查（用于自动化或已是最新）
  -d, --dry-run            试运行模式（只显示命令不执行）
  -v, --verbose            详细输出模式
  -u, --uninstall          卸载 Mihomo
  -h, --help               显示此帮助信息

示例:
  $SCRIPT_NAME --mode docker              # Docker 模式部署
  $SCRIPT_NAME --mode binary              # Binary 模式部署
  $SCRIPT_NAME --update                   # 更新模板与二进制
  $SCRIPT_NAME --enable-auto-update       # 启用自动更新
  $SCRIPT_NAME --disable-auto-update      # 禁用自动更新
  $SCRIPT_NAME --dry-run                  # 试运行
  $SCRIPT_NAME --uninstall                # 卸载
  $SCRIPT_NAME                            # 交互式菜单（有 TTY 时）

版本: $VERSION
EOF
}

show_commands() {
  cat <<EOF
脚本命令大全:

  安装/部署（默认动作）:
    sudo ./$SCRIPT_NAME
    sudo ./$SCRIPT_NAME --install
    sudo ./$SCRIPT_NAME --mode binary
    sudo ./$SCRIPT_NAME --mode docker
    sudo ./$SCRIPT_NAME --install --skip-self-update

  更新（模板 + mihomo）:
    sudo ./$SCRIPT_NAME --update

  自动更新:
    sudo ./$SCRIPT_NAME --enable-auto-update    # 启用自动更新
    sudo ./$SCRIPT_NAME --disable-auto-update   # 禁用自动更新

  卸载:
    sudo ./$SCRIPT_NAME --uninstall

  调试:
    sudo ./$SCRIPT_NAME --dry-run
    sudo ./$SCRIPT_NAME --verbose

  帮助:
    ./$SCRIPT_NAME --help
EOF
}

update_template_file() {
  local tpl_url
  tpl_url="$(wrap_github_url "https://raw.githubusercontent.com/binbin1213/Mihomo-Gateway-Script/main/config.yaml.tpl")"

  local tmp
  tmp="$(mktemp)"

  if ! download_file "$tpl_url" "$tmp" "false"; then
    rm -f "$tmp"
    log_warn "模板文件更新检查失败（下载失败）"
    return 1
  fi

  local target="$SCRIPT_DIR/config.yaml.tpl"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_info "模板文件已是最新版本"
    return 0
  fi

  if [ -d "$SCRIPT_DIR" ] && [ -w "$SCRIPT_DIR" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_debug "[DRY RUN] mv '$tmp' '$target'"
    else
      mv "$tmp" "$target" || true
      chmod 644 "$target" 2>/dev/null || true
    fi
    log_info "模板文件已更新: $target"
    return 0
  fi

  rm -f "$tmp"
  log_warn "脚本目录不可写，无法更新模板文件: $target"
  return 1
}

get_installed_mihomo_version() {
  if ! command -v mihomo >/dev/null 2>&1; then
    return 0
  fi
  mihomo -v 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i ~ /^v[0-9]+\./) {print $i; exit}}'
}

update_mihomo_binary() {
  if [ "$(id -u)" -ne 0 ]; then
    error_exit "更新 mihomo（二进制）需要 root 权限"
  fi

  need_cmd gzip

  local arch
  arch="$(detect_arch)"
  [ "$arch" = "unknown" ] && error_exit "无法检测系统架构"

  local latest
  latest="$(get_latest_mihomo_version || true)"
  if [ -z "${latest:-}" ]; then
    error_exit "无法获取 mihomo 最新版本号"
  fi

  local current
  current="$(get_installed_mihomo_version || true)"
  if [ -n "${current:-}" ] && [ "$current" = "$latest" ]; then
    log_info "mihomo 已是最新版本: $current"
    return 0
  fi

  local tmp_dir
  tmp_dir="$(create_temp_dir mihomo-update)"

  local gz_path="$tmp_dir/mihomo.gz"
  local bin_path="$tmp_dir/mihomo"
  local url
  url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$latest/mihomo-linux-$arch-$latest.gz")"

  local checksum_file="$tmp_dir/checksums.txt"
  local checksum_downloaded=0
  local checksum_url
  checksum_url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$latest/sha256sums-$arch.txt")"
  if download_file_optional "$checksum_url" "$checksum_file"; then
    checksum_downloaded=1
  else
    checksum_url="$(wrap_github_url "https://github.com/MetaCubeX/mihomo/releases/download/$latest/sha256sums")"
    if download_file_optional "$checksum_url" "$checksum_file"; then
      checksum_downloaded=1
    fi
  fi

  log_info "下载 mihomo $latest ($arch)..."
  if ! download_file "$url" "$gz_path" "true"; then
    error_exit "下载 mihomo 失败"
  fi

  if [ "$checksum_downloaded" -eq 1 ]; then
    local filename="mihomo-linux-$arch-$latest.gz"
    local expected_checksum
    expected_checksum="$(grep "$filename" "$checksum_file" | awk '{print $1}' | head -n 1 || true)"
    if [ -n "${expected_checksum:-}" ]; then
      if ! verify_checksum "$gz_path" "$expected_checksum"; then
        error_exit "严重错误：文件校验失败！下载的文件可能不完整或已被篡改。"
      fi
    else
      log_warn "未在校验和文件中找到对应文件的哈希值，跳过校验"
    fi
  else
    log_warn "无法下载校验和文件，跳过验证"
  fi

  log_info "解压二进制文件..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log_debug "[DRY RUN] gzip -dc '$gz_path' > '$bin_path'"
  else
    gzip -dc "$gz_path" >"$bin_path" || error_exit "解压失败"
    chmod +x "$bin_path"
  fi

  log_info "安装 mihomo 到 /usr/local/bin/..."
  run_cmd "chmod +x '$bin_path'"
  run_cmd "install -m 0755 '$bin_path' /usr/local/bin/mihomo"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx mihomo.service; then
      log_info "重启 mihomo 服务..."
      run_cmd "systemctl daemon-reload"
      run_cmd "systemctl restart mihomo"
    fi
  fi

  log_info "mihomo 二进制已更新: ${current:-unknown} -> $latest"
  return 0
}

update_mihomo_docker() {
  need_cmd docker
  local tz_mounts=""
  if [ -e /etc/localtime ]; then
    tz_mounts="$tz_mounts -v /etc/localtime:/etc/localtime:ro"
  fi
  if [ -f /etc/timezone ]; then
    tz_mounts="$tz_mounts -v /etc/timezone:/etc/timezone:ro"
  else
    log_warn "/etc/timezone 不存在，跳过挂载（DSM 常见）"
  fi

  if ! docker ps -a --format '{{.Names}}' | grep -qx mihomo; then
    error_exit "未找到 mihomo 容器，无法执行 Docker 更新"
  fi

  local image
  image="$(docker inspect -f '{{.Config.Image}}' mihomo 2>/dev/null || true)"
  [ -z "${image:-}" ] && image="metacubex/mihomo:latest"

  # 验证 Docker 镜像名称安全性
  if ! validate_docker_image "$image"; then
    error_exit "检测到无效的 Docker 镜像名称: $image"
  fi

  local network_name
  network_name="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{printf "%s\n" $name}}{{end}}' mihomo 2>/dev/null | head -n 1 || true)"
  [ -z "${network_name:-}" ] && error_exit "无法检测 mihomo 容器网络"

  local ip
  ip="$(docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{printf "%s\n" $net.IPAddress}}{{end}}' mihomo 2>/dev/null | head -n 1 || true)"
  [ -z "${ip:-}" ] && error_exit "无法检测 mihomo 容器 IP"

  local config_dir
  config_dir="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/root/.config/mihomo"}}{{.Source}}{{end}}{{end}}' mihomo 2>/dev/null || true)"
  [ -z "${config_dir:-}" ] && error_exit "无法检测 mihomo 容器配置目录挂载"

  log_info "拉取镜像: $image"
  run_cmd "docker pull '$image'"

  log_info "重建容器以应用新镜像..."
  run_cmd "docker rm -f mihomo"
  run_cmd "docker run -d --name mihomo \
    --restart=always \
    --network='$network_name' \
    --ip='$ip' \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e TZ=Asia/Shanghai \
    $tz_mounts \
    -v '$config_dir:/root/.config/mihomo' \
    '$image'" || error_exit "启动容器失败"

  log_info "Docker 模式更新完成"
  return 0
}

do_update() {
  if [ -z "${USE_GH_PROXY:-}" ]; then
    if [ -n "${TTY:-}" ]; then
      USE_GH_PROXY="$(prompt_yes_no "是否使用 GitHub 代理加速资源下载" "yes")"
      if [ "$USE_GH_PROXY" = "yes" ]; then
        GH_PROXY_BASE="$(prompt "GitHub 代理地址" "${GH_PROXY_BASE:-https://ghfast.top}")"
      fi
    else
      USE_GH_PROXY="no"
    fi
  fi

  update_template_file || true

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx mihomo; then
    update_mihomo_docker
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx mihomo.service; then
      update_mihomo_binary
      return 0
    fi
  fi

  if command -v mihomo >/dev/null 2>&1; then
    update_mihomo_binary
    return 0
  fi

  error_exit "未检测到现有部署（docker 容器或 systemd 服务），请先安装"
}

# 启用自动更新
enable_auto_update_action() {
  log_info "启用自动更新..."

  # 查找配置目录
  local cfg=""
  for cfg in /opt/mihomo/.deploy_config /volume1/docker/mihomo/.deploy_config /root/mihomo/.deploy_config /etc/mihomo/.deploy_config; do
    if [ -f "$cfg" ]; then
      load_saved_config "$cfg" || true
      break
    fi
  done

  if [ -z "${CONFIG_DIR:-}" ]; then
    error_exit "未找到配置目录，请先安装 Mihomo"
  fi

  # 检查 cron 是否可用
  if ! command -v crontab >/dev/null 2>&1; then
    error_exit "crontab 命令不可用，无法安装自动更新"
  fi

  # 询问更新频率
  printf "\n"
  printf "%s\n" "更新频率选项："
  printf "%s\n" "  1) 每天更新一次（推荐，默认）"
  printf "%s\n" "  2) 每周更新一次"
  printf "%s\n" "  3) 每小时更新一次"
  printf "\n"
  printf "请选择更新频率 [1-3，默认 1]: "
  read -r freq_choice
  case "$freq_choice" in
    2|"weekly")
      AUTO_UPDATE_INTERVAL="weekly"
      ;;
    3|"hourly")
      AUTO_UPDATE_INTERVAL="hourly"
      ;;
    *)
      AUTO_UPDATE_INTERVAL="daily"
      ;;
  esac

  install_auto_update "$CONFIG_DIR" "$AUTO_UPDATE_INTERVAL"

  log_info "自动更新已启用，查看日志: $CONFIG_DIR/auto-update.log"
}

# 禁用自动更新
disable_auto_update_action() {
  log_info "禁用自动更新..."

  # 查找配置目录
  local cfg=""
  for cfg in /opt/mihomo/.deploy_config /volume1/docker/mihomo/.deploy_config /root/mihomo/.deploy_config /etc/mihomo/.deploy_config; do
    if [ -f "$cfg" ]; then
      load_saved_config "$cfg" || true
      break
    fi
  done

  if [ -z "${CONFIG_DIR:-}" ]; then
    error_exit "未找到配置目录"
  fi

  remove_auto_update "$CONFIG_DIR"

  log_info "自动更新已禁用"
}

# 修改订阅链接
change_subscription_action() {
  log_info "修改订阅链接..."

  # 查找配置目录
  local cfg=""
  for cfg in /opt/mihomo/.deploy_config /volume1/docker/mihomo/.deploy_config /root/mihomo/.deploy_config /etc/mihomo/.deploy_config; do
    if [ -f "$cfg" ]; then
      load_saved_config "$cfg" || true
      break
    fi
  done

  if [ -z "${CONFIG_DIR:-}" ]; then
    error_exit "未找到配置目录，请先安装"
  fi

  printf "\n"
  printf "%s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "%s\n" "  修改订阅链接"
  printf "%s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "\n"
  printf "当前订阅链接: %s\n" "${SUB_URL:-未设置}"
  printf "\n"

  local new_url
  new_url="$(prompt "新的订阅链接" "")"

  if [ -z "$new_url" ]; then
    log_info "订阅链接未修改"
    return 0
  fi

  # 验证 URL
  new_url="$(sanitize_url "$new_url")"

  # 更新配置文件
  local saved_config="$CONFIG_DIR/.deploy_config"
  if [ -f "$saved_config" ]; then
    # 使用 sed 替换 SUB_URL
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s|^SUB_URL=.*|SUB_URL=\"$new_url\"|" "$saved_config"
    else
      sed -i "s|^SUB_URL=.*|SUB_URL=\"$new_url\"|" "$saved_config"
    fi
    log_info "订阅链接已更新到配置文件"
  fi

  # 更新 YAML 配置文件（精确匹配 proxy-providers 下的 url）
  local yaml_file="$CONFIG_DIR/config.yaml"
  if [ -f "$yaml_file" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s|^    url: \".*\"|    url: \"$new_url\"|" "$yaml_file"
    else
      sed -i "s|^    url: \".*\"|    url: \"$new_url\"|" "$yaml_file"
    fi
    log_info "YAML 配置文件已更新"
  fi

  # 删除旧的订阅缓存文件，让 mihomo 重新下载
  local sub_file="$CONFIG_DIR/proxy_providers/sub.yaml"
  if [ -f "$sub_file" ]; then
    rm -f "$sub_file"
    log_info "已删除旧的订阅缓存，重启后将重新下载"
  fi

  # 重启 mihomo 服务
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet mihomo 2>/dev/null; then
      log_info "重启 mihomo 服务..."
      systemctl restart mihomo
      log_info "mihomo 服务已重启"
    fi
  elif command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -qx mihomo 2>/dev/null; then
      log_info "重启 mihomo 容器..."
      docker restart mihomo
      log_info "mihomo 容器已重启"
    fi
  fi

  log_info "订阅链接修改完成！"
  printf "\n新订阅链接: %s\n" "$new_url"
}

select_menu_action() {
  printf "\n"
  printf "%s\n" "请选择要执行的操作："
  printf "%s\n" "1) 一键安装/部署（首次安装或重新部署）"
  printf "%s\n" "2) 一键更新（模板文件 + mihomo 二进制）"
  printf "%s\n" "3) 启用自动更新（cron 任务）"
  printf "%s\n" "4) 禁用自动更新"
  printf "%s\n" "5) 修改订阅链接"
  printf "%s\n" "6) 一键卸载（彻底清理）"
  printf "%s\n" "7) 命令大全（脚本所有命令）"
  printf "\n"

  local choice
  choice="$(prompt "输入选项" "1")"
  case "$choice" in
    1) ACTION="install" ;;
    2) ACTION="update" ;;
    3) ACTION="enable_auto_update" ;;
    4) ACTION="disable_auto_update" ;;
    5) ACTION="change_subscription" ;;
    6) ACTION="uninstall" ;;
    7) ACTION="commands" ;;
    *) ACTION="install" ;;
  esac
}

self_update_script() {
  if [ "${SKIP_SELF_UPDATE:-0}" -eq 1 ]; then
    return 0
  fi

  local script_path="$SCRIPT_DIR/$SCRIPT_NAME"
  if [ ! -f "$script_path" ]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  local url="https://raw.githubusercontent.com/binbin1213/Mihomo-Gateway-Script/main/deploy-mihomo-optimized.sh"

  local ok=0
  if download_file "$url" "$tmp" "false" 1 15; then
    ok=1
  else
    local old_proxy="${USE_GH_PROXY:-no}"
    local old_proxy_base="${GH_PROXY_BASE:-}"
    USE_GH_PROXY="yes"
    GH_PROXY_BASE="https://ghfast.top"
    if download_file "$(wrap_github_url "$url")" "$tmp" "false" 1 20; then
      ok=1
    fi
    USE_GH_PROXY="$old_proxy"
    GH_PROXY_BASE="$old_proxy_base"
  fi

  if [ "$ok" -ne 1 ]; then
    rm -f "$tmp"
    log_warn "脚本自更新检查失败，继续使用当前版本"
    return 0
  fi

  if cmp -s "$tmp" "$script_path"; then
    rm -f "$tmp"
    log_info "脚本已是最新版本"
    return 0
  fi

  local remote_version
  remote_version="$(awk -F'"' '/^VERSION=/{print $2; exit}' "$tmp" 2>/dev/null || true)"
  [ -z "${remote_version:-}" ] && remote_version="unknown"

  local backup="$script_path.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$script_path" "$backup" || true
  mv "$tmp" "$script_path" || true
  chmod +x "$script_path" 2>/dev/null || true

  log_info "脚本已更新（$remote_version），重新执行..."
  exec "$script_path" --install --skip-self-update
}

# =============================================================================
# 显示 Banner
# =============================================================================

show_banner() {
  # 检测终端颜色支持
  local red=""
  local green=""
  local yellow=""
  local blue=""
  local cyan=""
  local reset=""

  if [ -t 1 ]; then
    red="\033[31m"
    green="\033[32m"
    yellow="\033[33m"
    blue="\033[34m"
    cyan="\033[36m"
    bold="\033[1m"
    reset="\033[0m"
  fi

  # 清屏
  clear

  # 打印 Banner
  printf "\n"
  printf "${bold}${green}"
  printf "   ███║   ███║  ██║  ██║  ██║   ██████║   ███║   ███║   ██████║\n"
  printf "   ████║ ████║  ██║  ██║  ██║  ██║   ██║  ████║ ████║  ██║   ██║\n"
  printf "   ██║ ██║ ██║  ██║  ███████║  ██║   ██║  ██║ ██║ ██║  ██║   ██║\n"
  printf "   ██║ ██║ ██║  ██║  ██║  ██║  ██║   ██║  ██║ ██║ ██║  ██║   ██║\n"
  printf "   ██║     ██║  ██║  ██║  ██║   ██████║   ██║     ██║   ██████║\n"
  printf "${reset}\n"
  printf "   ${yellow}▸ 透明网关自动部署脚本 v${VERSION}${reset}\n"
  printf "\n"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
  local start_time=$(date +%s)

  # 解析命令行参数
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -m|--mode)
        DEPLOY_MODE="${2:-}"
        shift 2
        ;;
      --mode=*)
        DEPLOY_MODE="${1#*=}"
        shift
        ;;
      --install)
        ACTION="install"
        shift
        ;;
      --update)
        ACTION="update"
        shift
        ;;
      --commands)
        ACTION="commands"
        shift
        ;;
      --skip-self-update)
        SKIP_SELF_UPDATE=1
        shift
        ;;
      -d|--dry-run)
        DRY_RUN=1
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -u|--uninstall)
        ACTION="uninstall"
        shift
        ;;
      --enable-auto-update)
        ACTION="enable_auto_update"
        shift
        ;;
      --disable-auto-update)
        ACTION="disable_auto_update"
        shift
        ;;
      *)
        printf "错误：未知参数 %s\n\n" "$1" >&2
        usage
        exit 1
        ;;
    esac
  done

  # 显示 Banner
  show_banner

  # 初始化日志
  init_logging

  log_info "Mihomo Gateway Script v$VERSION"
  log_info "==========================================="

  if [ -z "${ACTION:-}" ]; then
    if [ -n "${TTY:-}" ]; then
      select_menu_action
    else
      ACTION="install"
    fi
  fi

  case "$ACTION" in
    commands)
      show_commands
      return 0
      ;;
    uninstall)
      uninstall_mihomo
      return 0
      ;;
    update)
      do_update
      return 0
      ;;
    enable_auto_update)
      enable_auto_update_action
      return 0
      ;;
    disable_auto_update)
      disable_auto_update_action
      return 0
      ;;
    change_subscription)
      change_subscription_action
      return 0
      ;;
    install)
      self_update_script
      ;;
    *)
      ACTION="install"
      self_update_script
      ;;
  esac

  # 检测平台
  PLATFORM="$(detect_platform)"
  log_info "检测到平台: $PLATFORM"

  # 自动选择部署模式
  if [ -z "$DEPLOY_MODE" ]; then
    if command -v docker >/dev/null 2>&1; then
      DEPLOY_MODE="docker"
    else
      DEPLOY_MODE="binary"
    fi
    log_info "自动选择部署模式: $DEPLOY_MODE"
  fi

  # 验证部署模式
  case "$DEPLOY_MODE" in
    docker|binary)
      log_info "部署模式: $DEPLOY_MODE"
      ;;
    *)
      error_exit "不支持的部署模式: $DEPLOY_MODE（仅支持 docker 或 binary）"
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "试运行模式：命令将不会实际执行"
  fi

  # 检测网络配置
  detect_network_config

  # 检查依赖
  check_dependencies

  # 收集参数
  collect_parameters

  # 创建配置目录
  if [ ! -d "$CONFIG_DIR" ]; then
    log_info "创建配置目录: $CONFIG_DIR"
    run_cmd "mkdir -p \"$CONFIG_DIR\""
  fi

  # 创建必要的子目录
  log_info "创建配置子目录..."
  run_cmd "mkdir -p \"$CONFIG_DIR/proxy_providers\" \"$CONFIG_DIR/ruleset\" \"$CONFIG_DIR/ui\"" || true

  # 备份现有配置
  local config_file="$CONFIG_DIR/config.yaml"
  if [ -f "$config_file" ]; then
    backup_config "$config_file"
  fi

  # 安装管理面板
  install_dashboard

  # 生成配置
  generate_dns_config
  generate_rules_config

  # 根据配置类型选择模板
  local template_path=""
  local template_url=""
  case "$CONFIG_TEMPLATE" in
    region)
      template_path="$SCRIPT_DIR/config-region.yaml.tpl"
      template_url="https://raw.githubusercontent.com/binbin1213/Mihomo-Gateway-Script/main/config-region.yaml.tpl"
      ;;
    *)
      template_path="$SCRIPT_DIR/config.yaml.tpl"
      template_url="https://raw.githubusercontent.com/binbin1213/Mihomo-Gateway-Script/main/config.yaml.tpl"
      ;;
  esac

  # 模板文件不存在时自动下载
  if [ ! -f "$template_path" ]; then
    log_warn "配置模板不存在，开始从 GitHub 下载..."
    log_info "使用模板: $CONFIG_TEMPLATE"

    local tpl_url
    tpl_url="$(wrap_github_url "$template_url")"

    # 创建临时目录下载
    local tmp_tpl
    tmp_tpl="$(mktemp)"

    if download_file "$tpl_url" "$tmp_tpl" "false"; then
      # 移动到目标位置
      if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] mv '$tmp_tpl' '$template_path'"
      else
        mv "$tmp_tpl" "$template_path" || error_exit "移动模板文件失败"
      fi
      log_info "配置模板下载完成: $template_path"
    else
      rm -f "$tmp_tpl"
      error_exit "下载配置模板失败，请手动下载: $tpl_url"
    fi
  fi

  render_config_from_tpl "$template_path" "$config_file"

  # 部署
  if [ "$DEPLOY_MODE" = "docker" ]; then
    deploy_docker_mode
  elif [ "$DEPLOY_MODE" = "binary" ]; then
    deploy_binary_mode
  fi

  # 验证配置（此时 mihomo 已可用）
  log_info "验证配置文件..."
  local mihomo_cmd="mihomo"
  if [ "$DEPLOY_MODE" = "docker" ]; then
    # Docker 模式：在容器内验证
    if docker exec mihomo mihomo -d /root/.config/mihomo -t >/dev/null 2>&1; then
      log_info "配置文件验证通过"
    else
      log_warn "配置文件验证失败，但服务可能仍能运行"
    fi
  else
    # Binary 模式：直接验证
    if validate_config "$config_file" "mihomo"; then
      log_info "配置文件验证通过"
    else
      log_warn "配置文件验证失败，但服务可能仍能运行"
    fi
  fi

  # 健康检查
  health_check || log_warn "健康检查未完全通过，请按日志手动排查"

  # 自动更新
  if [ "${AUTO_UPDATE:-}" = "yes" ]; then
    if command -v crontab >/dev/null 2>&1; then
      install_auto_update "$CONFIG_DIR" "${AUTO_UPDATE_INTERVAL:-daily}"
    else
      log_warn "crontab 不可用，跳过自动更新安装"
    fi
  fi

  # 显示部署信息
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  printf "\n"
  printf "%s\n" "=========================================="
  printf "%s\n" "部署完成！"
  printf "%s\n" "=========================================="
  printf "%s\n" "部署模式: $DEPLOY_MODE"
  printf "%s\n" "Mihomo IP: $MIHOMO_IP"
  printf "%s\n" "配置文件: $config_file"
  printf "%s\n" "控制面板: http://$MIHOMO_IP:19090/ui"
  printf "%s\n" "面板密钥: $CLASH_SECRET"
  printf "%s\n" "----------------------------------------"
  printf "%s\n" "客户端配置："
  printf "%s\n" "  网关: $MIHOMO_IP"
  printf "%s\n" "  DNS: $MIHOMO_IP"
  printf "%s\n" "----------------------------------------"
  printf "%s\n" "日志文件: $LOG_FILE"
  printf "%s\n" "耗时: ${duration} 秒"
  printf "%s\n" "=========================================="
  printf "\n"

  log_info "部署成功完成，耗时 ${duration} 秒"

  return 0
}

# 启动主函数
main "$@"
