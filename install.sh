#!/usr/bin/env bash
set -Eeuo pipefail

TITLE="config-netflow"

# Caminhos
SYSTEMD_TMPL="/etc/systemd/system/nfdump@.service"
NFDUMP_ETC="/etc/nfdump"
PROFILES_BASE_DEFAULT="/var/nfdump/profiles_data"
PROFILE_NAME_DEFAULT="live"
SOURCE_DEFAULT="default"
PORT_DEFAULT="2055"

ZBX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_INC_DIR="/etc/zabbix/zabbix_agent2.d"
ZBX_CANON="${ZBX_INC_DIR}/netflow.conf"

# Helpers (scripts)
NFSTAT="/usr/local/bin/nfstat.sh"
NFTOP="/usr/local/bin/nf_top_hosts.sh"
NFREPORT="/usr/local/bin/nf_report.sh"
NFHOSTS_M="/usr/local/bin/nf_hosts_merged.sh"

# Retenção
EXPIRE_SCRIPT="/usr/local/sbin/nfdump-expire.sh"
EXPIRE_SVC="/etc/systemd/system/nfdump-expire.service"
EXPIRE_TIMER="/etc/systemd/system/nfdump-expire.timer"
RETENTION_DEFAULT="7"   # dias

ASSISTANT_CORE="/usr/local/sbin/config-netflow.core.sh"
ASSISTANT="/usr/local/sbin/config-netflow"

have(){ command -v "$1" >/dev/null 2>&1; }
root_required(){ [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }; }

# ===== UI =====
ui_has_whiptail(){ have whiptail; }
ui_has_dialog(){ have dialog; }

ui_menu(){
  local title="$1"; shift
  if ui_has_whiptail; then
    whiptail --title "$TITLE" --menu "$title" 20 78 10 "$@" 3>&1 1>&2 2>&3 || echo "__cancel__"
  elif ui_has_dialog; then
    dialog --title "$TITLE" --menu "$title" 20 78 10 "$@" 3>&1 1>&2 2>&3 || echo "__cancel__"
  else
    clear; echo "===== $TITLE ====="; echo "$title"
    local i=1 k v; declare -A opt
    while (( "$#" )); do k="$1"; v="$2"; shift 2; echo " [$i] $v"; opt[$i]="$k"; ((i++)); done
    read -rp "> Choice: " sel; echo "${opt[$sel]:-__cancel__}"
  fi
}

ui_input(){
  local prompt="$1" def="${2:-}"
  if ui_has_whiptail; then
    whiptail --title "$TITLE" --inputbox "$prompt" 10 70 "$def" 3>&1 1>&2 2>&3
  elif ui_has_dialog; then
    dialog --title "$TITLE" --inputbox "$prompt" 10 70 "$def" 3>&1 1>&2 2>&3
  else
    read -rp "$prompt [${def}]: " _a; echo "${_a:-$def}"
  fi
}

ui_msg(){
  local text="$1"
  if ui_has_whiptail; then
    whiptail --title "$TITLE" --msgbox "$text" 13 78
  elif ui_has_dialog; then
    dialog --title "$TITLE" --msgbox "$text" 13 78
  else
    echo -e "\n$text\n"; read -rp "Press Enter to continue..."
  fi
}

# ===== Pacotes / firewall =====
ensure_packages(){
  dnf -y install epel-release >/dev/null 2>&1 || true
  dnf -y install nfdump tcpdump policycoreutils-python-utils firewalld >/dev/null 2>&1
  if ! have zabbix_agent2; then
    dnf -y install zabbix-agent2 >/dev/null 2>&1 || {
      dnf -y install https://repo.zabbix.com/zabbix/7.0/rhel/9/x86_64/zabbix-release-latest.el9.noarch.rpm
      dnf clean all
      dnf -y install zabbix-agent2
    }
  fi
  dnf -y install whiptail dialog >/dev/null 2>&1 || true

  # Firewall — NetFlow 2055/udp e Zabbix Agent 10050/tcp
  systemctl enable --now firewalld >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=2055/udp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=10050/tcp >/dev/null 2>&1 || true
  # Se também for Zabbix Server/Proxy:
  # firewall-cmd --permanent --add-port=10051/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
}

# ===== systemd template nfdump =====
ensure_systemd_template(){
  cat > "$SYSTEMD_TMPL" <<'EOF'
[Unit]
Description=NetFlow collector nfcapd (instance: %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/nfdump/%i.conf
ExecStart=/usr/bin/nfcapd $options
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ===== helpers (APENAS nfstat.sh alterado p/ corrigir bytes/packets/flows) =====
ensure_helper_scripts(){
  # nfstat.sh — soma %pkt/%byt e conta linhas (flows). Não usa -q, funciona em todas as builds.
  cat > "$NFSTAT" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
# Usage: nfstat.sh <bytes|packets|flows> [WINDOW_SECONDS] [BASE_DIR]
METRIC="${1:-bytes}"
WINDOW="${2:-300}"
BASE="${3:-/var/nfdump/profiles_data/live/default}"

END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
START_TS="$(date -d "-${WINDOW} seconds" '+%Y-%m-%d %H:%M:%S')"

sum_stream(){
  awk -F',' '
    NF==2 {
      pk += ($1+0);
      by += ($2+0);
      fl += 1
    }
    END {
      printf "%d;%d;%d\n", pk, by, fl
    }'
}

# 1) Janela
OUT="$(/usr/bin/nfdump -R "${BASE}" -t "${START_TS}:${END_TS}" -o 'fmt:%pkt,%byt' 2>/dev/null || true)"
read -r PK BY FL <<<"$(printf "%s\n" "$OUT" | sum_stream | tr ';' ' ')"

# 2) Fallback: últimos 2 arquivos se tudo zerado
if [[ "${PK:-0}" -eq 0 && "${BY:-0}" -eq 0 && "${FL:-0}" -eq 0 ]]; then
  LASTS="$(ls -1t "${BASE}"/nfcapd.* 2>/dev/null | head -n 2 || true)"
  if [[ -n "$LASTS" ]]; then
    PK=0; BY=0; FL=0
    while read -r f; do
      [[ -n "$f" ]] || continue
      o="$(/usr/bin/nfdump -r "$f" -o 'fmt:%pkt,%byt' 2>/dev/null || true)"
      read -r p b fcount <<<"$(printf "%s\n" "$o" | sum_stream | tr ';' ' ')"
      PK=$((PK + p)); BY=$((BY + b)); FL=$((FL + fcount))
    done <<< "$LASTS"
  fi
fi

case "$METRIC" in
  bytes)   echo "${BY:-0}" ;;
  packets) echo "${PK:-0}" ;;
  flows)   echo "${FL:-0}" ;;
  *)       echo 0 ;;
esac
EOSH

  # nf_top_hosts.sh — (sem mudanças)
  cat > "$NFTOP" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
# Usage: nf_top_hosts.sh [srcip|dstip] [LIMIT] [WINDOW_SECONDS] [BASE_DIR]
DIRECTION="${1:-srcip}"; LIMIT="${2:-10}"; WINDOW="${3:-300}"
DIR="${4:-/var/nfdump/profiles_data/live/default}"
END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
START_TS="$(date -d "-${WINDOW} seconds" '+%Y-%m-%d %H:%M:%S')"
case "$DIRECTION" in
  srcip) FMT="%sa,%byt"; STAT="srcip/bytes" ;;
  dstip) FMT="%da,%byt"; STAT="dstip/bytes" ;;
  *)     FMT="%sa,%byt"; STAT="srcip/bytes" ;;
esac
/usr/bin/nfdump -R "$DIR" -t "${START_TS}:${END_TS}" \
  -s "$STAT" -n ${LIMIT} -o "fmt:${FMT}" -q 2>/dev/null || true
EOSH

  # nf_report.sh — (generic reporting)
  cat > "$NFREPORT" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C
# Usage: nf_prtg.sh [WINDOW_SECONDS] [LIMIT] [BASE_DIR]
WIN="${1:-300}"; LIM="${2:-10}"; DIR="${3:-/var/nfdump/profiles_data/live/default}"

END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
START_TS="$(date -d "-${WIN} seconds" '+%Y-%m-%d %H:%M:%S')"

run_fmt(){ /usr/bin/nfdump "$@" -o 'fmt:%ts,%td,%sa,%sp,%da,%dp,%pr,%pkt,%byt' -q 2>/dev/null || true; }

RAW="$(run_fmt -R "$DIR" -t "${START_TS}:${END_TS}" \
        -A srcip,dstip,srcport,dstport,proto -s record/bytes -n "$LIM")"

if [[ -z "$RAW" ]]; then
  LAST="$(ls -1t "$DIR"/nfcapd.* 2>/dev/null | head -n 2)"
  if [[ -n "$LAST" ]]; then
    RAW=""
    while read -r f; do [[ -n "$f" ]] || continue
      RAW+="$(
        run_fmt -r "$f" -A srcip,dstip,srcport,dstport,proto -s record/bytes -n "$LIM"
      )"$'\n'
    done <<< "$LAST"
    RAW="$(printf "%s" "$RAW" | sed '/^$/d' | head -n "$LIM")"
  fi
fi

awk -F',' -v W="$WIN" '
  function trim(x){gsub(/^ +| +$/,"",x); return x}
  function max(a,b){return a>b?a:b}
  function shorten(s,maxw,  len,keep,left,right){
    len=length(s); if (len<=maxw) return s;
    keep=maxw-3; if (keep<1) return substr(s,1,maxw);
    left=int(keep/2); right=keep-left;
    return substr(s,1,left) "..." substr(s,len-right+1,right);
  }
  {
    ts=trim($1); td=trim($2)
    src=trim($3) ":" trim($4)
    dst=trim($5) ":" trim($6)
    pr =trim($7)
    pk =($8+0); by=($9+0)
    bps=(W>0 ? by/W : 0); pps=(W>0 ? pk/W : 0); bpp=(pk>0 ? by/pk : 0)

    p_ts=ts; p_td=td; p_pr=pr; p_src=src; p_dst=dst
    p_pk=sprintf("%d",pk); p_by=sprintf("%d",by)
    p_bps=sprintf("%.0f",bps); p_pps=sprintf("%.1f",pps); p_bpp=sprintf("%.0f",bpp)

    N++; R_ts[N]=p_ts; R_td[N]=p_td; R_pr[N]=p_pr; R_src[N]=p_src; R_dst[N]=p_dst
        ; R_pk[N]=p_pk; R_by[N]=p_by; R_bps[N]=p_bps; R_pps[N]=p_pps; R_bpp[N]=p_bpp

    W_ts =max(W_ts ,length(p_ts))
    W_td =max(W_td ,length(p_td))
    W_pr =max(W_pr ,length(p_pr))
    W_src=max(W_src,length(p_src))
    W_dst=max(W_dst,length(p_dst))
    W_pk =max(W_pk ,length(p_pk))
    W_by =max(W_by ,length(p_by))
    W_bps=max(W_bps,length(p_bps))
    W_pps=max(W_pps,length(p_pps))
    W_bpp=max(W_bpp,length(p_bpp))
  }
  END{
    if(N==0) exit
    if(W_ts<19) W_ts=19
    if(W_td<12) W_td=12
    if(W_pr<5)  W_pr=5
    if(W_src<21) W_src=21; if(W_src>46) W_src=46
    if(W_dst<21) W_dst=21; if(W_dst>46) W_dst=46
    if(W_pk<7)  W_pk=7
    if(W_by<7)  W_by=7
    if(W_bps<7) W_bps=7
    if(W_pps<6) W_pps=6
    if(W_bpp<3) W_bpp=3

    printf "%-*s  %-*s  %-*s  %-*s  %-*s  %*s  %*s  %*s  %*s  %*s\n",
      W_ts,"Date first seen", W_td,"Duration", W_pr,"Proto",
      W_src,"Src IP:Port",   W_dst,"Dst IP:Port",
      W_pk,"Packets", W_by,"Bytes", W_bps,"Bytes/s", W_pps,"Pkts/s", W_bpp,"Bpp";

    sep=W_ts+2 + W_td+2 + W_pr+2 + W_src+2 + W_dst+2 + W_pk+2 + W_by+2 + W_bps+2 + W_pps+2 + W_bpp
    for(i=1;i<=sep;i++) printf "-"; printf "\n";

    for(i=1;i<=N;i++){
      ssrc=shorten(R_src[i], W_src)
      sdst=shorten(R_dst[i], W_dst)
      printf "%-*s  %-*s  %-*s  %-*s  %-*s  %*s  %*s  %*s  %*s  %*s\n",
        W_ts,R_ts[i], W_td,R_td[i], W_pr,R_pr[i],
        W_src,ssrc,   W_dst,sdst,
        W_pk,R_pk[i], W_by,R_by[i], W_bps,R_bps[i], W_pps,R_pps[i], W_bpp,R_bpp[i]
    }
  }
' <<< "$RAW"
EOSH

  # nf_hosts_merged.sh — (merged host stats)
  cat > "$NFHOSTS_M" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C
# Usage: nf_prtg_talkers_merged.sh [WINDOW_SECONDS] [LIMIT] [BASE_DIR]
WIN="${1:-300}"; LIM="${2:-10}"; DIR="${3:-/var/nfdump/profiles_data/live/default}"

CSV_RAW="$(
  /usr/bin/nfdump -R "$DIR" \
    -t "$(date -d "-${WIN} seconds" '+%Y-%m-%d %H:%M:%S'):$(date '+%Y-%m-%d %H:%M:%S')" \
    -A srcip,dstip,srcport,dstport,proto -s record/bytes -n 100000 \
    -o 'fmt:%ts,%te,%td,%sa,%sp,%da,%dp,%pr,%pkt,%byt' -q 2>/dev/null || true
)"

if [[ -z "$CSV_RAW" ]]; then
  LAST="$(ls -1t "$DIR"/nfcapd.* 2>/dev/null | head -n 2)"
  if [[ -n "$LAST" ]]; then
    CSV_RAW=""
    while read -r f; do [[ -z "$f" ]] && continue
      CSV_RAW+="$(
        /usr/bin/nfdump -r "$f" \
          -A srcip,dstip,srcport,dstport,proto -s record/bytes -n 100000 \
          -o 'fmt:%ts,%te,%td,%sa,%sp,%da,%dp,%pr,%pkt,%byt' -q 2>/dev/null || true
      )"$'\n'
    done <<< "$LAST"
    CSV_RAW="$(printf "%s" "$CSV_RAW" | sed '/^$/d')"
  fi
fi

LINES="$(awk -F',' -v W="$WIN" '
  function trim(x){gsub(/^ +| +$/,"",x); return x}
  NF>=10 {
    s=trim($4); d=trim($6); pk=$9+0; by=$10+0;
    src_pk[s]+=pk; src_by[s]+=by;
    dst_pk[d]+=pk; dst_by[d]+=by;
  }
  END{
    for (h in src_pk){ if(!(h in dst_pk)){dst_pk[h]=0; dst_by[h]=0} }
    for (h in dst_pk){ if(!(h in src_pk)){src_pk[h]=0; src_by[h]=0} }
    for (h in src_pk){
      tpk=src_pk[h]+dst_pk[h]; tby=src_by[h]+dst_by[h]; bps=(W>0?tby/W:0);
      printf "%s,%d,%d,%d,%d,%d,%d,%.0f\n", h, src_pk[h], src_by[h], dst_pk[h], dst_by[h], tpk, tby, bps;
    }
  }' <<< "$CSV_RAW" | sort -t, -k7,7nr | head -n "$LIM")"

printf "%-23s  %10s  %12s  %10s  %12s  %12s  %14s  %10s\n" \
  "Host" "SrcPkts" "SrcBytes" "DstPkts" "DstBytes" "TotPkts" "TotBytes" "Bytes/s"
printf -- "%0.s-" {1..120}; echo
printf "%s\n" "$LINES" | awk -F',' '
  function trim(x){gsub(/^ +| +$/,"",x); return x}
  NF>=8 {
    printf "%-23s  %10d  %12d  %10d  %12d  %12d  %14d  %10.0f\n",
      trim($1),$2+0,$3+0,$4+0,$5+0,$6+0,$7+0,$8+0
  }'
EOSH

  chmod +x "$NFSTAT" "$NFTOP" "$NFREPORT" "$NFHOSTS_M"
  semanage fcontext -a -t bin_t "/usr/local/bin(/.*)?" 2>/dev/null || true
  restorecon -RF /usr/local/bin >/dev/null 2>&1 || true
}

# ===== coletor =====
action_configure_collector(){
  ensure_packages; ensure_systemd_template; ensure_helper_scripts
  mkdir -p "$NFDUMP_ETC"
  local profiles_base profile_name source port
  profiles_base="$(ui_input 'nfdump base path' "$PROFILES_BASE_DEFAULT")"
  profile_name="$(ui_input 'nfdump profile name' "$PROFILE_NAME_DEFAULT")"
  source="$(ui_input 'Collector source instance' "$SOURCE_DEFAULT")"
  port="$(ui_input 'Collector UDP port' "$PORT_DEFAULT")"
  local base="${profiles_base}/${profile_name}/${source}"
  mkdir -p "$base"

  # Moderno: -w (em vez de -l), sem -T
  cat > "${NFDUMP_ETC}/${source}.conf" <<EOF
options='-z -S 1 -w ${base} -p ${port}'
EOF

  semanage fcontext -a -t var_t "${profiles_base}(/.*)?" 2>/dev/null || true
  restorecon -RF "${profiles_base}" 2>/dev/null || true

  firewall-cmd --add-port="${port}"/udp --permanent >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true

  systemctl enable --now "nfdump@${source}.service"
  systemctl restart "nfdump@${source}.service" || true

  ui_msg "Collector OK\n- Instance: nfdump@${source}\n- UDP: ${port}\n- Base: ${base}"
}

# ===== zabbix agent2 =====
fix_agent_pid(){
  local pidfile="/run/zabbix/zabbix_agent2.pid"
  if [[ -f "$pidfile" ]] && ! pgrep -F "$pidfile" >/devnull 2>&1; then
    rm -f "$pidfile"
  fi
}

action_configure_agent(){
  ensure_packages; ensure_helper_scripts
  mkdir -p "$ZBX_INC_DIR"; touch "$ZBX_CONF"

  local def_ServerCSV def_ServerActive def_Hostname
  def_ServerCSV="$(awk -F= '/^Server=/{print $2}' "$ZBX_CONF" | head -n1)"
  def_ServerActive="$(awk -F= '/^ServerActive=/{print $2}' "$ZBX_CONF" | head -n1 | cut -d, -f1)"
  def_Hostname="$(awk -F= '/^Hostname=/{print $2}' "$ZBX_CONF" | head -n1)"
  [[ -z "$def_ServerCSV" ]] && def_ServerCSV="127.0.0.1"
  [[ -z "$def_ServerActive" ]] && def_ServerActive="${def_ServerCSV}:10051"
  [[ -z "$def_Hostname" ]] && def_Hostname="$(hostname -f 2>/dev/null || hostname)"

  local ServerCSV ServerActive Hostname profiles_base profile_name source base
  ServerCSV="$(ui_input 'Zabbix Server(s) CSV (passive/allow)' "$def_ServerCSV")"
  ServerActive="$(ui_input 'ServerActive host:port (Server/Proxy)' "$def_ServerActive")"
  [[ "$ServerActive" =~ : ]] || ServerActive="${ServerActive}:10051"
  Hostname="$(ui_input 'Agent Hostname (igual no Zabbix)' "$def_Hostname")"
  profiles_base="$(ui_input 'nfdump base path' "$PROFILES_BASE_DEFAULT")"
  profile_name="$(ui_input 'nfdump profile name' "$PROFILE_NAME_DEFAULT")"
  source="$(ui_input 'Collector source instance' "$SOURCE_DEFAULT")"
  base="${profiles_base}/${profile_name}/${source}"

  sed -i '/^Server=/d;/^ServerActive=/d;/^Hostname=/d;/^Include=/d' "$ZBX_CONF" 2>/dev/null || true
  {
    echo "Server=${ServerCSV}"
    echo "ServerActive=${ServerActive}"
    echo "Hostname=${Hostname}"
    echo "Include=${ZBX_INC_DIR}/*.conf"
  } >> "$ZBX_CONF"

  # NetFlow UserParameters — ${TITLE}
  cat > "$ZBX_CANON" <<EOF
# NetFlow UserParameters — ${TITLE}
UserParameter=netflow.bytes[*],${NFSTAT} bytes \$1 ${base}
UserParameter=netflow.packets[*],${NFSTAT} packets \$1 ${base}
UserParameter=netflow.flows[*],${NFSTAT} flows \$1 ${base}
UserParameter=netflow.tophosts[*],${NFTOP} \$1 \$2 \$3 ${base}
UserParameter=netflow.report[*],${NFREPORT} \$1 \$2 ${base}
UserParameter=netflow.hosts_merged[*],${NFHOSTS_M} \$1 \$2 ${base}
EOF
  chmod 644 "$ZBX_CANON"

  systemctl enable --now zabbix-agent2
  fix_agent_pid
  systemctl restart zabbix-agent2 || true

  ui_msg "Zabbix Agent OK\n- Server=${ServerCSV}\n- ServerActive=${ServerActive}\n- Hostname=${Hostname}\n- Base=${base}\n- UserParams: ${ZBX_CANON}"
}

# ===== Validação rápida =====
action_validate(){
  local out
  out="$(systemctl --no-pager --full status zabbix-agent2 2>&1 | sed -n '1,20p' || true)"
  ui_msg "=== zabbix-agent2 status ===\n${out}"

  local k; k="$(
    { zabbix_agent2 -t agent.ping || true;
      zabbix_agent2 -t 'netflow.bytes[300]' || true;
      zabbix_agent2 -t 'netflow.packets[300]' || true;
      zabbix_agent2 -t 'netflow.flows[300]' || true;
      zabbix_agent2 -t 'netflow.hosts_merged[300,10]' || true;
      zabbix_agent2 -t 'netflow.report[300,10]' || true; } 2>&1
  )"
  ui_msg "=== KEY TESTS ===\n${k}"
}

# ===== Retenção (expurgo 30d + configurável) =====
ensure_expire_timer(){
  cat > "$EXPIRE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
RETENTION_DAYS="${RETENTION_DAYS:-30}"
BASE="${BASE:-/var/nfdump/profiles_data/live}"
find "$BASE" -type f -name 'nfcapd.*' -mtime +${RETENTION_DAYS} -print -delete
find "$BASE" -type d -empty -print -delete || true
EOF
  chmod +x "$EXPIRE_SCRIPT"

  cat > "$EXPIRE_SVC" <<EOF
[Unit]
Description=Expire old nfdump capture files (${TITLE})

[Service]
Type=oneshot
Environment=RETENTION_DAYS=${RETENTION_DEFAULT}
Environment=BASE=${PROFILES_BASE_DEFAULT}/${PROFILE_NAME_DEFAULT}
ExecStart=${EXPIRE_SCRIPT}
EOF

  cat > "$EXPIRE_TIMER" <<'EOF'
[Unit]
Description=Daily nfdump expire job
[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
Unit=nfdump-expire.service
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now nfdump-expire.timer
}

action_configure_retention(){
  ensure_expire_timer
  local cur_days cur_base
  cur_days="$(awk -F= '/^Environment=RETENTION_DAYS=/{print $2}' "$EXPIRE_SVC" 2>/dev/null | tail -n1)"
  cur_base="$(awk -F= '/^Environment=BASE=/{print $2}' "$EXPIRE_SVC" 2>/dev/null | tail -n1)"
  [[ -z "$cur_days" ]] && cur_days="$RETENTION_DEFAULT"
  [[ -z "$cur_base" ]] && cur_base="${PROFILES_BASE_DEFAULT}/${PROFILE_NAME_DEFAULT}"
  local days base tmp
  days="$(ui_input 'Retention (days)' "$cur_days")"
  base="$(ui_input 'Expire base path' "$cur_base")"
  tmp="$(mktemp)"; cp -a "$EXPIRE_SVC" "$tmp"
  sed -i -E "s|^Environment=RETENTION_DAYS=.*|Environment=RETENTION_DAYS=${days}|g" "$tmp"
  sed -i -E "s|^Environment=BASE=.*|Environment=BASE=${base}|g" "$tmp"
  cp -a "$tmp" "$EXPIRE_SVC"; rm -f "$tmp"
  systemctl daemon-reload
  systemctl restart nfdump-expire.service || true
  systemctl enable --now nfdump-expire.timer
  local tstat; tstat="$(systemctl status nfdump-expire.timer --no-pager 2>/dev/null | sed -n '1,8p')"
  ui_msg "Retention set to ${days} days on base ${base}.\nTimer enabled.\n\n${tstat}"
}

action_about(){ ui_msg "$TITLE\nNetFlow (nfdump) + Zabbix Agent 2 — Developed by Hector Crizel - NapIT"; }

ensure_assistant_shortcut(){
  [[ -f "$ASSISTANT_CORE" ]] || install -m 0755 "$0" "$ASSISTANT_CORE"
  cat > "$ASSISTANT" <<EOF
#!/usr/bin/env bash
exec bash "$ASSISTANT_CORE"
EOF
  chmod +x "$ASSISTANT"
}

main_menu(){
  while true; do
    choice="$(ui_menu "Assistente de Configuração" \
      install_col "Install/Configure NetFlow Collector" \
      install_zbx "Install/Configure Zabbix Agent 2" \
      validate    "Validate keys & services" \
      retention   "Configure Retention (days & base)" \
      about       "About" \
      exit        "Exit")"
    case "$choice" in
      install_col) action_configure_collector ;;
      install_zbx) action_configure_agent ;;
      validate)    action_validate ;;
      retention)   action_configure_retention ;;
      about)       action_about ;;
      __cancel__|exit) break ;;
      *) break ;;
    esac
  done
}

# run
root_required
ensure_packages
ensure_systemd_template
ensure_helper_scripts
ensure_expire_timer
ensure_assistant_shortcut
main_menu

