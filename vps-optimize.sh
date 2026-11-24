#!/usr/bin/env bash
# =============================================================================
#  vps-optimize.sh —— 新 VPS 初始化与优化工具（逐项可选、每步可回滚）
#  适用：Ubuntu 22.04 / 24.04、Debian 12（含甲骨文云 Oracle Cloud 镜像的特殊处理）
#
#  一键运行：bash <(curl -fsSL https://raw.githubusercontent.com/insffxx/vps-optimize/main/vps-optimize.sh)
#  用法：
#    sudo bash vps-optimize.sh              打开菜单，自己挑要做的项（可输入多个编号，如 3 5 9）
#    sudo bash vps-optimize.sh auto         一键推荐优化（一路回车即可，不含 SSH 加固/改端口）
#    sudo bash vps-optimize.sh uninstall    卸载本工具（可选同时撤销所有改动）
#    装好快捷命令后，直接输入 ins 启动
#    sudo bash vps-optimize.sh 9            直接执行第 9 项
#    sudo bash vps-optimize.sh status       只看当前状态，不改任何东西
#    sudo DRY_RUN=1 bash vps-optimize.sh    预演模式：只打印将要做的改动，不真正执行
#
#  原则：每项都先说明要改什么 → 你确认 → 备份原文件 → 修改 → 校验。
#        改过的文件都备份在 /var/backups/vps-optimize/<时间>/ 下。
#  License: MIT
# =============================================================================
set -uo pipefail

VD_VERSION="1.2.0"
SHORTCUT="ins"
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
  [ -e "$f" ] || { mkdir -p "$BK"; echo "$f" >>"$BK/.created"; }
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
TASKS=(t_status t_sshkey t_sshharden t_sshport t_ipv6fw t_fail2ban t_services t_update t_autoupdate t_bbr t_sysctl t_swap t_timezone t_hostname t_journald t_dns t_openport t_ipv4pref t_timesync t_ufw t_shortcut t_clean t_nettune t_newuser t_tools t_ports t_restore t_mirror t_traffic)
NAMES=("查看当前状态（只读）" "添加 SSH 公钥" "SSH 加固（禁 root / 禁密码 / 限次数）" "更换 SSH 端口（带自动回滚）" "IPv6 防火墙补齐" "安装 fail2ban 防爆破" "关闭用不上的服务" "系统更新" "自动安全更新" "开启 BBR 加速" "内核网络安全参数" "创建 swap 交换空间" "设置时区" "修改主机名" "限制日志占用" "加密 DNS（DoT）" "系统防火墙放行端口" "IPv4 优先" "时间自动同步" "最小化防火墙（UFW）" "安装快捷命令 ins" "系统清理" "网络性能调优（按内存自动）" "新建 sudo 用户" "安装常用工具 / Docker" "查看端口占用" "恢复备份（撤销改动）" "切换软件源（国内机器）" "流量超额自动关机")
AUTO_SET=(t_update t_autoupdate t_bbr t_sysctl t_swap t_timezone t_timesync t_journald t_ipv4pref t_services t_fail2ban t_ipv6fw t_clean)

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
    t_shortcut) [ -x "/usr/local/bin/$SHORTCUT" ] ;;
    t_nettune) [ -f /etc/sysctl.d/93-vps-nettune.conf ] ;;
    t_newuser) [ -n "$(admin_user)" ] && id -nG "$(admin_user)" 2>/dev/null | grep -qwE 'sudo|wheel' ;;
    t_tools) command -v htop >/dev/null && command -v vim >/dev/null && command -v unzip >/dev/null ;;
    t_mirror) grep -rqsE 'mirrors\.(aliyun|tuna\.tsinghua|ustc)' /etc/apt/sources.list /etc/apt/sources.list.d/ ;;
    t_traffic) [ -f /etc/vps-optimize/traffic.conf ] ;;
    t_status|t_clean|t_ports|t_restore|t_openport) return 2 ;;
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
  title "安装快捷命令 $SHORTCUT"
  echo "安装后，以后在终端输入 ${CB}$SHORTCUT${C0} 就能打开这个菜单（每次自动拉取最新版，联网失败时用本机缓存）。"
  if command -v "$SHORTCUT" >/dev/null && [ ! -f "/usr/local/bin/$SHORTCUT" ]; then err "系统里已有别的程序叫 $SHORTCUT（$(command -v "$SHORTCUT")），为避免冲突不安装"; return 1; fi
  yesno "确认安装？" y || return 0
  if [ -f "$SELF" ] && [ "$SELF" != /dev/stdin ] && [[ "$SELF" != /dev/fd/* && "$SELF" != /proc/* ]]; then run install -m 755 "$SELF" /usr/local/lib/vps-optimize.sh
  else run curl -fsSL "$RAW_URL" -o /usr/local/lib/vps-optimize.sh && run chmod 755 /usr/local/lib/vps-optimize.sh; fi
  rm -f /usr/local/bin/vpso /usr/local/bin/vd
  put "/usr/local/bin/$SHORTCUT" 755 <<EOF
#!/usr/bin/env bash
# Vernal Dawn VPS 工具箱 快捷命令：拉取最新版到缓存后运行；联网失败就用缓存
[ "\$(id -u)" -eq 0 ] || exec sudo "\$0" "\$@"
tmp="\$(mktemp)"
if [ "\${INS_NO_UPDATE:-0}" != 1 ] && curl -fsSL -m 15 "$RAW_URL" -o "\$tmp" && bash -n "\$tmp" 2>/dev/null && grep -q 'VD_VERSION=' "\$tmp"; then install -m 755 "\$tmp" /usr/local/lib/vps-optimize.sh; fi
rm -f "\$tmp"
exec bash /usr/local/lib/vps-optimize.sh "\$@"
EOF
  ok "已安装：输入 $SHORTCUT 打开菜单，$SHORTCUT status 查看状态，$SHORTCUT auto 一键优化"
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

# 21 -----------------------------------------------------------------------
t_clean(){
  title "系统清理"
  local before after; before="$(df -BM --output=used / | tail -1 | tr -dc 0-9)"
  echo "将清理：软件包缓存、不再需要的依赖和旧内核、超出上限的系统日志、snap 旧版本。"
  echo "（不会删除你的文件和正在用的日志）"
  yesno "确认执行？" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq >/dev/null
  run apt-get clean
  local jl; jl="$(sed -n 's/^SystemMaxUse=//p' /etc/systemd/journald.conf.d/*.conf /etc/systemd/journald.conf 2>/dev/null | head -1)"
  run journalctl --vacuum-size="${jl:-500M}" >/dev/null 2>&1
  if command -v snap >/dev/null; then
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r n r; do run snap remove "$n" --revision="$r" >/dev/null 2>&1; done
  fi
  find /tmp /var/tmp -xdev -type f -atime +10 -delete 2>/dev/null
  after="$(df -BM --output=used / | tail -1 | tr -dc 0-9)"
  ok "清理完成，释放约 $(( before > after ? before - after : 0 )) MB；磁盘(/)：$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
}

# 22 -----------------------------------------------------------------------
t_nettune(){
  title "网络性能调优（按内存自动）"
  local f=/etc/sysctl.d/93-vps-nettune.conf
  if [ -f "$f" ]; then
    echo "已调优过。 1) 重新按当前内存调优   2) 删除调优，恢复系统默认"
    local c; c="$(ask "选择" "1")"
    if [ "$c" = 2 ]; then
      backup "$f" /etc/security/limits.d/90-vps-optimize.conf /etc/systemd/system.conf.d/90-vps-optimize.conf
      run rm -f "$f" /etc/security/limits.d/90-vps-optimize.conf /etc/systemd/system.conf.d/90-vps-optimize.conf
      run sysctl --system >/dev/null; ok "已删除调优配置（部分参数要重启后才完全回到默认值）"; return 0
    fi
  fi
  local m buf somax backlog syn cur_r cur_w buf_r buf_w; m="$(mem_mb)"
  if   [ "$m" -le 1100 ];  then buf=8388608;  somax=1024; backlog=4096;  syn=2048
  elif [ "$m" -le 4200 ];  then buf=16777216; somax=4096; backlog=16384; syn=8192
  elif [ "$m" -le 16500 ]; then buf=33554432; somax=8192; backlog=32768; syn=16384
  else                          buf=67108864; somax=8192; backlog=65536; syn=16384; fi
  cur_r="$(sysctl -n net.core.rmem_max)"; cur_w="$(sysctl -n net.core.wmem_max)"
  [ "$cur_r" -gt "$buf" ] && buf_r="$cur_r" || buf_r="$buf"
  [ "$cur_w" -gt "$buf" ] && buf_w="$cur_w" || buf_w="$buf"
  echo "内存 ${m}MB → 收发缓冲最大 $((buf/1048576))MB、连接队列 $somax、最大打开文件数 1048576"
  echo "（已有更大的设置会保留，不会调小；适合网站、代理、高并发服务）"
  yesno "确认执行？" y || return 0
  put "$f" 644 <<EOF
# managed by vps-optimize.sh ($TS) — 按内存 ${m}MB 自动生成
net.core.rmem_max = $buf_r
net.core.wmem_max = $buf_w
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 $buf
net.ipv4.tcp_wmem = 4096 65536 $buf
net.core.somaxconn = $somax
net.core.netdev_max_backlog = $backlog
net.ipv4.tcp_max_syn_backlog = $syn
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
EOF
  printf '# managed by vps-optimize.sh\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' | put /etc/security/limits.d/90-vps-optimize.conf 644
  printf '[Manager]\nDefaultLimitNOFILE=1048576\n' | put /etc/systemd/system.conf.d/90-vps-optimize.conf 644
  run sysctl --system >/dev/null && run systemctl daemon-reload
  [ "$DRY" = 1 ] || ok "已生效：rmem_max=$(sysctl -n net.core.rmem_max) somaxconn=$(sysctl -n net.core.somaxconn)（文件数上限对新登录和新启动的服务生效，重启后全部生效）"
}

# 23 -----------------------------------------------------------------------
t_newuser(){
  title "新建 sudo 用户"
  echo "很多 VPS 只给 root 账号。建一个能用 sudo 的普通账号，之后才能安全地禁用 root 登录（第 2 项）。"
  local u; u="$(ask "新用户名（小写字母开头，可含数字、下划线、短横线）" "")"; [ -n "$u" ] || return 0
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "用户名格式不对"; return 1; }
  local grp=sudo; getent group sudo >/dev/null || grp=wheel
  if id "$u" >/dev/null 2>&1; then warn "用户 $u 已存在"; yesno "把它加入 $grp 组？" y && run usermod -aG "$grp" "$u"
  else yesno "创建用户 $u 并加入 $grp 组？" y || return 0; run useradd -m -s /bin/bash -G "$grp" "$u"; fi
  local home; home="$(getent passwd "$u" | cut -d: -f6)"
  if [ -s /root/.ssh/authorized_keys ] && yesno "把 root 现有的 SSH 公钥复制给 $u（这样能用同一把密钥登录）？" y; then
    run install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
    if [ "$DRY" != 1 ]; then cat /root/.ssh/authorized_keys >>"$home/.ssh/authorized_keys"; sort -u -o "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys"; chown "$u:$u" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"; fi
    ok "已复制 $(grep -c . /root/.ssh/authorized_keys) 把公钥"
  fi
  echo "sudo 时是否需要输入密码？"
  echo "  1) 需要（更安全，接下来给 $u 设置密码）   2) 不需要（只能用密钥登录的机器上比较方便）"
  if [ "$(ask "选择" "1")" = 2 ]; then
    echo "$u ALL=(ALL) NOPASSWD:ALL" | put "/etc/sudoers.d/90-$u" 440
    [ "$DRY" = 1 ] || visudo -cf "/etc/sudoers.d/90-$u" >/dev/null || { err "sudoers 校验失败，已删除"; rm -f "/etc/sudoers.d/90-$u"; return 1; }
  else
    [ "$DRY" = 1 ] || { echo "给 $u 设置密码："; passwd "$u" </dev/tty || warn "密码没设置成功，可稍后执行：passwd $u"; }
  fi
  ok "用户 $u 已就绪。先别关当前窗口，新开一个终端执行：ssh $u@$(pub_ip)，再试 sudo -v"
}

# 24 -----------------------------------------------------------------------
t_tools(){
  title "安装常用工具"
  local base="curl wget sudo vim nano htop unzip zip tar socat jq lsof git ca-certificates mtr-tiny dnsutils net-tools rsync tmux"
  echo "将安装：$base"
  yesno "确认安装？" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $base >/dev/null 2>&1; then
    local p; for p in $base; do run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1 || warn "跳过 $p（软件源里没有）"; done
  fi
  ok "常用工具已安装"
  if command -v docker >/dev/null; then ok "Docker 已安装：$(docker --version 2>/dev/null)"; return 0; fi
  if yesno "同时安装 Docker（用系统软件源里的 docker.io，不运行第三方脚本）？" n; then
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null || { err "Docker 安装失败"; return 1; }
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose >/dev/null 2>&1 || true
    run systemctl enable --now docker >/dev/null 2>&1
    ok "Docker：$(docker --version 2>/dev/null)"
    warn "注意：Docker 发布的端口会绕过 UFW；只想本机访问的服务，端口请写成 127.0.0.1:端口:端口"
  fi
}

# 25 -----------------------------------------------------------------------
t_ports(){
  title "端口占用（只读）"
  printf "  %-5s %-7s %-26s %-18s %s\n" "协议" "端口" "监听地址" "程序" "范围"
  ss -Htulnp 2>/dev/null | awk '{
      addr=$5; n=split(addr,a,":"); port=a[n]; host=substr(addr,1,length(addr)-length(port)-1)
      prog="-"; if (match($0,/users:\(\("[^"]+"/)) { prog=substr($0,RSTART+9,RLENGTH-10) }
      scope=(host ~ /^(127\.|\[::1\]|\[?fe80)/ || host ~ /%lo/) ? "仅本机" : "对外"
      printf "  %-5s %-7s %-26s %-18s %s\n", $1, port, host, prog, scope }' | sort -k5,5r -k2,2n | uniq
  echo
  info "「对外」只表示程序在监听公网地址，外面能不能连上还取决于防火墙（类型：$(fw_type)）和云厂商安全组"
}

# 26 -----------------------------------------------------------------------
restore_dir(){ # restore_dir <备份目录>：把该次备份的文件还原，并删除那次新建的文件
  local d="$1" f t touched=""
  while IFS= read -r -d '' f; do
    t="${f#"$d"}"; touched="$touched $t"; backup "$t"; run cp -a "$f" "$t"
  done < <(find "$d" -type f ! -name .created -print0)
  if [ -f "$d/.created" ]; then
    while IFS= read -r t; do [ -e "$t" ] || continue; touched="$touched $t"; backup "$t"; run rm -f "$t"; done <"$d/.created"
  fi
  echo "$touched"
}
reload_after_restore(){ # 根据还原过的文件，重新加载对应服务
  local list="$1"
  case "$list" in *"/etc/ssh/"*)
    if sshd -t; then restart_ssh; else err "还原后 sshd 配置校验失败，已撤回这次还原的 SSH 文件"; restore_dir "$BK" >/dev/null; restart_ssh; fi ;; esac
  case "$list" in *"/etc/sysctl.d/"*|*"/etc/security/limits"*) run sysctl --system >/dev/null ;; esac
  case "$list" in *"/etc/iptables/rules.v4"*) [ -f /etc/iptables/rules.v4 ] && run iptables-restore </etc/iptables/rules.v4 ;; esac
  case "$list" in *"/etc/iptables/rules.v6"*) [ -f /etc/iptables/rules.v6 ] && run ip6tables-restore </etc/iptables/rules.v6 ;; esac
  case "$list" in *"/etc/fail2ban/"*) systemctl is-active --quiet fail2ban && run systemctl restart fail2ban ;; esac
  case "$list" in *"/etc/systemd/resolved"*|*"/etc/systemd/network/"*) run systemctl restart systemd-resolved ;; esac
  case "$list" in *"/etc/systemd/journald"*) run systemctl restart systemd-journald ;; esac
  case "$list" in *"/etc/cron.d/"*) : ;; esac
  run systemctl daemon-reload
}
t_restore(){
  title "恢复备份（撤销某一次改动）"
  local root=/var/backups/vps-optimize d i=0; local -a dirs=()
  for d in "$root"/*/; do [ -d "$d" ] && [ "${d%/}" != "$BK" ] && dirs+=("${d%/}"); done
  [ ${#dirs[@]} -gt 0 ] || { ok "还没有任何备份"; return 0; }
  for d in "${dirs[@]}"; do
    i=$((i+1)); printf "  %2d) %s  改了 %s 个文件%s\n" "$i" "$(basename "$d")" "$(find "$d" -type f ! -name .created | wc -l)" "$( [ -f "$d/.created" ] && echo "，新建了 $(grep -c . "$d/.created") 个")"
  done
  local n; n="$(ask "恢复哪一次（编号）" "")"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#dirs[@]} ] || return 0
  d="${dirs[$((n-1))]}"
  echo "将还原这些文件："; find "$d" -type f ! -name .created | sed "s#^$d#    #"
  [ -f "$d/.created" ] && { echo "将删除那次新建的文件："; sed 's/^/    /' "$d/.created"; }
  find "$d" -path '*/etc/ssh/*' -o -name authorized_keys | grep -q . && warn "包含 SSH 相关文件：还原后 SSH 端口或登录方式可能变回旧的，请保持当前窗口不关"
  yesno "确认还原？（当前状态会先备份，可以再撤回）" n || return 0
  local touched; touched="$(restore_dir "$d")"
  reload_after_restore "$touched"
  ok "已还原到 $(basename "$d") 之前的状态；还原前的状态备份在 $BK"
  [[ "$touched" == *"/etc/ssh/"* ]] && warn "当前 SSH 端口：$(ssh_ports)，请新开终端确认能登录"
}

# 27 -----------------------------------------------------------------------
t_mirror(){
  title "切换软件源"
  local files f n orig=/var/lib/vps-optimize/apt-original
  files="$(grep -lsE 'ubuntu\.com|debian\.org|mirrors\.(aliyun|tuna|ustc)' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list)"
  [ -n "$files" ] || { err "没找到官方软件源配置"; return 1; }
  echo "当前源：$(grep -hoE 'https?://[^ /]+' $files | sort -u | tr '\n' ' ')"
  echo "  1) 阿里云   2) 清华大学   3) 中科大   4) 恢复成本机原来的源"
  info "只建议国内机器换；海外机器用默认源通常更快"
  local c host; c="$(ask "选择" "1")"
  case "$c" in 1) host=mirrors.aliyun.com ;; 2) host=mirrors.tuna.tsinghua.edu.cn ;; 3) host=mirrors.ustc.edu.cn ;;
    4) [ -d "$orig" ] || { err "没有保存过原来的源"; return 1; }
       for f in "$orig"/*; do backup "$(cat "$f.path" 2>/dev/null)"; done 2>/dev/null
       for f in "$orig"/*; do case "$f" in *.path) continue ;; esac; run cp -a "$f" "$(cat "$f.path")"; done
       run apt-get update -qq && ok "已恢复原来的源"; return 0 ;;
    *) return 0 ;; esac
  yesno "切换到 $host？" y || return 0
  if [ ! -d "$orig" ] && [ "$DRY" != 1 ]; then mkdir -p "$orig"; for f in $files; do n="$(echo "$f" | tr / _)"; cp -a "$f" "$orig/$n"; echo "$f" >"$orig/$n.path"; done; fi
  for f in $files; do
    backup "$f"
    run sed -i -E "s#https?://[a-zA-Z0-9.-]*(ubuntu\.com|debian\.org|mirrors\.aliyun\.com|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn)/(ubuntu-ports|ubuntu|debian-security|debian)([/ ]|\$)#https://$host/\2\3#g" "$f"
  done
  [ "$DRY" = 1 ] && return 0
  if apt-get update -qq 2>/dev/null; then ok "已切换到 $host，软件源可用"
  else err "新源不可用，已恢复"; for f in $files; do cp -a "$BK$f" "$f"; done; apt-get update -qq; fi
}

# 28 -----------------------------------------------------------------------
t_traffic(){
  title "流量超额自动关机"
  local conf=/etc/vps-optimize/traffic.conf guard=/usr/local/sbin/vps-traffic-guard cron=/etc/cron.d/vps-optimize-traffic
  if [ -f "$conf" ]; then
    echo "当前设置：$(tr '\n' ' ' <"$conf")"
    command -v vnstat >/dev/null && vnstat --oneline b 2>/dev/null | awk -F';' '{printf "本月已用：入 %.2f GB  出 %.2f GB  合计 %.2f GB\n",$9/1073741824,$10/1073741824,$11/1073741824}'
    echo "  1) 修改设置   2) 关闭流量限制"
    if [ "$(ask "选择" "1")" = 2 ]; then backup "$conf" "$guard" "$cron"; run rm -f "$conf" "$guard" "$cron"; ok "已关闭（vnstat 统计保留）"; return 0; fi
  fi
  echo "用 vnstat 统计本月流量，超过你设的额度就自动关机，防止超额扣费；到 90% 时先在系统日志和登录终端里提醒。"
  local ifc lim mode act day
  ifc="$(ask "统计哪块网卡" "$(ip route show default | awk '{print $5; exit}')")"
  lim="$(ask "每月额度（GB）" "1000")"; [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -gt 0 ] || { err "额度无效"; return 1; }
  echo "怎么算流量：1) 只算出站（多数厂商这样计费）  2) 进出合计"
  mode="$(ask "选择" "1")"; [ "$mode" = 2 ] && mode=total || mode=tx
  echo "超额后：1) 自动关机  2) 只提醒不关机"
  act="$(ask "选择" "1")"; [ "$act" = 2 ] && act=warn || act=poweroff
  day="$(ask "每月几号重新计数（账单日，1–28）" "1")"; [[ "$day" =~ ^[0-9]+$ ]] && [ "$day" -ge 1 ] && [ "$day" -le 28 ] || day=1
  yesno "确认：$ifc 每月 ${lim}GB（$( [ $mode = tx ] && echo 出站 || echo 进出合计)），超额$( [ $act = poweroff ] && echo 自动关机 || echo 只提醒)，每月 $day 号重新计数？" y || return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vnstat >/dev/null || { err "vnstat 安装失败"; return 1; }
  if [ -f /etc/vnstat.conf ]; then backup /etc/vnstat.conf; run sed -i -E "s/^;?\s*MonthRotate\s+.*/MonthRotate $day/" /etc/vnstat.conf; fi
  run systemctl enable --now vnstat >/dev/null 2>&1; run systemctl restart vnstat
  run vnstat --add -i "$ifc" >/dev/null 2>&1 || true
  printf 'IFACE=%s\nLIMIT_GB=%s\nMODE=%s\nACTION=%s\n' "$ifc" "$lim" "$mode" "$act" | put "$conf" 644
  put "$guard" 755 <<'EOF'
#!/usr/bin/env bash
# 流量守卫（vps-optimize.sh 生成）：每 5 分钟检查本月流量
. /etc/vps-optimize/traffic.conf || exit 0
line="$(vnstat --oneline b -i "$IFACE" 2>/dev/null)" || exit 0
IFS=';' read -r -a f <<<"$line"
used=${f[9]:-0}; [ "$MODE" = total ] && used=${f[10]:-0}
limit=$(( LIMIT_GB * 1073741824 ))
[ "$used" -gt 0 ] 2>/dev/null || exit 0
pct=$(( used * 100 / limit ))
flag=/run/vps-traffic-warned
if [ "$pct" -ge 100 ]; then
  msg="本月流量已用 ${pct}%（额度 ${LIMIT_GB}GB）"
  logger -t vps-traffic-guard "$msg，动作：$ACTION"
  if [ "$ACTION" = poweroff ]; then wall "$msg，1 分钟后自动关机" 2>/dev/null; sleep 60; systemctl poweroff; fi
elif [ "$pct" -ge 90 ] && [ ! -f "$flag" ]; then
  logger -t vps-traffic-guard "本月流量已用 ${pct}%（额度 ${LIMIT_GB}GB）"; wall "提醒：本月流量已用 ${pct}%（额度 ${LIMIT_GB}GB）" 2>/dev/null; touch "$flag"
fi
EOF
  echo '*/5 * * * * root /usr/local/sbin/vps-traffic-guard' | put "$cron" 644
  ok "已开启。注意：vnstat 从现在开始统计，本月之前用掉的流量不会计入"
  info "查看本月用量：vnstat -m    关闭：再次执行本项选 2"
}

# 卸载 ---------------------------------------------------------------------
t_uninstall(){
  title "卸载本工具"
  echo "  1) 只卸载工具（快捷命令 $SHORTCUT、缓存、流量守卫），保留所有优化效果"
  echo "  2) 卸载工具，并撤销本工具做过的所有改动（把每个改过的文件还原成第一次修改前的样子）"
  local c; c="$(ask "选择" "1")"; [[ "$c" =~ ^[12]$ ]] || return 0
  if [ "$c" = 2 ]; then
    warn "会还原 SSH 配置（端口、登录方式可能变回最初的样子）、防火墙、DNS、内核参数等；装过的软件（fail2ban、ufw、docker 等）不会卸载"
    warn "如果改过 SSH 端口，还原后会回到原来的端口，请确认云厂商网页那层也放行了它"
    yesno "确认撤销所有改动？" n || return 0
    local root=/var/backups/vps-optimize d all="" seen="|" f t
    # 从最早的备份开始：每个文件只用它第一次出现的那份（即最原始的版本）
    while IFS= read -r d; do
      [ "$d" = "$BK" ] && continue
      while IFS= read -r -d '' f; do
        t="${f#"$d"}"; case "$seen" in *"|$t|"*) continue ;; esac; seen="$seen$t|"
        backup "$t"; run cp -a "$f" "$t"; all="$all $t"
      done < <(find "$d" -type f ! -name .created -print0)
      if [ -f "$d/.created" ]; then
        while IFS= read -r t; do case "$seen" in *"|$t|"*) continue ;; esac; seen="$seen$t|"; [ -e "$t" ] && { backup "$t"; run rm -f "$t"; all="$all $t"; }; done <"$d/.created"
      fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    reload_after_restore "$all"
    ok "已撤销所有改动；SSH 端口：$(ssh_ports)。建议方便时重启一次，让所有参数完全回到默认"
  fi
  local conf=/etc/vps-optimize/traffic.conf
  run rm -f "/usr/local/bin/$SHORTCUT" /usr/local/bin/vpso /usr/local/bin/vd /usr/local/lib/vps-optimize.sh /usr/local/sbin/vps-traffic-guard /etc/cron.d/vps-optimize-traffic "$conf"
  run rm -rf /var/lib/vps-optimize /etc/vps-optimize
  systemctl stop vps-optimize-ssh-rollback.timer vps-optimize-ufw-rollback.timer 2>/dev/null
  if yesno "同时删除备份目录 /var/backups/vps-optimize？（删了就无法再撤销）" n; then run rm -rf /var/backups/vps-optimize; fi
  ok "已卸载。想再用时执行：bash <(curl -fsSL $RAW_URL)"
  [ "$DRY" = 1 ] || exit 0
}

# =============================================================================
#  菜单
# =============================================================================
banner(){
  clear 2>/dev/null || true
  echo "${CC}"
  cat <<'ART'
 _    ____________  _   _____    __    ____  ___ _       ___   __
| |  / / ____/ __ \/ | / /   |  / /   / __ \/   | |     / / | / /
| | / / __/ / /_/ /  |/ / /| | / /   / / / / /| | | /| / /  |/ /
| |/ / /___/ _, _/ /|  / ___ |/ /___/ /_/ / ___ | |/ |/ / /|  /
|___/_____/_/ |_/_/ |_/_/  |_/_____/_____/_/  |_|__/|__/_/ |_/
ART
  echo "${C0}${CB}Vernal Dawn VPS 工具箱 v$VD_VERSION${C0}   $( [ "$DRY" = 1 ] && echo "${CY}[预演模式]${C0}")"
  if [ -x "/usr/local/bin/$SHORTCUT" ]; then echo "命令行输入 ${CY}$SHORTCUT${C0} 快速启动脚本"
  else echo "选 ${CY}20${C0} 安装快捷命令，以后输入 ${CY}$SHORTCUT${C0} 就能启动"; fi
}
menu(){
  if [ ! -x "/usr/local/bin/$SHORTCUT" ] && [ ! -f /var/lib/vps-optimize/no-shortcut ] && [ "$DRY" != 1 ]; then
    banner
    if yesno "安装快捷命令 $SHORTCUT（以后输入 $SHORTCUT 就能打开本菜单）？" y; then t_shortcut; else mkdir -p /var/lib/vps-optimize; touch /var/lib/vps-optimize/no-shortcut; fi
  fi
  while true; do
    banner; hr
    echo "  $(hostname) · $(. /etc/os-release; echo "$PRETTY_NAME") · $(is_oracle && echo 甲骨文云 || echo "$(uname -m)")"; hr
    local i; for i in "${!TASKS[@]}"; do
      [ "$i" = 0 ] && { printf "    %2s. %s\n" "s" "${NAMES[0]}"; continue; }
      local m="  " rc; done_mark "${TASKS[$i]}"; rc=$?; [ $rc = 0 ] && m="${CG}✅${C0}"; [ $rc = 1 ] && m="⬜"
      printf " %s %2d. %s\n" "$m" "$i" "${NAMES[$i]}"
    done
    hr; echo "  ${CB}a.${C0} 一键推荐优化（一路回车，不含 SSH 加固/改端口）"
    echo "  ${CB}u.${C0} 卸载本工具"
    echo "  ${CB}0.${C0} 退出脚本"
    hr; echo " 建议：先 a，再 1 → 2 → 3；可输入多个编号，用空格隔开；s 查看状态"
    local sel; read -r -p "选择: " sel </dev/tty || exit 0
    if [[ "$sel" =~ ^(0|00|q|Q|exit|quit)$ ]]; then echo "再见！下次输入 $SHORTCUT 即可启动"; exit 0; fi
    [[ "$sel" =~ ^[aA]$ ]] && { t_auto; read -r -p "按回车返回菜单…" _ </dev/tty || true; continue; }
    [[ "$sel" =~ ^[uU]$ ]] && { t_uninstall; read -r -p "按回车返回菜单…" _ </dev/tty || true; continue; }
    for i in $sel; do
      case "$i" in s|S) i=0 ;; 0) continue ;; esac
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
  list) for i in "${!TASKS[@]}"; do printf "%2d. %s\n" "$i" "${NAMES[$i]}"; done; echo " a. 一键推荐优化"; echo " u. 卸载本工具" ;;
  auto|a) t_auto ;;
  uninstall|u) t_uninstall ;;
  *) for i in "$@"; do if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "${#TASKS[@]}" ]; then "${TASKS[$i]}" || warn "第 $i 项没有完成"; else err "没有第 $i 项"; fi; done ;;
esac
