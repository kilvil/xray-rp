#!/usr/bin/env bash
# xray-rp.sh - Portal/Bridge 一键安装与配置（VLESS + REALITY + Reverse v4）
# Tested on Debian/Ubuntu/CentOS/Rocky/Alma/Oracle/Alpine
set -euo pipefail

XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_CFG="${XRAY_CFG_DIR}/config.json"
LOG_DIR="/var/log/xray"

color() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
ok()    { color "32" "✔ $*"; }
warn()  { color "33" "⚠ $*"; }
err()   { color "31" "✘ $*"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then err "请用 root 运行"; exit 1; fi
}

detect_pm() {
  if command -v apt >/dev/null 2>&1; then PM="apt"; INSTALL="apt install -y"
  elif command -v dnf >/dev/null 2>&1; then PM="dnf"; INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then PM="yum"; INSTALL="yum install -y"
  elif command -v apk >/dev/null 2>&1; then PM="apk"; INSTALL="apk add --no-cache"
  else err "未识别的包管理器"; exit 1; fi
}

ensure_tools() {
  $INSTALL curl jq openssl >/dev/null 2>&1 || $INSTALL curl jq openssl
}

install_xray() {
  # 使用临时文件运行安装脚本，避免通过管道传参导致的 bash 选项解析异常
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp"
  # 直接以子命令方式调用安装脚本，避免特殊占位符参数引发兼容性问题
  bash "$tmp" install
  rm -f "$tmp"
}

ensure_layout() {
  mkdir -p "$XRAY_CFG_DIR" "$LOG_DIR"
  touch "$LOG_DIR/access.log" "$LOG_DIR/error.log"
}

bkp_cfg() {
  if [[ -f "$XRAY_CFG" ]]; then cp -a "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%Y%m%d%H%M%S)"; fi
}

xray_ok() {
  "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null && return 0 || return 1
}

restart_xray() {
  systemctl daemon-reload || true
  systemctl enable --now xray
  systemctl restart xray
  systemctl status --no-pager -l xray | sed -n '1,15p'
}

gen_uuid() { "$XRAY_BIN" uuid; }

# 生成 REALITY 密钥对（私钥 + “Password=公钥”）
gen_reality_keys() {
  local out priv pub
  out="$("$XRAY_BIN" x25519)"
  priv=$(sed -n 's/^PrivateKey: //p' <<<"$out")
  pub=$(sed -n 's/^Password: //p' <<<"$out")
  printf '%s;%s\n' "$priv" "$pub"
}

gen_shortid() { openssl rand -hex 8; }

# 生成 VLESS 加密/解密字符串（选择 PQ 或 X25519）
gen_vlessenc() {
  local mode="$1" out enc dec
  out="$("$XRAY_BIN" vlessenc)"
  if [[ "$mode" == "pq" ]]; then
    dec=$(awk '/Authentication: ML-KEM-768/{f=1} f&&/"decryption":/{gsub(/.*"decryption": "|".*/,""); print; exit}' <<<"$out")
    enc=$(awk '/Authentication: ML-KEM-768/{f=1} f&&/"encryption":/{gsub(/.*"encryption": "|".*/,""); print; exit}' <<<"$out")
  else
    dec=$(awk '/Authentication: X25519/{f=1} f&&/"decryption":/{gsub(/.*"decryption": "|".*/,""); print; exit}' <<<"$out")
    enc=$(awk '/Authentication: X25519/{f=1} f&&/"encryption":/{gsub(/.*"encryption": "|".*/,""); print; exit}' <<<"$out")
  fi
  printf '%s;%s\n' "$dec" "$enc"
}

ask() { # ask "提示" "默认值"
  local p="$1" d="${2:-}"
  if [[ -n "$d" ]]; then read -rp "$p [$d]: " v; echo "${v:-$d}"; else read -rp "$p: " v; echo "$v"; fi
}

make_portal() {
  need_root; detect_pm; ensure_tools; install_xray; ensure_layout; bkp_cfg

  local addr sni_fwd sni_rev auth_choice auth_mode
  addr=$(ask "Portal 公网域名或IP(将写入连接参数)" "")
  sni_fwd=$(ask "正向(443) REALITY 的 SNI(serverName)" "tidal.com")
  sni_rev=$(ask "反向(9443) REALITY 的 SNI(serverName)" "apple.com")
  auth_choice=$(ask "VLESS 认证方案 [pq=后量子 / x25519=非PQ]" "pq")
  [[ "$auth_choice" == "pq" ]] && auth_mode="pq" || auth_mode="x25519"

  # 生成：443(正向) 的 REALITY 密钥 + 短ID + 客户端 UUID
  local f_priv f_pub f_short f_uuid
  IFS=';' read -r f_priv f_pub < <(gen_reality_keys)
  f_short=$(gen_shortid)
  f_uuid=$(gen_uuid)

  # 生成：9443(反向) 的 REALITY 密钥 + 短ID + 反向 UUID（Bridge 使用）
  local r_priv r_pub r_short r_uuid
  IFS=';' read -r r_priv r_pub < <(gen_reality_keys)
  r_short=$(gen_shortid)
  r_uuid=$(gen_uuid)

  # 生成 VLESS enc/dec（同一组：Portal入站用 decryption；Bridge出站用 encryption）
  local v_dec v_enc
  IFS=';' read -r v_dec v_enc < <(gen_vlessenc "$auth_mode")

  # 写入 Portal 配置（含 API + 443 正向 + 9443 反向 + 31234 tunnel）
  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning", "error": "$LOG_DIR/error.log", "access": "$LOG_DIR/access.log" },
  "api": { "tag": "api", "services": ["HandlerService","LoggerService","StatsService"] },
  "stats": {},
  "policy": { "levels": {"0":{"statsUserUplink":true,"statsUserDownlink":true}},
              "system":{"statsInboundUplink":true,"statsInboundDownlink":true,"statsOutboundUplink":true,"statsOutboundDownlink":true} },
  "routing": {
    "rules": [
      { "ruleTag":"api", "inboundTag":["api"], "outboundTag":"api" },
      { "ruleTag":"bt", "protocol":["bittorrent"], "outboundTag":"block" },
      { "inboundTag":["t-inbound"], "outboundTag":"r-outbound" },
      { "ruleTag":"private-ip", "ip":["geoip:private"], "outboundTag":"block" },
      { "ruleTag":"cn-ip", "ip":["geoip:cn"], "outboundTag":"block" },
      { "ruleTag":"ad-domain", "domain":["geosite:category-ads-all"], "outboundTag":"block" }
    ]
  },
  "inbounds": [
    { "tag":"api","listen":"127.0.0.1","port":32768,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"} },
    {
      "tag": "VLESS-Vision-REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "email":"vless@xtls.reality", "id":"$f_uuid", "flow":"xtls-rprx-vision", "level":0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$sni_fwd:443",
          "serverNames": ["$sni_fwd"],
          "privateKey": "$f_priv",
          "shortIds": ["$f_short"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },
    {
      "tag": "external-vless",
      "listen": "0.0.0.0",
      "port": 9443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "email":"bridge-rev","id":"$r_uuid","flow":"xtls-rprx-vision","reverse":{"tag":"r-outbound"} }
        ],
        "decryption": "$v_dec"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$sni_rev:443",
          "serverNames": ["$sni_rev"],
          "privateKey": "$r_priv",
          "shortIds": ["$r_short"]
        }
      }
    },
    { "listen":"0.0.0.0", "port":31234, "protocol":"tunnel", "tag":"t-inbound" }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF

  if xray_ok; then ok "配置校验通过"; else err "配置校验失败"; exit 1; fi
  restart_xray

  # 输出连接参数（Bridge 脚本将解析）
  cat <<JSON

================= 连接参数（请复制到 Bridge 脚本） =================
{
  "portal_addr": "${addr}",
  "auth": "${auth_mode}",
  "forward": {
    "address": "${addr}",
    "port": 443,
    "id": "${f_uuid}",
    "serverName": "${sni_fwd}",
    "publicKey": "${f_pub}",
    "shortId": "${f_short}",
    "flow": "xtls-rprx-vision"
  },
  "reverse": {
    "address": "${addr}",
    "port": 9443,
    "id": "${r_uuid}",
    "serverName": "${sni_rev}",
    "publicKey": "${r_pub}",
    "shortId": "${r_short}",
    "encryption": "${v_enc}",
    "flow": "xtls-rprx-vision"
  }
}
===================================================================
JSON

  ok "Portal 完成。请把以上 JSON 原样复制，粘贴到 Bridge 脚本提示处。"
}

make_bridge() {
  need_root; detect_pm; ensure_tools; install_xray; ensure_layout; bkp_cfg

  warn "请粘贴从 Portal 输出的连接参数 JSON，粘贴结束后按 Ctrl-D："
  local tmp=$(mktemp)
  cat > "$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then err "粘贴的不是有效 JSON"; exit 1; fi

  local paddr auth f_id f_sni f_pub f_sid f_port f_flow
  local r_id r_sni r_pub r_sid r_port r_enc r_flow

  paddr=$(jq -r '.portal_addr' "$tmp")
  auth=$(jq -r '.auth' "$tmp")
  # forward (可选)
  f_id=$(jq -r '.forward.id' "$tmp")
  f_sni=$(jq -r '.forward.serverName' "$tmp")
  f_pub=$(jq -r '.forward.publicKey' "$tmp")
  f_sid=$(jq -r '.forward.shortId' "$tmp")
  f_port=$(jq -r '.forward.port' "$tmp")
  f_flow=$(jq -r '.forward.flow' "$tmp")
  # reverse
  r_id=$(jq -r '.reverse.id' "$tmp")
  r_sni=$(jq -r '.reverse.serverName' "$tmp")
  r_pub=$(jq -r '.reverse.publicKey' "$tmp")
  r_sid=$(jq -r '.reverse.shortId' "$tmp")
  r_port=$(jq -r '.reverse.port' "$tmp")
  r_enc=$(jq -r '.reverse.encryption' "$tmp")
  r_flow=$(jq -r '.reverse.flow' "$tmp")

  # 是否要配置本地 Socks 正向上网（走 443）
  local with_socks; with_socks=$(ask "是否配置本地 Socks5(127.0.0.1:10808) 并走 Portal:443 正向代理? [y/n]" "y")

  # 生成 Bridge 配置
  {
    cat <<'HDR'
{
  "log": { "loglevel": "info", "error": "/var/log/xray/error.log", "access": "/var/log/xray/access.log" },
  "inbounds": [
HDR
    if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
      cat <<'INB'
    { "tag":"socks-in","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true} }
INB
    fi
    cat <<'MID'
  ],
  "outbounds": [
    { "protocol":"direct","tag":"default" },
    { "protocol":"freedom","tag":"local-web","settings":{"redirect":"127.0.0.1:80"} },
MID
    if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
      # 正向代理出站
      cat <<FWD
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [ { "address": "${paddr}", "port": ${f_port},
          "users": [ { "id": "${f_id}", "encryption": "none", "flow": "${f_flow}" } ] } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${f_sni}",
          "publicKey": "${f_pub}",
          "shortId": "${f_sid}",
          "fingerprint": "chrome",
          "spiderX": "/"
        }
      },
      "mux": { "enabled": false }
    },
FWD
    fi
    # 反向出站（Bridge -> Portal:9443）
    cat <<REV
    {
      "tag": "rev-link",
      "protocol": "vless",
      "settings": {
        "address": "${paddr}",
        "port": ${r_port},
        "id": "${r_id}",
        "encryption": "${r_enc}",
        "flow": "${r_flow}",
        "reverse": { "tag": "r-inbound" }
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${r_sni}",
          "publicKey": "${r_pub}",
          "shortId": "${r_sid}",
          "fingerprint": "chrome",
          "spiderX": "/"
        }
      },
      "mux": { "enabled": false }
    }
REV
    cat <<'TAIL'
  ],
  "routing": {
    "rules": [
      { "type":"field", "inboundTag":["r-inbound"], "outboundTag":"local-web" }
TAIL
    if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
      cat <<'ROUTE'
      ,{ "type":"field", "inboundTag":["socks-in"], "outboundTag":"proxy" }
ROUTE
    fi
    cat <<'ENDJSON'
    ]
  }
}
ENDJSON
  } > "$XRAY_CFG"

  if xray_ok; then ok "配置校验通过"; else err "配置校验失败"; exit 1; fi
  restart_xray

  ok "Bridge 完成。现在："
  if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
    echo "  * 本机 SOCKS5: 127.0.0.1:10808 (curl --socks5 127.0.0.1:10808 http://ip-api.com/json)"
  fi
  echo "  * 反向隧道入口：访问 http://${paddr}:31234 会被转发到 Bridge 的 127.0.0.1:80"
  echo "日志: tail -F /var/log/xray/error.log /var/log/xray/access.log"
}

uninstall_xray() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp"
  bash "$tmp" remove
  rm -f "$tmp"
  ok "已卸载 xray（保留配置）。如需彻底清理：再次执行并添加 --purge。"
}

update_geodata() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp"
  bash "$tmp" install-geodata
  rm -f "$tmp"
  ok "已更新 geosite/geoip"
}

main() {
  need_root; detect_pm
  cat <<MENU
================ Xray Reverse Proxy 快速配置 ================
1) 安装并配置 Portal（生成连接参数）
2) 安装并配置 Bridge（粘贴连接参数）
3) 卸载 Xray
4) 更新 geodata
0) 退出
==============================================================
MENU
  read -rp "选择: " sel
  case "${sel:-0}" in
    1) make_portal ;;
    2) make_bridge ;;
    3) uninstall_xray ;;
    4) update_geodata ;;
    0) exit 0 ;;
    *) err "无效选择" ; exit 1 ;;
  esac
}

main "$@"
