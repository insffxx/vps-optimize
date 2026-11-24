#!/usr/bin/env bash
# =============================================================================
#  vps-optimize.sh —— 新 VPS 初始化与优化工具（逐项可选、每步可回滚）
#  适用：Ubuntu 22.04 / 24.04、Debian 12（含甲骨文云 Oracle Cloud 镜像的特殊处理）
#
#  一键运行：bash <(curl -fsSL https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh)
#  用法：
#    sudo bash vps-optimize.sh              打开菜单，自己挑要做的项（可输入多个编号，如 3 5 9）
#    sudo bash vps-optimize.sh auto         一键推荐优化（一路回车即可，不含 SSH 加固/改端口）
#    sudo bash vps-optimize.sh 9            直接执行第 9 项
#    sudo bash vps-optimize.sh status       只看当前状态，不改任何东西
#    sudo DRY_RUN=1 bash vps-optimize.sh    预演模式：只打印将要做的改动，不真正执行
#
#  原则：每项都先说明要改什么 → 你确认 → 备份原文件 → 修改 → 校验。
#        改过的文件都备份在 /var/backups/vps-optimize/<时间>/ 下。
#  License: MIT
# =============================================================================
set -uo pipefail

VERSION="1.1.0"
RAW_URL="https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh"
AUTO="${AUTO:-0}"
TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/vps-optimize/$TS"
DRY="${DRY_RUN:-0}"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 输出 ----------
if [ -t 1 ]; then C0=$'\e[0m'; CB=$'\e[1m'; CG=$'\e[32m'; CY=$'\e[33m'; CR=$'\e[31m'; CC=$'\e[36m'; else C0=; CB=; CG=; CY=; CR=; CC=; fi
info(){ echo "${CC}•${C0} $*"; }
ok(){   echo "${CG}✔${C0} $( [ "${DRY_RUN:-0}" = 1 ] && echo "（预演）")$*"; }
warn(){ echo "${CY}⚠${C0} $*"; }
err(){  echo "${CR}✘${C0} $*" >&2; }
hr(){   echo "────────────────────────────────────────────────────────"; }
title(){ echo; hr; echo "${CB}$*${C0}"; hr; }

ask(){ # ask "问题" "默认值" -> 打印答案（AUTO=1 时直接用默认值）
  local a; if [ "$AUTO" = 1 ]; then echo "$1：${2:-（空）}（自动）" >&2; echo "${2:-}"; return; fi
  read -r -p "$1${2:+ [默认 $2]}: " a </dev/tty || a=""; echo "${a:-${2:-}}"; }
yesno(){ # yesno "问题" [y|n 默认]
  local d="${2:-n}" a
  if [ "$AUTO" = 1 ]; then echo "$1 → $( [ "$d" = y ] && echo 是 || echo 否)（自动）"; [ "$d" = y ]; return; fi
  read -r -p "$1 $( [ "$d" = y ] && echo '[Y/n]' || echo '[y/N]' ): " a </dev/tty || a=""
  a="${a:-$d}"; [[ "$a" =~ ^[Yy] ]]; }

# ---------- 执行 / 备份（预演模式下只打印） ----------
exec 3>&1
run(){ if [ "$DRY" = 1 ]; then echo "  [预演] $*" >&3; else "$@"; fi; }
backup(){ local f; for f in "$@"; do [ -e "$f" ] || continue; mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; done; }
put(){ # put <文件> <权限>  内容从 stdin 读入
  local f="$1" mode="${2:-644}" tmp; tmp="$(mktemp)"; cat >"$tmp"
  if [ "$DRY" = 1 ]; then echo "  [预演] 将写入 $f："; sed 's/^/    | /' "$tmp"; rm -f "$tmp"; return 0; fi
  backup "$f"; mkdir -p "$(dirname "$f")"; install -m "$mode" "$tmp" "$f"; rm -f "$tmp"; }

# ---------- 环境检测 ----------
need_root(){
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null || { err "需要 root 权限：先切到 root 再运行"; exit 1; }
  info "需要 root 权限，自动用 sudo 重新运行…"
  if [ -f "$SELF" ] && [[ "$SELF" != /dev/fd/* && "$SELF" != /proc/* ]]; then exec sudo bash "$SELF" "$@"; fi
  # 通过 bash <(curl …) 运行时没有本地文件，重新下载一次再以 root 执行
  exec sudo bash -c 'bash <(curl -fsSL "$0") "$@"' "$RAW_URL" "$@"
}
os_check(){
  . /etc/os-release 2>/dev/null || { err "无法识别系统"; exit 1; }
  case "${ID:-}" in ubuntu|debian) : ;; *) warn "未在 ${PRETTY_NAME:-该系统} 上测试过，继续请自行承担风险"; yesno "继续？" || exit 1 ;; esac
}
is_oracle(){ grep -qi oracle /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || grep -qi "Oracle Cloud" /etc/iptables/rules.v4 2>/dev/null; }
admin_user(){ local u="${SUDO_USER:-}"; [ -n "$u" ] && [ "$u" != root ] && { echo "$u"; return; }; awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/{print $1; exit}' /etc/passwd; }
ssh_ports(){ sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ' | sed 's/ $//'; }
ssh_socket(){ systemctl is-active --quiet ssh.socket 2>/dev/null; }
listening(){ ss -Htln "sport = :$1" 2>/dev/null | grep -q .; }
fw_type(){
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then echo iptables-reject
  elif command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q 'hook input.*policy drop'; then echo nft
  else echo none; fi
}
pub_ip(){ curl -4 -s -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }
mem_mb(){ awk '/MemTotal/{print int($2/1024)}' /proc/meminfo; }

restart_ssh(){
  sshd -t || { err "sshd 配置校验失败，未重启"; return 1; }
  if ssh_socket; then run systemctl daemon-reload; run systemctl restart ssh.socket
  else run systemctl reload ssh 2>/dev/null || run systemctl reload sshd; fi
}

# 防火墙放行 / 删除（v4 + v6；甲骨文镜像要插在 REJECT 之前并写进 rules.v4/v6）
fw_allow(){ # fw_allow tcp|udp 端口
  local proto="$1" p="$2" f
  case "$(fw_type)" in
    ufw) run ufw allow "$p/$proto" >/dev/null ;;
    iptables-reject)
      for bin in iptables ip6tables; do
        $bin -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || run $bin -I INPUT 1 -p "$proto" --dport "$p" -j ACCEPT
      done
      for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f" ] || continue
        grep -qE -- "-p $proto .*--dport $p( |$).*-j ACCEPT" "$f" && continue
        grep -q -- '-A INPUT .*-j REJECT' "$f" || continue
        if [ "$DRY" = 1 ]; then echo "  [预演] $f 在 REJECT 前插入 $proto/$p"; continue; fi
        backup "$f"
        awk -v r="-A INPUT -p $proto -m $proto --dport $p -j ACCEPT" 'BEGIN{d=0} /^-A INPUT .*-j REJECT/ && !d {print r; d=1} {print}' "$f" >"$f.new" && mv "$f.new" "$f"
      done ;;
    nft) warn "检测到自定义 nftables 默认拒绝规则，请手动放行 $proto/$p" ;;
    none) : ;;
  esac
}
fw_remove(){ # fw_remove tcp 端口
  local proto="$1" p="$2" f
  case "$(fw_type)" in
    ufw) run ufw --force delete allow "$p/$proto" >/dev/null 2>&1; run ufw --force delete allow "$p" >/dev/null 2>&1; [ "$p" = 22 ] && run ufw --force delete allow OpenSSH >/dev/null 2>&1; true ;;
    iptables-reject)
      for bin in iptables ip6tables; do
        $bin -S INPUT 2>/dev/null | grep -E -- "^-A INPUT .*-p $proto .*--dport $p( |$).*-j ACCEPT" | while read -r rule; do
          # shellcheck disable=SC2086
          if [ "$DRY" = 1 ]; then echo "  [预演] $bin ${rule/-A INPUT/-D INPUT}" >&3; else eval "$bin ${rule/-A INPUT/-D INPUT}"; fi
        done
      done
      for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f" ] || continue; backup "$f"; run sed -i -E "/-p $proto .*--dport $p( |$).*-j ACCEPT/d" "$f"
      done ;;
    *) : ;;
  esac
}
cloud_reminder(){ # cloud_reminder tcp|udp 端口
  if is_oracle; then
    warn "甲骨文云还要在网页放行：控制台 → 网络 → 虚拟云网络 → 你的 VCN → 子网 → 安全列表 → 添加入站规则（源 0.0.0.0/0，协议 ${1^^}，端口 $2）"
  else
    warn "如果你的云厂商有「安全组 / 防火墙」网页设置，也要放行 ${1^^} $2"
  fi
}

# =============================================================================
#  各项任务（每项独立，可单独执行）
# =============================================================================
TASKS=(t_status t_sshkey t_sshharden t_sshport t_ipv6fw t_fail2ban t_services t_update t_autoupdate t_bbr t_sysctl t_swap t_timezone t_hostname t_journald t_dns t_openport t_ipv4pref t_timesync t_ufw t_shortcut)
NAMES=("查看当前状态（只读）" "添加 SSH 公钥" "SSH 加固（禁 root / 禁密码 / 限次数）" "更换 SSH 端口（带自动回滚）" "IPv6 防火墙补齐" "安装 fail2ban 防爆破" "关闭用不上的服务" "系统更新" "自动安全更新" "开启 BBR 加速" "内核网络安全参数" "创建 swap 交换空间" "设置时区" "修改主机名" "限制日志占用" "加密 DNS（DoT）" "系统防火墙放行端口" "IPv4 优先" "时间自动同步" "最小化防火墙（UFW）" "安装快捷命令 vpso")
AUTO_SET=(t_update t_autoupdate t_bbr t_sysctl t_swap t_timezone t_timesync t_journald t_ipv4pref t_services t_fail2ban t_ipv6fw)

done_mark(){ # 菜单里的 ✅ 状态（尽量快速、只读）
  case "$1" in
    t_sshkey) [ -s "$(getent passwd "$(admin_user)" | cut -d: -f6)/.ssh/authorized_keys" ] ;;
    t_sshharden) sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' && sshd -T 2>/dev/null | grep -qx 'permitrootlogin no' ;;
    t_sshport) [ "$(ssh_ports)" != 22 ] ;;
    t_ipv6fw) ! ip -6 addr show scope global 2>/dev/null | grep -q inet6 || ip6tables -S INPUT 2>/dev/null | grep -qE -- '-j (REJECT|DROP)|-P INPUT DROP' || [ "$(fw_type)" = ufw ] ;;
    t_fail2ban) systemctl is-active --quiet fail2ban ;;
    t_services) ! systemctl is-active --quiet rpcbind 2>/dev/null && ! systemctl is-active --quiet cups 2>/dev/null ;;
    t_autoupdate) grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null ;;
    t_bbr) [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] ;;
    t_sysctl) [ -f /etc/sysctl.d/91-vps-hardening.conf ] ;;
    t_swap) [ -n "$(swapon --show --noheadings 2>/dev/null)" ] ;;
    t_journald) [ -f /etc/systemd/journald.conf.d/00-vps-optimize.conf ] ;;
    t_dns) resolvectl status 2>/dev/null | grep -q '+DNSOverTLS' ;;
    t_ipv4pref) grep -qE '^precedence ::ffff:0:0/96 +100' /etc/gai.conf 2>/dev/null ;;
    t_timesync) [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] ;;
    t_ufw) [ "$(fw_type)" != none ] ;;
    t_shortcut) [ -x /usr/local/bin/vpso ] ;;
    *) return 1 ;;
  esac
}

# 0 ------------------------------------------------------------------------
t_status(){
  title "当前状态（只读）"
  . /etc/os-release; echo "系统：$PRETTY_NAME  内核：$(uname -r)  架构：$(uname -m)"
  echo "CPU：$(nproc) 核  内存：$(mem_mb) MB  磁盘(/)：$(df -h / | awk 'NR==2{print $2" 已用 "$5}')"
  echo "云厂商：$(is_oracle && echo 甲骨文云 || echo 未识别)  防火墙类型：$(fw_type)  时区：$(timedatectl show -p Timezone --value 2>/dev/null)"
  echo "SSH 端口：$(ssh_ports)  $(ssh_socket && echo '(socket 激活)')"
  sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|x11forwarding) ' | sed 's/^/  /'
  echo "BBR：$(sysctl -n net.ipv4.tcp_congestion_control)  swap：$(swapon --show --noheadings | awk '{print $3}' | head -1)"
  echo "fail2ban：$(systemctl is-active fail2ban 2>/dev/null)  自动更新：$(grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && echo 开 || echo 关)"
  echo "对外监听端口："; ss -Htulnp | awk '$5 !~ /^(127\.|\[::1\]|\[?fe80)/ {split($7,a,"\""); printf "  %-4s %-28s %s\n",$1,$5,a[2]}' | sort -u
  ip -6 addr show scope global 2>/dev/null | grep -q inet6 && { ip6tables -S INPUT 2>/dev/null | grep -qE -- '-j (REJECT|DROP)|-P INPUT DROP' || [ "$(fw_type)" = ufw ] || warn "有公网 IPv6，但 IPv6 防火墙没有任何拦截规则（建议执行第 4 项）"; }
  [ -f /var/run/reboot-required ] && warn "系统提示需要重启"
  echo "最近登录："; last -n 5 -w 2>/dev/null | grep -v '^$\|^wtmp' | sed 's/^/  /'
}

# 1 ------------------------------------------------------------------------
t_sshkey(){
  title "添加 SSH 公钥"
  local u home k; u="$(ask "给哪个用户添加" "$(admin_user)")"; home="$(getent passwd "$u" | cut -d: -f6)"
  [ -n "$home" ] || { err "用户 $u 不存在"; return 1; }
  echo "把你电脑上的公钥（以 ssh-ed25519 / ssh-rsa / ecdsa- 开头的一整行）粘贴进来："
  read -r k </dev/tty || k=""
  [[ "$k" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-) ]] || { err "这不像公钥（注意别贴私钥）"; return 1; }
  echo "$k" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1 || { err "公钥格式不正确"; return 1; }
  if grep -qF "$k" "$home/.ssh/authorized_keys" 2>/dev/null; then ok "这把公钥已经在里面了"; return 0; fi
  run install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
  backup "$home/.ssh/authorized_keys"
  if [ "$DRY" = 1 ]; then echo "  [预演] 追加到 $home/.ssh/authorized_keys"; else echo "$k" >>"$home/.ssh/authorized_keys"; chown "$u:$u" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"; fi
  ok "已添加：$(echo "$k" | ssh-keygen -lf /dev/stdin 2>/dev/null)"
  warn "先别关当前窗口，新开一个终端用这把密钥登录一次，确认能进再做 SSH 加固"
}

# 2 ------------------------------------------------------------------------
t_sshharden(){
  title "SSH 加固"
  local u home; u="$(admin_user)"; home="$(getent passwd "$u" | cut -d: -f6)"
  echo "将写入 /etc/ssh/sshd_config.d/00-hardening.conf："
  echo "  禁止 root 直接登录、禁止密码登录（只认密钥）、最多试 3 次、关 X11 转发、登录宽限 30 秒"
  if [ -z "$u" ] || [ ! -s "$home/.ssh/authorized_keys" ]; then
    err "没找到普通用户的 authorized_keys（$u）。先执行第 1 项添加公钥，否则关掉密码登录会把你锁在外面。"; return 1; fi
  ok "检测到 $u 已有 $(grep -c . "$home/.ssh/authorized_keys") 把公钥"
  id -nG "$u" | grep -qwE 'sudo|wheel' || { err "$u 没有 sudo 权限，禁 root 后会没法管理机器"; return 1; }
  local allow=""; yesno "是否只允许 $u 一个用户登录 SSH（AllowUsers）？" n && allow="AllowUsers $u"
  yesno "确认执行？" y || return 0
  put /etc/ssh/sshd_config.d/00-hardening.conf 644 <<EOF
# managed by vps-optimize.sh ($TS)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
$allow
EOF
  [ "$DRY" = 1 ] && return 0
  if ! sshd -t; then err "校验失败，已恢复原样"; rm -f /etc/ssh/sshd_config.d/00-hardening.conf; [ -f "$BK/etc/ssh/sshd_config.d/00-hardening.conf" ] && cp -a "$BK/etc/ssh/sshd_config.d/00-hardening.conf" /etc/ssh/sshd_config.d/; return 1; fi
  restart_ssh && sshd -T | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|x11forwarding|allowusers) ' | sed 's/^/  生效：/'
  warn "当前窗口别关；新开一个终端确认还能登录"
}

# 3 ------------------------------------------------------------------------
PORT_STATE=/var/lib/vps-optimize/ssh-port
port_rollback(){ # 恢复改端口之前的状态（也供定时器调用）
  [ -d "$PORT_STATE" ] || { err "没有改端口的记录"; return 1; }
  local old new f; old="$(cat "$PORT_STATE/old")"; new="$(cat "$PORT_STATE/new")"
  for f in "$PORT_STATE"/files/*; do case "$f" in *.path) continue ;; esac; [ -e "$f.path" ] && cp -a "$f" "$(cat "$f.path")"; done
  systemctl is-active --quiet fail2ban && systemctl restart fail2ban
  [ -f "$PORT_STATE/had_dropin" ] || rm -f /etc/ssh/sshd_config.d/00-port.conf
  [ -f "$PORT_STATE/had_sock" ] || rm -f /etc/systemd/system/ssh.socket.d/00-port.conf
  for p in $old; do fw_allow tcp "$p"; done
  case " $old " in *" $new "*) ;; *) fw_remove tcp "$new" ;; esac
  restart_ssh; systemctl stop vps-optimize-ssh-rollback.timer 2>/dev/null
  rm -rf "$PORT_STATE"; logger -t vps-optimize "ssh port rolled back to $old" 2>/dev/null
  ok "已回滚，当前 SSH 端口：$(ssh_ports)"
}
port_save(){ # 改端口前保存会动到的文件
  local f; mkdir -p "$PORT_STATE/files"; chmod 700 /var/lib/vps-optimize "$PORT_STATE" 2>/dev/null
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf /etc/fail2ban/jail.local /etc/systemd/system/ssh.socket.d/00-port.conf; do
    [ -f "$f" ] || continue; local n; n="$(echo "$f" | tr / _)"; cp -a "$f" "$PORT_STATE/files/$n"; echo "$f" >"$PORT_STATE/files/$n.path"; done
  [ -f /etc/ssh/sshd_config.d/00-port.conf ] && touch "$PORT_STATE/had_dropin"
  [ -f /etc/systemd/system/ssh.socket.d/00-port.conf ] && touch "$PORT_STATE/had_sock"
}
socket_ports(){ # socket 激活时确保这些端口都在监听
  ssh_socket || return 0
  local p miss=0; for p in "$@"; do listening "$p" || miss=1; done; [ $miss = 0 ] && return 0
  mkdir -p /etc/systemd/system/ssh.socket.d
  { echo "[Socket]"; echo "ListenStream="; for p in "$@"; do echo "ListenStream=$p"; done; } >/etc/systemd/system/ssh.socket.d/00-port.conf
  systemctl daemon-reload; systemctl restart ssh.socket
}
f2b_port(){ [ -f /etc/fail2ban/jail.local ] || return 0
  awk -v np="$1" '/^\[/{s=($0=="[sshd]")} s && /^[[:space:]]*port[[:space:]]*=/{print "port = " np; next} {print}' /etc/fail2ban/jail.local >/etc/fail2ban/jail.local.new && mv /etc/fail2ban/jail.local.new /etc/fail2ban/jail.local
  systemctl is-active --quiet fail2ban && systemctl restart fail2ban; true; }
t_sshport(){
  title "更换 SSH 端口"
  [ "$DRY" = 1 ] && { info "预演：将新旧端口双开 → 你测试新端口 → 再关旧端口；10 分钟内不确认自动回滚"; return 0; }
  [ -d "$PORT_STATE" ] && { warn "上次改端口还没收尾"; yesno "现在回滚上次的改动？" y && port_rollback; return 0; }
  local old new u ip
  old="$(ssh_ports)"; echo "当前端口：$old"
  new="$(ask "新端口（建议 10000–65000 之间的随机数）" "$(shuf -i 20000-60000 -n 1)")"
  [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || { err "端口无效"; return 1; }
  case " $old " in *" $new "*) err "和当前端口相同"; return 1 ;; esac
  listening "$new" && { err "端口 $new 已被占用"; return 1; }
  cloud_reminder tcp "$new"
  yesno "云厂商网页那层已经放行 $new 了吗？" n || { info "先去放行，再回来执行这一项"; return 0; }
  port_save; echo "$old" >"$PORT_STATE/old"; echo "$new" >"$PORT_STATE/new"
  { echo '#!/usr/bin/env bash'; echo "DRY=0; AUTO=0; PORT_STATE='$PORT_STATE'; BK='$BK'; C0=; CB=; CG=; CY=; CR=; CC=; exec 3>&1"
    declare -f info ok warn err run backup ssh_ports ssh_socket listening fw_type fw_allow fw_remove restart_ssh port_rollback
    echo 'port_rollback'; } >"$PORT_STATE/self.sh"; chmod 700 "$PORT_STATE/self.sh"
  bash -n "$PORT_STATE/self.sh" || { err "回滚脚本生成失败，已中止"; rm -rf "$PORT_STATE"; return 1; }
  systemd-run --unit=vps-optimize-ssh-rollback --on-active=10m --collect /bin/bash "$PORT_STATE/self.sh" >/dev/null
  ok "已挂自动回滚：10 分钟内不确认，就自动恢复原端口"
  fw_allow tcp "$new"
  { echo "# managed by vps-optimize.sh"; for p in $old; do echo "Port $p"; done; echo "Port $new"; } >/etc/ssh/sshd_config.d/00-port.conf
  restart_ssh || { port_rollback; return 1; }
  socket_ports $old "$new"; sleep 1
  listening "$new" || { err "新端口没在监听，立即回滚"; port_rollback; return 1; }
  [ -f /etc/fail2ban/jail.local ] && f2b_port "$(echo "$old $new" | tr ' ' ',')"
  u="$(admin_user)"; ip="$(pub_ip)"
  ok "现在新旧端口同时开着"
  echo; echo "${CB}请保持当前窗口不关，新开一个终端执行：${C0}  ssh -p $new $u@$ip"; echo
  if ! yesno "新端口能登录吗？" n; then port_rollback; return 1; fi
  systemctl stop vps-optimize-ssh-rollback.timer 2>/dev/null
  if ! yesno "关闭旧端口 $old？（建议关）" y; then ok "保持新旧端口都开着"; rm -rf "$PORT_STATE"; return 0; fi
  systemd-run --unit=vps-optimize-ssh-rollback --on-active=10m --collect /bin/bash "$PORT_STATE/self.sh" >/dev/null
  local f; for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ "$f" = /etc/ssh/sshd_config.d/00-port.conf ] && continue
    grep -qE '^[[:space:]]*Port[[:space:]]' "$f" 2>/dev/null && sed -i -E 's/^([[:space:]]*Port[[:space:]].*)$/# \1  # disabled by vps-optimize.sh/' "$f"; done
  printf '# managed by vps-optimize.sh\nPort %s\n' "$new" >/etc/ssh/sshd_config.d/00-port.conf
  [ -f /etc/systemd/system/ssh.socket.d/00-port.conf ] && printf '[Socket]\nListenStream=\nListenStream=%s\n' "$new" >/etc/systemd/system/ssh.socket.d/00-port.conf
  restart_ssh || { port_rollback; return 1; }
  socket_ports "$new"; sleep 1
  for p in $old; do fw_remove tcp "$p"; done
  f2b_port "$new"
  echo "${CB}再新开一个终端确认一次：${C0} ssh -p $new $u@$ip"
  if yesno "还能登录吗？" n; then systemctl stop vps-optimize-ssh-rollback.timer 2>/dev/null; rm -rf "$PORT_STATE"; ok "完成，SSH 端口：$(ssh_ports)"; warn "记得在云厂商网页删掉旧端口 $old 的规则（不删也不影响，系统层已拒绝）"
  else port_rollback; fi
}

# 4 ------------------------------------------------------------------------
t_ipv6fw(){
  title "IPv6 防火墙补齐"
  ip -6 addr show scope global 2>/dev/null | grep -q inet6 || { ok "这台机器没有公网 IPv6，不需要"; return 0; }
  [ "$(fw_type)" = ufw ] && { ok "UFW 已同时管理 IPv4 和 IPv6"; return 0; }
  ip6tables -S INPUT 2>/dev/null | grep -qE -- '-j (REJECT|DROP)|-P INPUT DROP' && { ok "IPv6 已有拦截规则"; return 0; }
  [ "$(fw_type)" = iptables-reject ] || { warn "IPv4 也没有默认拦截规则，这台机器可能根本没开系统防火墙；建议先用 UFW 或云安全组管理，再回来"; return 0; }
  local ports; ports="$(iptables -S INPUT | grep -oE -- '-p tcp .*--dport [0-9]+ .*-j ACCEPT' | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -un | tr '\n' ' ')"
  echo "检测到公网 IPv6，但 IPv6 没有任何拦截规则（等于全开）。"
  echo "将按 IPv4 现有放行写一份 /etc/iptables/rules.v6：只放行 TCP 端口 [ $ports]，以及 ICMPv6、DHCPv6、本地回环"
  yesno "确认执行？" y || return 0
  { echo "# managed by vps-optimize.sh ($TS) — mirror of rules.v4"
    echo "*filter"; echo ":INPUT ACCEPT [0:0]"; echo ":FORWARD ACCEPT [0:0]"; echo ":OUTPUT ACCEPT [0:0]"
    echo "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
    echo "-A INPUT -p ipv6-icmp -j ACCEPT"; echo "-A INPUT -i lo -j ACCEPT"
    echo "-A INPUT -s fe80::/10 -p udp -m udp --dport 546 -j ACCEPT"
    for p in $ports; do echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport $p -j ACCEPT"; done
    iptables -S INPUT | grep -oE -- '-p udp .*--dport [0-9]+' | grep -oE '[0-9]+$' | sort -un | while read -r p; do echo "-A INPUT -p udp -m udp --dport $p -j ACCEPT"; done
    echo "-A INPUT -j REJECT --reject-with icmp6-adm-prohibited"
    echo "-A FORWARD -j REJECT --reject-with icmp6-adm-prohibited"
    echo "COMMIT"; } | put /etc/iptables/rules.v6 640
  [ "$DRY" = 1 ] && return 0
  ip6tables-restore --test /etc/iptables/rules.v6 && ip6tables-restore /etc/iptables/rules.v6 && ok "已生效（开机自动加载）" || { err "规则校验失败，已恢复"; cp -a "$BK/etc/iptables/rules.v6" /etc/iptables/rules.v6 2>/dev/null; }
}

# 5 ------------------------------------------------------------------------
t_fail2ban(){
  title "安装 fail2ban（SSH 防爆破）"
  echo "规则：10 分钟内输错 5 次，封 1 小时。"
  if [ -f /etc/fail2ban/jail.local ]; then warn "已存在 /etc/fail2ban/jail.local（可能有你自己的规则）"; yesno "覆盖它？（原文件会备份）" n || return 0; fi
  local ign; ign="$(ask "永不封禁的 IP（你自己的固定 IP / 管理机，空格分隔，可留空）" "")"
  yesno "确认执行？" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null || { err "安装失败"; return 1; }
  local backend="systemd" logline="journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd"
  [ -f /var/log/auth.log ] && { backend="auto"; logline="logpath = %(sshd_log)s"; }
  systemctl list-unit-files ssh.service >/dev/null 2>&1 || logline="${logline/ssh.service/sshd.service}"
  put /etc/fail2ban/jail.local 644 <<EOF
# managed by vps-optimize.sh ($TS)
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 $ign

[sshd]
enabled = true
port = $(ssh_ports | tr ' ' ',')
backend = $backend
$logline
EOF
  [ "$DRY" = 1 ] && return 0
  systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban; sleep 3
  fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban 已运行：$(fail2ban-client status sshd | grep -E 'Journal matches|File list' | sed 's/.*:\s*//')" || err "fail2ban 没起来，查看：journalctl -u fail2ban -n 20"
}

# 6 ------------------------------------------------------------------------
t_services(){
  title "关闭用不上的服务"
  local s found=0
  for s in rpcbind cups cups-browsed avahi-daemon ModemManager; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 || continue
    systemctl is-active --quiet "$s" || systemctl is-active --quiet "$s.socket" 2>/dev/null || continue
    found=1
    case $s in rpcbind) d="NFS 端口映射，开着 111 端口，常被扫描（不用 NFS 就关）";; cups|cups-browsed) d="打印服务，服务器用不上";; avahi-daemon) d="局域网发现服务";; ModemManager) d="调制解调器管理";; esac
    if yesno "关闭 $s？（$d）" y; then run systemctl disable --now "$s.socket" "$s.service" >/dev/null 2>&1; run systemctl mask "$s.service" >/dev/null 2>&1; ok "已关闭 $s"; fi
  done
  snap list cups >/dev/null 2>&1 && yesno "关闭 snap 版 cups？" y && run snap stop --disable cups && found=1
  [ $found = 0 ] && ok "没发现常见的多余服务"
  is_oracle && info "甲骨文自带的 oracle-cloud-agent（控制台监控靠它）已保留，未改动"
}

# 7 ------------------------------------------------------------------------
t_update(){
  title "系统更新"
  apt-get update -qq || { err "更新软件源失败"; return 1; }
  local n; n="$(apt list --upgradable 2>/dev/null | grep -c upgradable)"; echo "可更新的软件包：$n 个"
  [ "$n" -gt 0 ] || { ok "已是最新"; return 0; }
  yesno "现在更新？（保留你改过的配置文件）" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  [ -f /var/run/reboot-required ] && warn "更新了内核等组件，需要重启才完全生效（自己挑时间执行：sudo reboot）" || ok "更新完成，不需要重启"
}

# 8 ------------------------------------------------------------------------
t_autoupdate(){
  title "自动安全更新"
  echo "每天自动装安全补丁；不会自动重启机器。"
  yesno "确认执行？" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
  put /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
  put /etc/apt/apt.conf.d/52vps-optimize-noreboot 644 <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  ok "已开启（只装安全更新，不自动重启）"
}

# 9 ------------------------------------------------------------------------
t_bbr(){
  title "开启 BBR 拥塞控制"
  modprobe tcp_bbr 2>/dev/null; grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || { err "内核不支持 BBR"; return 1; }
  echo "当前：$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  yesno "改为 bbr + fq？" y || return 0
  printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | put /etc/sysctl.d/90-vps-bbr.conf 644
  run sysctl --system >/dev/null; ok "当前：$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}

# 10 -----------------------------------------------------------------------
t_sysctl(){
  title "内核网络安全参数"
  echo "开启 SYN 防护、拒绝 ICMP 重定向和源路由、忽略广播 ping、地址随机化。"
  local rp=1; yesno "这台机器会做代理/转发/有多网卡吗？（是则用宽松的反向路径校验）" n && rp=2
  yesno "确认执行？" y || return 0
  put /etc/sysctl.d/91-vps-hardening.conf 644 <<EOF
# managed by vps-optimize.sh ($TS)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = $rp
net.ipv4.conf.default.rp_filter = $rp
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.randomize_va_space = 2
EOF
  run sysctl --system >/dev/null && ok "已生效"
}

# 11 -----------------------------------------------------------------------
t_swap(){
  title "创建 swap 交换空间"
  local cur; cur="$(swapon --show --noheadings 2>/dev/null)"
  [ -n "$cur" ] && { ok "已有 swap：$(echo "$cur" | awk '{print $1" "$3}')"; return 0; }
  local m s; m="$(mem_mb)"; if [ "$m" -le 1100 ]; then s=2; elif [ "$m" -le 4200 ]; then s=2; else s=1; fi
  s="$(ask "内存 ${m}MB，swap 大小（GB）" "$s")"; [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] || { err "大小无效"; return 1; }
  [ "$(df -BG --output=avail / | tail -1 | tr -dc 0-9)" -gt $((s + 2)) ] || { err "磁盘空间不足"; return 1; }
  yesno "创建 ${s}G 的 /swapfile 并开机自动挂载？" y || return 0
  run fallocate -l "${s}G" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count=$((s * 1024)) status=none
  run chmod 600 /swapfile; run mkswap /swapfile >/dev/null; run swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || { backup /etc/fstab; [ "$DRY" = 1 ] || echo '/swapfile none swap sw 0 0' >>/etc/fstab; }
  printf 'vm.swappiness = 10\n' | put /etc/sysctl.d/92-vps-swap.conf 644; run sysctl -q -p /etc/sysctl.d/92-vps-swap.conf
  ok "swap：$(swapon --show --noheadings | awk '{print $3}')，swappiness=$(sysctl -n vm.swappiness)"
}

# 12 -----------------------------------------------------------------------
t_timezone(){
  title "设置时区"
  echo "当前：$(timedatectl show -p Timezone --value)"
  local z; z="$(ask "新时区（如 Asia/Shanghai、Asia/Tokyo、UTC）" "Asia/Shanghai")"
  timedatectl list-timezones | grep -qx "$z" || { err "没有这个时区：$z"; return 1; }
  run timedatectl set-timezone "$z" && ok "时区：$(timedatectl show -p Timezone --value)"
}

# 13 -----------------------------------------------------------------------
t_hostname(){
  title "修改主机名"
  echo "当前：$(hostname)"
  local h; h="$(ask "新主机名（字母、数字、短横线）" "")"; [ -n "$h" ] || return 0
  [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { err "主机名格式不对"; return 1; }
  run hostnamectl set-hostname "$h"
  backup /etc/hosts; grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts && run sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $h/" /etc/hosts || { [ "$DRY" = 1 ] || echo "127.0.1.1 $h" >>/etc/hosts; }
  [ -d /etc/cloud/cloud.cfg.d ] && echo 'preserve_hostname: true' | put /etc/cloud/cloud.cfg.d/99-vps-optimize-hostname.cfg 644
  ok "主机名：$(hostname)（已防止云初始化重启后改回）"
}

# 14 -----------------------------------------------------------------------
t_journald(){
  title "限制系统日志占用"
  echo "当前日志占用：$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)"
  local s; s="$(ask "最多占用" "200M")"
  printf '[Journal]\nSystemMaxUse=%s\n' "$s" | put /etc/systemd/journald.conf.d/00-vps-optimize.conf 644
  run systemctl restart systemd-journald && ok "已限制为 $s"
}

# 15 -----------------------------------------------------------------------
t_dns(){
  title "加密 DNS（DNS over TLS）"
  systemctl is-active --quiet systemd-resolved || { err "系统没用 systemd-resolved，本项不适用"; return 1; }
  echo "把系统 DNS 改为加密查询（DNS over TLS），并让网卡下发的 DNS 不再作为默认出口。"
  echo "  1) Cloudflare + Google（海外业务，推荐）"
  echo "  2) Google + Cloudflare"
  echo "  3) 阿里 + 腾讯（业务主要面向国内）"
  local c d1 d2; c="$(ask "选择" "1")"
  case "$c" in
    2) d1="8.8.8.8#dns.google 8.8.4.4#dns.google"; d2="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com" ;;
    3) d1="223.5.5.5#dns.alidns.com 223.6.6.6#dns.alidns.com"; d2="1.12.12.12#dot.pub 120.53.53.53#dot.pub" ;;
    *) d1="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"; d2="8.8.8.8#dns.google 8.8.4.4#dns.google" ;;
  esac
  yesno "确认执行？" y || return 0
  put /etc/systemd/resolved.conf.d/dns-over-tls.conf 644 <<EOF
[Resolve]
DNS=$d1
FallbackDNS=$d2
DNSOverTLS=yes
DNSSEC=no
Domains=~.
EOF
  local ifc; ifc="$(ip route show default | awk '{print $5; exit}')"
  if [ -n "$ifc" ] && ls /run/systemd/network/*"$ifc"*.network >/dev/null 2>&1; then
    local nf; nf="$(basename "$(ls /run/systemd/network/*"$ifc"*.network | head -1)")"
    printf '[Network]\nDNSDefaultRoute=false\n' | put "/etc/systemd/network/$nf.d/90-vps-optimize-dns.conf" 644
    run resolvectl default-route "$ifc" false
  fi
  run systemctl restart systemd-resolved; sleep 2
  [ "$DRY" = 1 ] && return 0
  if resolvectl query example.com >/dev/null 2>&1; then ok "解析正常，已走加密通道：$(ss -Htn '( dport = :853 )' | awk '{print $4}' | head -1)"
  else err "解析失败，已恢复原配置"; rm -f /etc/systemd/resolved.conf.d/dns-over-tls.conf; [ -f "$BK/etc/systemd/resolved.conf.d/dns-over-tls.conf" ] && cp -a "$BK/etc/systemd/resolved.conf.d/dns-over-tls.conf" /etc/systemd/resolved.conf.d/; [ -n "$ifc" ] && resolvectl default-route "$ifc" true; systemctl restart systemd-resolved; fi
}

# 16 -----------------------------------------------------------------------
t_openport(){
  title "系统防火墙放行端口（给新装的服务用）"
  echo "防火墙类型：$(fw_type)"
  local proto p; proto="$(ask "协议 tcp / udp" "tcp")"; [[ "$proto" =~ ^(tcp|udp)$ ]] || { err "协议只能是 tcp 或 udp"; return 1; }
  p="$(ask "端口" "")"; [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { err "端口无效"; return 1; }
  yesno "放行 $proto/$p（IPv4 + IPv6）？" y || return 0
  fw_allow "$proto" "$p"; ok "系统防火墙已放行 $proto/$p"; cloud_reminder "$proto" "$p"
}

# 17 -----------------------------------------------------------------------
t_ipv4pref(){
  title "IPv4 优先"
  ip -6 route show default 2>/dev/null | grep -q . || { ok "这台机器没有 IPv6 默认路由，本来就只走 IPv4"; return 0; }
  echo "有些线路的 IPv6 会绕路，导致 apt / 下载莫名变慢。改为：同一个域名同时有 IPv4 和 IPv6 地址时，优先用 IPv4（IPv6 仍可用）。"
  yesno "确认执行？" y || return 0
  if grep -qE '^precedence ::ffff:0:0/96 +100' /etc/gai.conf 2>/dev/null; then ok "已经是 IPv4 优先"; return 0; fi
  backup /etc/gai.conf
  if [ "$DRY" = 1 ]; then echo "  [预演] /etc/gai.conf 加入 precedence ::ffff:0:0/96 100"
  elif grep -qE '^#\s*precedence ::ffff:0:0/96 +100' /etc/gai.conf 2>/dev/null; then sed -i -E 's/^#\s*(precedence ::ffff:0:0\/96 +100)/\1/' /etc/gai.conf
  else echo 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf; fi
  [ "$DRY" = 1 ] || ok "已改为 IPv4 优先（示例：$(getent ahosts www.google.com 2>/dev/null | awk 'NR==1{print $1}')）"
}

# 18 -----------------------------------------------------------------------
t_timesync(){
  title "时间自动同步"
  echo "当前：$(timedatectl show -p Timezone --value) · 已同步：$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    ok "chrony 正在运行（$(chronyc -n tracking 2>/dev/null | awk -F': ' '/Reference ID/{print $2}')）"; return 0; fi
  if systemctl is-active --quiet systemd-timesyncd; then ok "systemd-timesyncd 正在运行"; return 0; fi
  yesno "开启自动对时（systemd-timesyncd）？" y || return 0
  systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1 || run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd-timesyncd >/dev/null
  run timedatectl set-ntp true; sleep 3
  ok "自动对时已开启，已同步：$(timedatectl show -p NTPSynchronized --value)（刚开启时可能要等一两分钟才显示 yes）"
}

# 19 -----------------------------------------------------------------------
t_ufw(){
  title "最小化防火墙（UFW）"
  case "$(fw_type)" in
    iptables-reject) ok "这台机器已经用 iptables 默认拒绝（甲骨文镜像就是这样），不建议再装 UFW 混用；要放行端口请用第 16 项"; return 0 ;;
    nft) warn "检测到自定义 nftables 防火墙，不改动"; return 0 ;;
    ufw) ok "UFW 已启用："; ufw status | sed 's/^/  /'; return 0 ;;
  esac
  local sp extra p; sp="$(ssh_ports)"
  echo "将启用 UFW：默认拒绝所有外来连接，只放行 SSH 端口 [$sp] 和你指定的端口。"
  command -v docker >/dev/null && warn "装了 Docker：Docker 发布的端口会绕过 UFW，请把容器端口绑定到 127.0.0.1"
  extra="$(ask "另外要放行的端口（如 80,443 或 443/udp，逗号分隔，可留空）" "")"
  yesno "确认启用？（启用后 5 分钟内不确认会自动关闭 UFW，防止把自己锁在外面）" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null || { err "安装失败"; return 1; }
  for p in $sp; do run ufw allow "$p/tcp" comment SSH >/dev/null; done
  for p in ${extra//,/ }; do [[ "$p" =~ ^[0-9]+(/(tcp|udp))?$ ]] && run ufw allow "$p" >/dev/null || warn "跳过无效端口：$p"; done
  run ufw default deny incoming >/dev/null; run ufw default allow outgoing >/dev/null
  [ "$DRY" = 1 ] && { run ufw --force enable; return 0; }
  if command -v systemd-run >/dev/null && systemd-run --unit=vps-optimize-ufw-rollback --on-active=5m --collect /usr/sbin/ufw --force disable >/dev/null 2>&1; then :; else
    nohup sh -c 'sleep 300; [ -f /run/vps-optimize-ufw-ok ] || ufw --force disable' >/dev/null 2>&1 & fi
  ufw --force enable >/dev/null && ufw status | sed 's/^/  /'
  echo "${CB}保持当前窗口不关，新开一个终端执行 ssh 登录测试${C0}"
  if yesno "新窗口能登录吗？" n; then systemctl stop vps-optimize-ufw-rollback.timer 2>/dev/null; touch /run/vps-optimize-ufw-ok; ok "UFW 已启用并保留"; cloud_reminder tcp "$sp"
  else ufw --force disable >/dev/null; systemctl stop vps-optimize-ufw-rollback.timer 2>/dev/null; warn "已关闭 UFW（规则保留，查清原因后可再执行 ufw enable）"; fi
}

# 20 -----------------------------------------------------------------------
t_shortcut(){
  title "安装快捷命令 vpso"
  echo "安装后，以后在终端输入 ${CB}vpso${C0} 就能打开这个菜单（每次自动拉取最新版，联网失败时用本机缓存）。"
  yesno "确认安装？" y || return 0
  if [ -f "$SELF" ] && [ "$SELF" != /dev/stdin ] && [[ "$SELF" != /dev/fd/* && "$SELF" != /proc/* ]]; then run install -m 755 "$SELF" /usr/local/lib/vps-optimize.sh
  else run curl -fsSL "$RAW_URL" -o /usr/local/lib/vps-optimize.sh && run chmod 755 /usr/local/lib/vps-optimize.sh; fi
  put /usr/local/bin/vpso 755 <<EOF
#!/usr/bin/env bash
# vps-optimize 快捷命令：拉取最新版到缓存后运行；联网失败就用缓存
[ "\$(id -u)" -eq 0 ] || exec sudo "\$0" "\$@"
tmp="\$(mktemp)"
if curl -fsSL -m 15 "$RAW_URL" -o "\$tmp" && bash -n "\$tmp" 2>/dev/null; then install -m 755 "\$tmp" /usr/local/lib/vps-optimize.sh; fi
rm -f "\$tmp"
exec bash /usr/local/lib/vps-optimize.sh "\$@"
EOF
  ok "已安装：输入 vpso 打开菜单，vpso status 查看状态，vpso auto 一键优化"
}

t_auto(){
  title "一键推荐优化"
  echo "将依次执行：系统更新、自动安全更新、BBR、内核安全参数、swap、时区、时间同步、日志上限、IPv4 优先、关闭多余服务、fail2ban、IPv6 防火墙。"
  echo "全部用推荐默认值；SSH 加固和改端口有锁死风险，不在其中，请单独执行第 2、3 项。"
  AUTO=0 yesno "开始？" y || return 0
  local t okc=0 bad=""
  AUTO=1
  local n
  for t in "${AUTO_SET[@]}"; do
    for n in "${!TASKS[@]}"; do [ "${TASKS[$n]}" = "$t" ] && break; done
    if done_mark "$t"; then ok "第 $n 项「${NAMES[$n]}」已是优化状态，跳过（保留你现有的配置）"; okc=$((okc+1)); continue; fi
    "$t" && okc=$((okc+1)) || bad="$bad $n"
  done
  AUTO=0
  title "一键推荐优化完成：成功 $okc 项${bad:+，未完成：$bad}"
  [ -f /var/run/reboot-required ] && warn "有更新需要重启才生效，方便时执行：reboot"
  info "建议接着手动做：1 添加公钥 → 2 SSH 加固 → 3 改端口"
}

# =============================================================================
#  菜单
# =============================================================================
menu(){
  while true; do
    echo; hr; echo "${CB} 新 VPS 初始化与优化  v$VERSION${C0}   $( [ "$DRY" = 1 ] && echo "${CY}[预演模式]${C0}")"
    echo "  $(hostname) · $(. /etc/os-release; echo "$PRETTY_NAME") · $(is_oracle && echo 甲骨文云 || echo "$(uname -m)")"; hr
    local i; for i in "${!TASKS[@]}"; do
      local m="  "; [ "$i" -gt 0 ] && { done_mark "${TASKS[$i]}" && m="${CG}✅${C0}" || m="⬜"; }
      printf " %s %2d. %s\n" "$m" "$i" "${NAMES[$i]}"
    done
    hr; echo "  ${CB}a. 一键推荐优化${C0}（一路回车，不含 SSH 加固/改端口）"
    echo " 建议：先 a，再 1 → 2 → 3；输入多个编号用空格隔开，q 退出"
    local sel; read -r -p "选择: " sel </dev/tty || exit 0
    [[ "$sel" =~ ^[qQ] ]] && exit 0
    [[ "$sel" =~ ^[aA]$ ]] && { t_auto; read -r -p "按回车返回菜单…" _ </dev/tty || true; continue; }
    for i in $sel; do
      [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "${#TASKS[@]}" ] || { warn "没有第 $i 项"; continue; }
      "${TASKS[$i]}" || warn "第 $i 项没有完成"
    done
    read -r -p "按回车返回菜单…" _ </dev/tty || true
  done
}

case "${1:-}" in
  -h|--help|help) sed -n '2,18p' "$SELF" 2>/dev/null || echo "用法：vps-optimize.sh [status|list|auto|编号…]"; exit 0 ;;
esac
need_root "$@"; os_check
case "${1:-}" in
  "") menu ;;
  status) t_status ;;
  list) for i in "${!TASKS[@]}"; do printf "%2d. %s\n" "$i" "${NAMES[$i]}"; done; echo " a. 一键推荐优化" ;;
  auto|a) t_auto ;;
  *) for i in "$@"; do if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "${#TASKS[@]}" ]; then "${TASKS[$i]}" || warn "第 $i 项没有完成"; else err "没有第 $i 项"; fi; done ;;
esac
