#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="OpenClaw 飞牛 NAS 一键安装 / 彻底卸载脚本"
SAFE_SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
TARGET_USER="${SUDO_USER:-${USER:-}}"

if [[ -z "$TARGET_USER" ]]; then
  echo "[错误] 无法识别当前用户名。"
  exit 1
fi

TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
[[ -n "$TARGET_GROUP" ]] || TARGET_GROUP="$TARGET_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/home/$TARGET_USER"

NPM_GLOBAL_DIR="$TARGET_HOME/.npm-global"
LOCAL_BIN_DIR="$TARGET_HOME/.local/bin"
OPENCLAW_DIR="$TARGET_HOME/.openclaw"
NPMRC_FILE="$TARGET_HOME/.npmrc"
BASHRC_FILE="$TARGET_HOME/.bashrc"
PROFILE_FILE="$TARGET_HOME/.profile"
BASH_PROFILE_FILE="$TARGET_HOME/.bash_profile"
PATH_BLOCK_BEGIN="# >>> OpenClaw FNOS PATH >>>"
PATH_LINE='export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"'
PATH_BLOCK_END="# <<< OpenClaw FNOS PATH <<<"

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[警告] %s\n' "$*"; }
err()  { printf '\n[错误] %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
}

run_as_target() {
  local cmd="$*"
  if [[ "$(id -un 2>/dev/null || true)" == "$TARGET_USER" ]]; then
    HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" PATH="$SAFE_SYSTEM_PATH" bash -c "$cmd"
  else
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" PATH="$SAFE_SYSTEM_PATH" bash -c "$cmd"
  fi
}

run_as_root() {
  local cmd="$*"
  if [[ "$(id -u)" -eq 0 ]]; then
    PATH="$SAFE_SYSTEM_PATH" bash -c "$cmd"
  else
    sudo env PATH="$SAFE_SYSTEM_PATH" bash -c "$cmd"
  fi
}

strip_ansi() {
  sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'
}

append_path_block() {
  local file="$1"
  [[ -f "$file" ]] || run_as_target "touch '$file'"

  if ! grep -Fq "$PATH_BLOCK_BEGIN" "$file" 2>/dev/null; then
    cat >> "$file" <<BLOCK

$PATH_BLOCK_BEGIN
$PATH_LINE
$PATH_BLOCK_END
BLOCK
    chown "$TARGET_USER:$TARGET_GROUP" "$file" 2>/dev/null || true
  fi
}

remove_path_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  sed -i \
    -e "/$(printf '%s' "$PATH_BLOCK_BEGIN" | sed 's/[][\\/.^$*]/\\&/g')/,/$(printf '%s' "$PATH_BLOCK_END" | sed 's/[][\\/.^$*]/\\&/g')/d" \
    -e '/# OpenClaw npm global path/d' \
    -e '/\.npm-global\/bin:\$HOME\/.local\/bin:\$PATH/d' \
    "$file" || true

  if [[ -f "$file" ]] && [[ -z "$(tr -d '[:space:]' < "$file")" ]]; then
    rm -f "$file"
  fi
}

remove_completion_lines() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  sed -i \
    -e '/\.openclaw\/completions\/openclaw\.bash/d' \
    -e '/openclaw\.bash["'\'' ]*$/d' \
    -e '/# OpenClaw Completion/d' \
    "$file" || true

  if [[ -f "$file" ]] && [[ -z "$(tr -d '[:space:]' < "$file")" ]]; then
    rm -f "$file"
  fi
}

cleanup_empty_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  rmdir "$dir" 2>/dev/null || true
}

cleanup_empty_tree() {
  local start="$1"
  local stop="$2"
  local current="$start"
  while [[ -n "$current" && "$current" != "/" ]]; do
    rmdir "$current" 2>/dev/null || break
    [[ "$current" == "$stop" ]] && break
    current="$(dirname "$current")"
  done
}

prepare_shell_files() {
  remove_completion_lines "$BASH_PROFILE_FILE"
  remove_completion_lines "$PROFILE_FILE"
  remove_completion_lines "$BASHRC_FILE"
}

ensure_home_dirs() {
  need_cmd sudo
  need_cmd bash
  need_cmd curl

  log "准备用户目录: $TARGET_HOME"

  if [[ ! -d "$TARGET_HOME" ]]; then
    run_as_root "mkdir -p '$TARGET_HOME'"
  fi

  run_as_root "chown '$TARGET_USER:$TARGET_GROUP' '$TARGET_HOME'"
  run_as_root "chmod 755 '$TARGET_HOME'"

  run_as_target "mkdir -p '$NPM_GLOBAL_DIR' '$LOCAL_BIN_DIR' '$OPENCLAW_DIR' '$TARGET_HOME/.config' '$TARGET_HOME/.cache'"

  prepare_shell_files
  append_path_block "$BASH_PROFILE_FILE"
  append_path_block "$PROFILE_FILE"
  append_path_block "$BASHRC_FILE"

  if command -v npm >/dev/null 2>&1; then
    run_as_target "npm config set prefix '$NPM_GLOBAL_DIR'"
    log "当前 npm 全局目录:"
    run_as_target "PATH='$SAFE_SYSTEM_PATH' npm prefix -g || true"
  else
    warn "当前环境还没有 npm，后续由 OpenClaw 官方安装器处理。"
  fi
}

ensure_gateway_background() {
  log "确保 OpenClaw Gateway 以后台服务方式运行"

  run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway start >/dev/null 2>&1 || true"

  if ! run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway status --require-rpc >/dev/null 2>&1"; then
    warn "后台服务首次探测未通过，尝试重启 Gateway 服务"
    run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway restart >/dev/null 2>&1 || true"
  fi

  if run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway status --require-rpc >/dev/null 2>&1"; then
    log "后台服务已正常运行"
  else
    warn "Gateway 已安装为服务，但暂未通过 RPC 探测。你可以稍后手动执行：openclaw gateway status"
  fi
}

show_login_info() {
  local status_raw=""
  local status_clean=""
  local dashboard_raw=""
  local dashboard_clean=""
  local token_raw=""
  local token=""
  local gateway_line=""
  local port="18789"
  local web_ui_url=""
  local web_ui_token_url=""
  local gateway_ws=""
  local docs_url="https://docs.openclaw.ai/web/control-ui"

  status_raw="$(run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway status 2>/dev/null || true")"
  dashboard_raw="$(run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw dashboard --no-open 2>/dev/null || true")"
  token_raw="$(run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw config get gateway.auth.token 2>/dev/null || true")"

  status_clean="$(printf '%s\n' "$status_raw" | strip_ansi | tr -d '\r')"
  dashboard_clean="$(printf '%s\n' "$dashboard_raw" | strip_ansi | tr -d '\r')"
  token="$(printf '%s\n' "$token_raw" | tail -n 1 | tr -d '\r' | sed 's/^ *//;s/ *$//')"

  gateway_line="$(printf '%s\n' "$status_clean" | grep -E '^Gateway:' | head -n 1 || true)"
  if [[ -n "$gateway_line" ]]; then
    local parsed_port=""
    parsed_port="$(printf '%s\n' "$gateway_line" | sed -n 's/.*port=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    [[ -n "$parsed_port" ]] && port="$parsed_port"
  fi

  web_ui_url="$(printf '%s\n' "$dashboard_clean" | grep -Eo 'https?://[^[:space:]]+' | head -n 1 || true)"
  [[ -n "$web_ui_url" ]] || web_ui_url="http://127.0.0.1:${port}/"

  if [[ -n "$token" && "$token" != "null" && "$token" != "undefined" ]]; then
    web_ui_token_url="${web_ui_url%%#*}#token=${token}"
  else
    web_ui_token_url="$(printf '%s\n' "$dashboard_clean" | grep -Eo 'https?://[^[:space:]]+#token=[^[:space:]]+' | head -n 1 || true)"
  fi

  gateway_ws="ws://127.0.0.1:${port}"

  cat <<MSG

============================================
登录 / 连接信息
============================================
Web UI: $web_ui_url
MSG

  if [[ -n "$web_ui_token_url" ]]; then
    printf 'Web UI (with token): %s\n' "$web_ui_token_url"
  else
    printf 'Web UI (with token): 未直接读取到，可手动执行：openclaw dashboard --no-open\n'
  fi

  printf 'Gateway WS: %s\n' "$gateway_ws"
  if [[ -n "$gateway_line" ]]; then
    printf '%s\n' "$gateway_line"
  else
    printf 'Gateway: reachable（未读取到详细状态，按默认端口推断）\n'
  fi
  printf 'Docs: %s\n' "$docs_url"
  printf '============================================\n'
}

install_openclaw() {
  need_cmd curl
  need_cmd bash
  need_cmd sudo
  need_cmd npm

  ensure_home_dirs

  log "开始安装 OpenClaw（使用官方 installer，跳过自动 onboard）"
  run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard"

  log "执行 OpenClaw 初始化并安装网关服务"
  run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw onboard --install-daemon"

  ensure_gateway_background

  log "安装完成，执行基础检查"
  run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw doctor || true"
  run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; openclaw gateway status || true"

  cat <<MSG

============================================
安装完成
当前用户: $TARGET_USER
真实家目录: $TARGET_HOME
OpenClaw 状态目录: $OPENCLAW_DIR

以后无论你登录后落在哪个目录，直接运行：
  bash ~/openclaw-fnos-menu.sh

后台服务常用命令：
  openclaw gateway status
  openclaw gateway restart
============================================
MSG

  show_login_info
}

cleanup_openclaw_in_home() {
  local home="$1"
  [[ -d "$home" ]] || return 0

  log "清理目录中的 OpenClaw / npm 残留: $home"

  rm -rf \
    "$home/.openclaw" \
    "$home/.openclaw-dev" \
    "$home/.local/share/openclaw" \
    "$home/.cache/openclaw" \
    "$home/.config/openclaw" \
    "$home/.npm-global" \
    "$home/.npm" \
    "$home/openclaw-gateway.log" \
    2>/dev/null || true

  find "$home" -maxdepth 1 -mindepth 1 -type d -name '.openclaw-*' -exec rm -rf {} + 2>/dev/null || true

  if [[ -d "$home/.config/systemd/user" ]]; then
    rm -f "$home/.config/systemd/user"/openclaw-gateway*.service 2>/dev/null || true
    rm -rf "$home/.config/systemd/user"/openclaw-gateway*.service.d 2>/dev/null || true
    rm -f "$home/.config/systemd/user/default.target.wants"/openclaw-gateway*.service 2>/dev/null || true
  fi

  if [[ -d "$home/.local/bin" ]]; then
    rm -f "$home/.local/bin/openclaw" 2>/dev/null || true
  fi

  if [[ -f "$home/.npmrc" ]]; then
    sed -i -E '/^[[:space:]]*prefix[[:space:]]*=.*/d' "$home/.npmrc" || true
    if [[ -z "$(tr -d '[:space:]' < "$home/.npmrc")" ]]; then
      rm -f "$home/.npmrc"
    fi
  fi

  remove_completion_lines "$home/.bash_profile"
  remove_completion_lines "$home/.profile"
  remove_completion_lines "$home/.bashrc"
  remove_path_block "$home/.bash_profile"
  remove_path_block "$home/.profile"
  remove_path_block "$home/.bashrc"

  rm -f "$home/.bash_profile" "$home/.bashrc" "$home/.bash_history" 2>/dev/null || true

  cleanup_empty_dir "$home/.local/bin"
  cleanup_empty_tree "$home/.local/share" "$home/.local"
  cleanup_empty_tree "$home/.local" "$home"
  cleanup_empty_tree "$home/.cache" "$home"
  cleanup_empty_tree "$home/.config/systemd/user/default.target.wants" "$home/.config"
  cleanup_empty_tree "$home/.config/systemd/user" "$home/.config"
  cleanup_empty_tree "$home/.config/systemd" "$home/.config"
  cleanup_empty_tree "$home/.config" "$home"
}

uninstall_openclaw() {
  need_cmd bash
  need_cmd sudo

  log "开始彻底卸载 OpenClaw 并恢复到安装前状态"

  if command -v openclaw >/dev/null 2>&1; then
    export HOME="$TARGET_HOME"
    export PATH="$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH:$PATH"
    openclaw uninstall --all --yes --non-interactive >/dev/null 2>&1 || true
  else
    run_as_target "export PATH='$NPM_GLOBAL_DIR/bin:$LOCAL_BIN_DIR:$SAFE_SYSTEM_PATH'; if command -v openclaw >/dev/null 2>&1; then openclaw uninstall --all --yes --non-interactive >/dev/null 2>&1 || true; fi"
  fi

  if command -v npm >/dev/null 2>&1; then
    run_as_target "export PATH='$SAFE_SYSTEM_PATH'; npm rm -g openclaw >/dev/null 2>&1 || true"
  fi
  if command -v pnpm >/dev/null 2>&1; then
    run_as_target "export PATH='$SAFE_SYSTEM_PATH'; pnpm remove -g openclaw >/dev/null 2>&1 || true"
  fi
  if command -v bun >/dev/null 2>&1; then
    run_as_target "export PATH='$SAFE_SYSTEM_PATH'; bun remove -g openclaw >/dev/null 2>&1 || true"
  fi

  cleanup_openclaw_in_home "$TARGET_HOME"

  log "清理系统临时目录"
  rm -rf /tmp/openclaw /tmp/openclaw-* 2>/dev/null || true

  cat <<MSG

============================================
卸载完成
已清理：
- ~/.openclaw 及其衍生目录
- ~/.npm-global / ~/.npm / ~/.npmrc 中的 prefix
- ~/.bash_profile / ~/.profile / ~/.bashrc 里的 PATH 和补全残留
- ~/.config/systemd/user 下的 openclaw-gateway 服务文件
- ~/.config/openclaw / ~/.cache/openclaw / ~/.local/share/openclaw
- /tmp/openclaw* 临时目录和日志
- ~/.bash_profile / ~/.bashrc / ~/.bash_history

未清理：
- Node / npm / pnpm / bun 本体
- .ssh 和其它非 OpenClaw 文件
============================================
MSG
}

show_menu() {
  cat <<MENU

============================================
$SCRIPT_NAME
当前用户: $TARGET_USER
真实家目录: $TARGET_HOME
============================================
1) 安装 OpenClaw（自动后台运行）
2) 彻底卸载并恢复到安装前状态
0) 退出
MENU
}

main() {
  while true; do
    show_menu
    read -rp '请选择操作 [1/2/0]: ' choice
    case "$choice" in
      1)
        install_openclaw
        break
        ;;
      2)
        uninstall_openclaw
        break
        ;;
      0)
        echo '已退出。'
        exit 0
        ;;
      *)
        echo '输入无效，请重新选择。'
        ;;
    esac
  done
}

main "$@"
