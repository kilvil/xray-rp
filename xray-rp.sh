#!/usr/bin/env bash
# xray-rp.sh - Portal/Bridge 一键安装与配置（VLESS + REALITY + Reverse v4）
# Tested on Debian/Ubuntu/CentOS/Rocky/Alma/Oracle/Alpine
set -euo pipefail

XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_CFG="${XRAY_CFG_DIR}/config.json"
LOG_DIR="/var/log/xray"

# REALITY 伪装域名池（随机抽取，用作 serverName/dest）
declare -a REALITY_DOMAINS=(
  "bleach.fandom.com"
  "booth.pm"
  "dragonball.fandom.com"
  "fandom.com"
  "mora.jp"
  "mxj.myanimelist.net"
  "naruto.fandom.com"
  "nichijou.fandom.com"
  "onepiece.fandom.com"
  "pokemon.fandom.com"
  "tidal.com"
  "toarumajutsunoindex.fandom.com"
  "www.fandom.com"
  "www.ivi.tv"
  "www.j-wave.co.jp"
  "www.leercapitulo.co"
  "www.lovelive-anime.jp"
  "www.pixiv.co.jp"
  "www.sky.com"
)

pick_reality_domain() {
  local n=${#REALITY_DOMAINS[@]}
  [[ $n -gt 0 ]] || { echo "tidal.com"; return; }
  local idx=$((RANDOM % n))
  echo "${REALITY_DOMAINS[$idx]}"
}

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

# 通过 Cloudflare Meta 获取公网 IP（优先 IPv4/IPv6 原样返回）
detect_public_addr() {
  local meta ip
  meta="$(curl -fsSL --connect-timeout 3 --max-time 5 https://speed.cloudflare.com/meta || true)"
  ip="$(jq -r '.clientIp // empty' <<<"$meta" 2>/dev/null || true)"
  printf '%s' "$ip"
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
  if [[ -f "$XRAY_CFG" ]]; then
    # 时间戳备份
    cp -a "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    # 固定名备份，满足“备份为 config.json.bak”的需求
    cp -a "$XRAY_CFG" "${XRAY_CFG_DIR}/config.json.bak"
  fi
}

# 安装/配置前的状态检测与提示
report_existing_state() {
  if [[ -x "$XRAY_BIN" ]]; then
    local ver
    ver=$("$XRAY_BIN" -version 2>/dev/null | head -n1 || true)
    if [[ -n "$ver" ]]; then
      warn "检测到已安装 Xray: ${ver}"
    else
      warn "检测到已安装 Xray 可执行文件"
    fi
  fi
  if [[ -s "$XRAY_CFG" ]]; then
    warn "检测到现有配置文件且非空：$XRAY_CFG。将备份为 config.json.bak"
  elif [[ -f "$XRAY_CFG" ]]; then
    warn "检测到现有配置文件但为空：$XRAY_CFG。将覆盖生成新配置"
  else
    ok "未发现现有配置文件，将生成新配置"
  fi
}

# 校验配置，失败时打印详细错误输出与 JSON 语法检查结果
xray_validate() {
  local out status=0
  # 先进行 JSON 语法预检查，尽早报告定位信息
  if ! jq -e . "$XRAY_CFG" >/dev/null 2>&1; then
    local jq_err
    jq_err="$(jq . "$XRAY_CFG" 2>&1 | head -n 3 || true)"
    err "配置 JSON 语法有误：$jq_err"
    echo "配置文件路径: $XRAY_CFG"
    return 1
  fi
  # 调用 Xray 进行配置校验，捕获详细输出
  out=$("$XRAY_BIN" run -test -c "$XRAY_CFG" 2>&1) || status=$?
  # 某些版本可能输出失败信息但退出码为 0，这里做内容兜底判断
  if [[ $status -ne 0 || "$out" == *"Failed to start"* || "$out" == *"failed to build"* ]]; then
    err "配置校验失败（以下为 Xray -test 输出）："
    echo "$out"
    echo "配置文件路径: $XRAY_CFG"
    return 1
  fi
  return 0
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
  out="$("$XRAY_BIN" vlessenc 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    if [[ "$mode" == "pq" ]]; then
      dec=$(awk '/Authentication: ML-KEM-768/{f=1} f&&/"decryption":/{gsub(/.*"decryption": "|".*/,""); print; exit}' <<<"$out")
      enc=$(awk '/Authentication: ML-KEM-768/{f=1} f&&/"encryption":/{gsub(/.*"encryption": "|".*/,""); print; exit}' <<<"$out")
    else
      dec=$(awk '/Authentication: X25519/{f=1} f&&/"decryption":/{gsub(/.*"decryption": "|".*/,""); print; exit}' <<<"$out")
      enc=$(awk '/Authentication: X25519/{f=1} f&&/"encryption":/{gsub(/.*"encryption": "|".*/,""); print; exit}' <<<"$out")
    fi
  fi
  [[ -z "$dec" ]] && dec="none"
  [[ -z "$enc" ]] && enc="none"
  printf '%s;%s\n' "$dec" "$enc"
}

ask() { # ask "提示" "默认值"
  local p="$1" d="${2:-}"
  if [[ -n "$d" ]]; then read -rp "$p [$d]: " v; echo "${v:-$d}"; else read -rp "$p: " v; echo "$v"; fi
}

ask_port() { # ask_port "提示" 默认端口
  local prompt="$1" def="${2:-80}" v
  while true; do
    if [[ -n "$def" ]]; then
      read -rp "$prompt [$def]: " v; v="${v:-$def}"
    else
      read -rp "$prompt: " v
    fi
    # 允许纯数字的 1-65535
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )); then
      echo "$v"; return 0
    fi
    warn "端口无效，请输入 1-65535 的数字"
  done
}

make_portal() {
  need_root; detect_pm; ensure_tools; install_xray; ensure_layout; report_existing_state; bkp_cfg

  local addr sni_fwd sni_rev auth_choice auth_mode daddr
  daddr="$(detect_public_addr || true)"
  if [[ -n "$daddr" ]]; then
    ok "已从 Cloudflare Meta 检测到公网IP: $daddr"
  else
    warn "未能通过 Cloudflare Meta 检测公网IP，请手动输入。"
  fi
  addr=$(ask "Portal 公网域名或IP(将写入连接参数)" "$daddr")
  local def_sni_fwd def_sni_rev
  def_sni_fwd="$(pick_reality_domain)"
  def_sni_rev="$(pick_reality_domain)"
  sni_fwd=$(ask "正向(443) REALITY 的 SNI(serverName)" "$def_sni_fwd")
  sni_rev=$(ask "反向(9443) REALITY 的 SNI(serverName)" "$def_sni_rev")
  # 端口自定义：Portal 正向端口(默认443)、Portal 反向端口(默认9443)
  local port_fwd port_rev
  port_fwd=$(ask_port "Portal 正向端口(REALITY/VLESS, 客户端连接端口)" 443)
  port_rev=$(ask_port "Portal 反向端口(REALITY/VLESS, Bridge 连接端口)" 9443)
  auth_choice=$(ask "VLESS 认证方案 [pq=后量子 / x25519=非PQ]" "pq")
  [[ "$auth_choice" == "pq" ]] && auth_mode="pq" || auth_mode="x25519"

  # 生成：443(正向) 的 REALITY 密钥 + 短ID + 客户端 UUID
  local f_priv f_pub f_short f_uuid
  IFS=';' read -r f_priv f_pub < <(gen_reality_keys)
  f_short=$(gen_shortid)
  f_uuid=$(gen_uuid)

  # 生成：9443(反向) 的 REALITY 密钥 + 短ID（所有隧道共享），每个隧道单独 UUID
  local r_priv r_pub r_short
  IFS=';' read -r r_priv r_pub < <(gen_reality_keys)
  r_short=$(gen_shortid)

  # 生成 VLESS enc/dec（同一组：Portal入站用 decryption；Bridge出站用 encryption）
  local v_dec v_enc
  IFS=';' read -r v_dec v_enc < <(gen_vlessenc "$auth_mode")

  # 收集多隧道配置
  local clients_json="" tunnels_inbounds_json="" route_tunnels_json="" tunnels_output_json=""
  local i=1 ans="n" tunnel_port def_tunnel_port=31234 r_uuid
  while true; do
    tunnel_port=$(ask_port "隧道入口端口(通过 http://portal:此端口 访问 Bridge 本地服务)" "$def_tunnel_port")
    r_uuid=$(gen_uuid)

    # external-vless 的多客户端（每个隧道一个 reverse tag）
    local c
    c=$(cat <<EOC
{ "email":"bridge-rev-${i}", "id":"${r_uuid}", "flow":"xtls-rprx-vision", "reverse":{"tag":"r-outbound-${i}"} }
EOC
)
    if [[ -z "$clients_json" ]]; then clients_json="$c"; else clients_json="$clients_json, $c"; fi

    # 对应的 tunnel inbound 与路由
    local tinb rr
    tinb=$(cat <<EOI
{ "listen":"0.0.0.0", "port":${tunnel_port}, "protocol":"tunnel", "tag":"t-inbound-${i}" }
EOI
)
    if [[ -z "$tunnels_inbounds_json" ]]; then tunnels_inbounds_json="$tinb"; else tunnels_inbounds_json="$tunnels_inbounds_json, $tinb"; fi

    rr=$(cat <<EOR
{ "inboundTag":["t-inbound-${i}"], "outboundTag":"r-outbound-${i}" }
EOR
)
    if [[ -z "$route_tunnels_json" ]]; then route_tunnels_json="$rr"; else route_tunnels_json="$route_tunnels_json, $rr"; fi

    # 输出 JSON 用：包含该隧道的全部信息
    local tout
    tout=$(cat <<EOJ
{ "tunnel_port": ${tunnel_port}, "reverse": { "address": "${addr}", "port": ${port_rev}, "id": "${r_uuid}", "serverName": "${sni_rev}", "publicKey": "${r_pub}", "shortId": "${r_short}", "encryption": "${v_enc}", "flow": "xtls-rprx-vision" } }
EOJ
)
    if [[ -z "$tunnels_output_json" ]]; then tunnels_output_json="$tout"; else tunnels_output_json="$tunnels_output_json, $tout"; fi

    # 是否继续
    ans=$(ask "是否继续添加下一个反向隧道? [y/N]" "n")
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      i=$((i+1))
      def_tunnel_port=$((tunnel_port+1))
      continue
    else
      break
    fi
  done

  # 写入 Portal 配置（含 API + 443 正向 + 9443 反向 + 多个 tunnel）
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
      ${route_tunnels_json},
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
      "port": ${port_fwd},
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
      "port": ${port_rev},
      "protocol": "vless",
      "settings": {
        "clients": [ ${clients_json} ],
        "decryption": "none"
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
    ${tunnels_inbounds_json}
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF

  if xray_validate; then ok "配置校验通过"; else exit 1; fi
  restart_xray

  # 输出连接参数（Bridge 脚本将解析）
  local first_tunnel_port first_reverse_id
  first_tunnel_port=$(jq -r '.[0].tunnel_port' <<< "[${tunnels_output_json}]" 2>/dev/null || true)
  first_reverse_id=$(jq -r '.[0].reverse.id'    <<< "[${tunnels_output_json}]" 2>/dev/null || true)

  cat <<JSON

================= 连接参数（请复制到 Bridge 脚本） =================
{
  "portal_addr": "${addr}",
  "auth": "${auth_mode}",
  "tunnel_port": ${first_tunnel_port:-31234},
  "forward": {
    "address": "${addr}",
    "port": ${port_fwd},
    "id": "${f_uuid}",
    "serverName": "${sni_fwd}",
    "publicKey": "${f_pub}",
    "shortId": "${f_short}",
    "flow": "xtls-rprx-vision"
  },
  "reverse": {
    "address": "${addr}",
    "port": ${port_rev},
    "id": "${first_reverse_id}",
    "serverName": "${sni_rev}",
    "publicKey": "${r_pub}",
    "shortId": "${r_short}",
    "encryption": "${v_enc}",
    "flow": "xtls-rprx-vision"
  },
  "tunnels": [ ${tunnels_output_json} ]
}
===================================================================
JSON

  ok "Portal 完成。已生成多隧道参数。请把以上 JSON 原样复制，粘贴到 Bridge 脚本提示处。"
}

make_bridge() {
  need_root; detect_pm; ensure_tools; install_xray; ensure_layout; report_existing_state; bkp_cfg

  warn "请粘贴从 Portal 输出的连接参数 JSON，粘贴结束后按 Ctrl-D："
  local tmp=$(mktemp)
  cat > "$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then err "粘贴的不是有效 JSON"; exit 1; fi

  local paddr auth f_id f_sni f_pub f_sid f_port f_flow
  local r_id r_sni r_pub r_sid r_port r_enc r_flow
  local p_tunnel_port
  local tunnels_count

  paddr=$(jq -r '.portal_addr' "$tmp")
  auth=$(jq -r '.auth' "$tmp")
  p_tunnel_port=$(jq -r '.tunnel_port // empty' "$tmp")
  if [[ -z "$p_tunnel_port" || "$p_tunnel_port" == "null" ]]; then p_tunnel_port=31234; fi
  tunnels_count=$(jq -r '(.tunnels | length) // 0' "$tmp")
  # forward (可选)
  f_id=$(jq -r '.forward.id' "$tmp")
  f_sni=$(jq -r '.forward.serverName' "$tmp")
  f_pub=$(jq -r '.forward.publicKey' "$tmp")
  f_sid=$(jq -r '.forward.shortId' "$tmp")
  f_port=$(jq -r '.forward.port' "$tmp")
  f_flow=$(jq -r '.forward.flow' "$tmp")
  # 单隧道兼容（当 tunnels 为空时读取 legacy 字段）
  if [[ "$tunnels_count" -eq 0 ]]; then
    r_id=$(jq -r '.reverse.id' "$tmp")
    r_sni=$(jq -r '.reverse.serverName' "$tmp")
    r_pub=$(jq -r '.reverse.publicKey' "$tmp")
    r_sid=$(jq -r '.reverse.shortId' "$tmp")
    r_port=$(jq -r '.reverse.port' "$tmp")
    r_enc=$(jq -r '.reverse.encryption' "$tmp")
    r_flow=$(jq -r '.reverse.flow' "$tmp")
    # 兼容：若未提供或为空，则回退为 none
    if [[ -z "$r_enc" || "$r_enc" == "null" ]]; then r_enc="none"; fi
  fi

  # 是否要配置本地 Socks 正向上网（走 443）
  local with_socks; with_socks=$(ask "是否配置本地 Socks5(127.0.0.1:10808) 并走 Portal:443 正向代理? [y/n]" "y")

  # 生成 Bridge 配置（支持多隧道）
  local inbounds_json="" outbounds_json="" routes_json=""
  # inbounds：可选 socks-in
  if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
    inbounds_json='{ "tag":"socks-in","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true} }'
  fi

  # outbounds：起始 direct 默认
  outbounds_json='{ "protocol":"direct","tag":"default" }'

  # forward 代理出站（可选）
  if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
    local fwd_out
    fwd_out=$(cat <<FWD
{ "tag": "proxy", "protocol": "vless",
  "settings": {
    "vnext": [ { "address": "${paddr}", "port": ${f_port},
      "users": [ { "id": "${f_id}", "encryption": "none", "flow": "${f_flow}" } ] } ]
  },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "serverName": "${f_sni}", "publicKey": "${f_pub}", "shortId": "${f_sid}", "fingerprint": "chrome", "spiderX": "/" } },
  "mux": { "enabled": false } }
FWD
)
    outbounds_json="$outbounds_json, $fwd_out"
  fi

  if [[ "$tunnels_count" -gt 0 ]]; then
    # 多隧道模式
    local idx=0 def_map_port=80
    while [[ $idx -lt $tunnels_count ]]; do
      local t_port r_id_i r_sni_i r_pub_i r_sid_i r_port_i r_enc_i r_flow_i map_port_i
      t_port=$(jq -r ".tunnels[$idx].tunnel_port" "$tmp")
      r_id_i=$(jq -r ".tunnels[$idx].reverse.id" "$tmp")
      r_sni_i=$(jq -r ".tunnels[$idx].reverse.serverName" "$tmp")
      r_pub_i=$(jq -r ".tunnels[$idx].reverse.publicKey" "$tmp")
      r_sid_i=$(jq -r ".tunnels[$idx].reverse.shortId" "$tmp")
      r_port_i=$(jq -r ".tunnels[$idx].reverse.port" "$tmp")
      r_enc_i=$(jq -r ".tunnels[$idx].reverse.encryption // \"none\"" "$tmp")
      r_flow_i=$(jq -r ".tunnels[$idx].reverse.flow" "$tmp")

      map_port_i=$(ask_port "Bridge 本地映射端口(供 Portal 隧道 ${t_port} 访问)" "$def_map_port")
      def_map_port=$((map_port_i+1))

      # 本地转发出站 & 反向出站
      local local_web rev_link route
      local_web=$(cat <<LWB
{ "protocol":"freedom","tag":"local-web-${idx}","settings":{"redirect":"127.0.0.1:${map_port_i}"} }
LWB
)
      rev_link=$(cat <<RVK
{ "tag":"rev-link-${idx}", "protocol":"vless",
  "settings": { "address": "${paddr}", "port": ${r_port_i}, "id": "${r_id_i}", "encryption": "${r_enc_i}", "flow": "${r_flow_i}", "reverse": { "tag": "r-inbound-${idx}" } },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "serverName": "${r_sni_i}", "publicKey": "${r_pub_i}", "shortId": "${r_sid_i}", "fingerprint": "chrome", "spiderX": "/" } },
  "mux": { "enabled": false } }
RVK
)
      route=$(cat <<RTE
{ "type":"field", "inboundTag":["r-inbound-${idx}"], "outboundTag":"local-web-${idx}" }
RTE
)
      outbounds_json="$outbounds_json, $local_web, $rev_link"
      if [[ -z "$routes_json" ]]; then routes_json="$route"; else routes_json="$routes_json, $route"; fi

      idx=$((idx+1))
    done
  else
    # 兼容：单隧道模式
    local map_port
    map_port=$(ask_port "Bridge 本地映射端口(将被 Portal 隧道访问)" 80)
    local local_web rev_link route
    local_web=$(cat <<LWB1
{ "protocol":"freedom","tag":"local-web","settings":{"redirect":"127.0.0.1:${map_port}"} }
LWB1
)
    rev_link=$(cat <<RVK1
{ "tag": "rev-link", "protocol": "vless",
  "settings": { "address": "${paddr}", "port": ${r_port}, "id": "${r_id}", "encryption": "${r_enc}", "flow": "${r_flow}", "reverse": { "tag": "r-inbound" } },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "serverName": "${r_sni}", "publicKey": "${r_pub}", "shortId": "${r_sid}", "fingerprint": "chrome", "spiderX": "/" } },
  "mux": { "enabled": false } }
RVK1
)
    route='{ "type":"field", "inboundTag":["r-inbound"], "outboundTag":"local-web" }'
    outbounds_json="$outbounds_json, $local_web, $rev_link"
    routes_json="$route"
  fi

  # with_socks 的路由
  if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
    local rts
    rts='{ "type":"field", "inboundTag":["socks-in"], "outboundTag":"proxy" }'
    if [[ -z "$routes_json" ]]; then routes_json="$rts"; else routes_json="$routes_json, $rts"; fi
  fi

  # 写入完整配置
  cat > "$XRAY_CFG" <<CFG
{
  "log": { "loglevel": "info", "error": "/var/log/xray/error.log", "access": "/var/log/xray/access.log" },
  "inbounds": [ ${inbounds_json} ],
  "outbounds": [ ${outbounds_json} ],
  "routing": { "rules": [ ${routes_json} ] }
}
CFG

  if xray_validate; then ok "配置校验通过"; else exit 1; fi
  restart_xray

  ok "Bridge 完成。现在："
  if [[ "$with_socks" == "y" || "$with_socks" == "Y" ]]; then
    echo "  * 本机 SOCKS5: 127.0.0.1:10808 (curl --socks5 127.0.0.1:10808 http://ip-api.com/json)"
  fi
  local paddr_disp="$paddr"; [[ "$paddr" == *:* ]] && paddr_disp="[$paddr]"
  if [[ "$tunnels_count" -gt 0 ]]; then
    # 输出每条隧道的入口提示
    local idx=0
    while [[ $idx -lt $tunnels_count ]]; do
      local t_port_i
      t_port_i=$(jq -r ".tunnels[$idx].tunnel_port" "$tmp")
      echo "  * 反向隧道入口：访问 http://${paddr_disp}:${t_port_i} 将被转发到 Bridge 的本地映射端口"
      idx=$((idx+1))
    done
  else
    echo "  * 反向隧道入口：访问 http://${paddr_disp}:${p_tunnel_port} 将被转发到 Bridge 的本地服务"
  fi
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
