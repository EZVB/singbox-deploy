#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f /etc/sing-box/.config_cache ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
    info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local-dns"
      }
    ],
    "final": "local-dns"
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    },
    {
      "type": "block",
      "tag": "block-out"
    }
  ],
  "route": {
    "rules": [],
    "final": "direct-out",
    "default_domain_resolver": "local-dns"
  }
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_PSK=$PSK_TUIC
TUIC_UUID=$UUID_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
REALITY_SNI=$REALITY_SNI
CACHEEOF

    [ -n "${CUSTOM_IP:-}" ] && echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache
}

create_config

# -----------------------
# 获取公网IP
get_public_ip() {
    local ip
    ip=$(curl -s https://api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s https://ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s https://icanhazip.com 2>/dev/null || true)
    ip=$(echo "$ip" | tr -d '\r\n[:space:]')
    echo "$ip"
}

# -----------------------
# 生成客户端URI/链接
generate_uris() {
    info "生成客户端连接信息..."
    
    # 使用用户输入的IP/DDNS或自动检测公网IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="${CUSTOM_IP}"
        info "使用用户指定连接地址: $PUBLIC_IP"
    else
        PUBLIC_IP=$(get_public_ip)
        if [ -z "$PUBLIC_IP" ]; then
            warn "无法获取公网IP,请手动修改链接中的IP"
            PUBLIC_IP="YOUR_SERVER_IP"
        fi
        info "自动检测公网IP: $PUBLIC_IP"
    fi
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    # 读取节点名称后缀
    suffix=""
    [ -f /root/node_names.txt ] && suffix=$(cat /root/node_names.txt)
    
    # 生成SS URI
    if $ENABLE_SS; then
        if [ "$SS_METHOD" = "2022-blake3-aes-128-gcm" ]; then
            # 2022-blake3-aes-128-gcm 使用 userinfo 直接 base64 编码 method:password
            SS_INFO=$(printf "%s:%s" "$SS_METHOD" "$PSK_SS" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            SS_URI="ss://${SS_INFO}@${PUBLIC_IP}:${PORT_SS}#SS${suffix}"
        else
            # 普通 aead 方式也使用 method:password base64 编码
            SS_INFO=$(printf "%s:%s" "$SS_METHOD" "$PSK_SS" | base64 | tr -d '\n')
            SS_URI="ss://${SS_INFO}@${PUBLIC_IP}:${PORT_SS}#SS${suffix}"
        fi
        echo "===== Shadowsocks (SS) =====" >> "$URI_FILE"
        echo "$SS_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    # 生成HY2 URI
    if $ENABLE_HY2; then
        HY2_URI="hysteria2://${PSK_HY2}@${PUBLIC_IP}:${PORT_HY2}/?insecure=1&sni=www.bing.com#HY2${suffix}"
        echo "===== Hysteria2 (HY2) =====" >> "$URI_FILE"
        echo "$HY2_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    # 生成TUIC URI
    if $ENABLE_TUIC; then
        TUIC_URI="tuic://${UUID_TUIC}:${PSK_TUIC}@${PUBLIC_IP}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=www.bing.com#TUIC${suffix}"
        echo "===== TUIC =====" >> "$URI_FILE"
        echo "$TUIC_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    # 生成VLESS Reality URI
    if $ENABLE_REALITY; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub 2>/dev/null || echo "")
        REALITY_SID=$(cat /etc/sing-box/.reality_sid 2>/dev/null || echo "")
        REALITY_URI="vless://${UUID}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
        echo "===== VLESS Reality =====" >> "$URI_FILE"
        echo "$REALITY_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    # 生成AnyTLS Reality URI
    if $ENABLE_ANYTLS; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub 2>/dev/null || echo "")
        REALITY_SID=$(cat /etc/sing-box/.reality_sid 2>/dev/null || echo "")
        ANYTLS_URI="anytls://${ANYTLS_USER}:${ANYTLS_PSK}@${PUBLIC_IP}:${PORT_ANYTLS}/?sni=${REALITY_SNI}&security=reality&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#AnyTLS${suffix}"
        echo "===== AnyTLS Reality =====" >> "$URI_FILE"
        echo "$ANYTLS_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    info "连接信息已保存到: $URI_FILE"
}

generate_uris

# -----------------------
# 配置服务管理
setup_service() {
    info "配置服务管理..."
    
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart || rc-service sing-box start
    else
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$(command -v sing-box) run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
    fi
    
    info "服务配置完成并已启动"
}

setup_service

# -----------------------
# 输出结果
show_results() {
    echo ""
    info "✅ Sing-box 部署完成!"
    echo "========================================"
    cat /etc/sing-box/uris.txt
    echo "========================================"
    echo ""
    info "💡 连接信息文件: /etc/sing-box/uris.txt"
    info "💡 配置文件路径: /etc/sing-box/config.json"
    info "💡 管理脚本路径: /usr/local/bin/sb"
    info "💡 使用方法: 输入 sb 打开管理面板"
}

show_results

# -----------------------
# 生成管理脚本 sb
SB_PATH="/usr/local/bin/sb"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="/etc/sing-box/config.json"
URI_FILE="/etc/sing-box/uris.txt"
CACHE_FILE="/etc/sing-box/.config_cache"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
else
    OS_ID=""
    OS_ID_LIKE=""
fi

if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
    OS="alpine"
elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
    OS="debian"
elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
    OS="redhat"
else
    OS="unknown"
fi

# 服务控制函数
service_start() {
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box start
    else
        systemctl start sing-box
    fi
}

service_stop() {
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box stop
    else
        systemctl stop sing-box
    fi
}

service_restart() {
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box restart
    else
        systemctl restart sing-box
    fi
}

service_status() {
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box status || true
    else
        systemctl status sing-box --no-pager || true
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s https://api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s https://ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s https://icanhazip.com 2>/dev/null || true)
    ip=$(echo "$ip" | tr -d '\r\n[:space:]')
    echo "$ip"
}

read_config() {
    [ -f "$CACHE_FILE" ] && . "$CACHE_FILE"
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

list_outbound_tags() {
    jq -r '.outbounds[]?.tag // empty' "$CONFIG_PATH"
}

outbound_exists() {
    local tag="$1"
    jq -e --arg tag "$tag" '.outbounds[]? | select(.tag == $tag)' "$CONFIG_PATH" >/dev/null
}

print_outbounds() {
    jq -r '
      .outbounds[]?
      | [
          (.tag // "-"),
          (.type // "-"),
          (.server // "-"),
          ((.server_port // 0) | tostring),
          (.detour // "-")
        ]
      | @tsv
    ' "$CONFIG_PATH" | while IFS=$'\t' read -r tag type server port detour; do
        printf "- %-18s type=%-12s server=%-24s port=%-8s detour=%s\n" "$tag" "$type" "$server" "$port" "$detour"
    done
}

select_outbound_tag() {
    local prompt="$1"
    local default_tag="${2:-}"
    local allow_blank="${3:-false}"
    local tags
    mapfile -t tags < <(list_outbound_tags)

    if [ "${#tags[@]}" -eq 0 ]; then
        err "当前没有可用出站"
        return 1
    fi

    echo "$prompt"
    local idx=1
    for tag in "${tags[@]}"; do
        echo "$idx) $tag"
        idx=$((idx + 1))
    done
    [ "$allow_blank" = "true" ] && echo "0) 保持空"
    if [ -n "$default_tag" ]; then
        read -p "请输入编号(回车默认 $default_tag): " choice
    else
        read -p "请输入编号: " choice
    fi

    if [ -z "$choice" ]; then
        if [ -n "$default_tag" ]; then
            echo "$default_tag"
            return 0
        fi
        err "必须选择一个出站"
        return 1
    fi

    if [ "$allow_blank" = "true" ] && [ "$choice" = "0" ]; then
        echo ""
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        err "无效编号"
        return 1
    fi

    echo "${tags[$((choice - 1))]}"
}

backup_config() {
    local backup
    backup="${CONFIG_PATH}.bak.$(date +%s)"
    cp "$CONFIG_PATH" "$backup"
    echo "$backup"
}

check_and_restart_or_restore() {
    local backup="$1"

    if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        info "配置验证通过，正在重启 sing-box..."
        if service_restart; then
            info "重启完成"
            rm -f "$backup"
            generate_uris || true
            return 0
        fi
        warn "重启失败，已恢复旧配置"
    else
        warn "配置验证失败，已恢复旧配置"
    fi

    cp "$backup" "$CONFIG_PATH"
    service_restart || true
    return 1
}

csv_to_json_array() {
    local input="$1"
    echo "$input" | awk -F',' '
        {
            printf("[")
            first=1
            for (i=1; i<=NF; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", $i)
                if ($i != "") {
                    if (!first) printf(",")
                    gsub(/\\/, "\\\\", $i)
                    gsub(/"/, "\\\"", $i)
                    printf("\"%s\"", $i)
                    first=0
                }
            }
            printf("]")
        }
    '
}

would_create_detour_cycle() {
    local source="$1"
    local target="$2"
    local current="$target"
    local next

    while [ -n "$current" ]; do
        [ "$current" = "$source" ] && return 0
        next=$(jq -r --arg tag "$current" '.outbounds[]? | select(.tag == $tag) | .detour // empty' "$CONFIG_PATH" | head -n1)
        current="$next"
    done

    return 1
}

# 重新生成 URIs
generate_uris() {
    read_config
    
    # 使用用户输入的IP/DDNS或自动检测公网IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="${CUSTOM_IP}"
    else
        PUBLIC_IP=$(get_public_ip)
        [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"
    fi
    
    > "$URI_FILE"
    suffix=""
    [ -f /root/node_names.txt ] && suffix=$(cat /root/node_names.txt)
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        if [ "$SS_METHOD" = "2022-blake3-aes-128-gcm" ]; then
            SS_INFO=$(printf "%s:%s" "$SS_METHOD" "$SS_PSK" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            SS_URI="ss://${SS_INFO}@${PUBLIC_IP}:${SS_PORT}#SS${suffix}"
        else
            SS_INFO=$(printf "%s:%s" "$SS_METHOD" "$SS_PSK" | base64 | tr -d '\n')
            SS_URI="ss://${SS_INFO}@${PUBLIC_IP}:${SS_PORT}#SS${suffix}"
        fi
        echo "===== Shadowsocks (SS) =====" >> "$URI_FILE"
        echo "$SS_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_URI="hysteria2://${HY2_PSK}@${PUBLIC_IP}:${HY2_PORT}/?insecure=1&sni=www.bing.com#HY2${suffix}"
        echo "===== Hysteria2 (HY2) =====" >> "$URI_FILE"
        echo "$HY2_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_URI="tuic://${TUIC_UUID}:${TUIC_PSK}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=www.bing.com#TUIC${suffix}"
        echo "===== TUIC =====" >> "$URI_FILE"
        echo "$TUIC_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub 2>/dev/null || echo "")
        REALITY_SID=$(cat /etc/sing-box/.reality_sid 2>/dev/null || echo "")
        REALITY_URI="vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
        echo "===== VLESS Reality =====" >> "$URI_FILE"
        echo "$REALITY_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub 2>/dev/null || echo "")
        REALITY_SID=$(cat /etc/sing-box/.reality_sid 2>/dev/null || echo "")
        ANYTLS_URI="anytls://${ANYTLS_USER}:${ANYTLS_PSK}@${PUBLIC_IP}:${ANYTLS_PORT}/?sni=${REALITY_SNI}&security=reality&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#AnyTLS${suffix}"
        echo "===== AnyTLS Reality =====" >> "$URI_FILE"
        echo "$ANYTLS_URI" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
}

# 查看协议链接
action_view_uri() {
    if [ -f "$URI_FILE" ]; then
        cat "$URI_FILE"
    else
        err "未找到连接信息文件"
    fi
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置文件
action_edit_config() {
    ${EDITOR:-vi} "$CONFIG_PATH"
}

action_show_routing() {
    echo "===== 当前出站列表 ====="
    print_outbounds
    echo ""
    echo "===== 当前 route 配置 ====="
    jq '.route // {}' "$CONFIG_PATH"
}

action_add_proxy_outbound() {
    local backup tag type server port username password method uuid tls_server_name reality_public_key reality_short_id
    local tmp_file="${CONFIG_PATH}.tmp"

    backup=$(backup_config)

    read -p "请输入新出站标签(tag)，例如 proxy-out: " tag
    tag="$(echo "$tag" | tr -d '[:space:]')"
    if [ -z "$tag" ]; then
        err "tag 不能为空"
        rm -f "$backup"
        return 1
    fi
    if outbound_exists "$tag"; then
        err "出站标签已存在: $tag"
        rm -f "$backup"
        return 1
    fi

    echo "请选择出站类型:"
    echo "1) SOCKS5"
    echo "2) HTTP"
    echo "3) Shadowsocks"
    echo "4) VLESS Reality"
    read -p "请输入选项: " type

    read -p "请输入服务器地址: " server
    server="$(echo "$server" | tr -d '[:space:]')"
    [ -z "$server" ] && err "服务器地址不能为空" && rm -f "$backup" && return 1

    read -p "请输入服务器端口: " port
    if ! is_valid_port "$port"; then
        err "端口无效"
        rm -f "$backup"
        return 1
    fi

    case "$type" in
        1)
            read -p "请输入用户名(可留空): " username
            read -p "请输入密码(可留空): " password
            jq --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" '
              .outbounds += [{
                "type": "socks",
                "tag": $tag,
                "server": $server,
                "server_port": $port,
                "version": "5"
              }]
              | if $username != "" then .outbounds[-1].username = $username else . end
              | if $password != "" then .outbounds[-1].password = $password else . end
            ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
            ;;
        2)
            read -p "请输入用户名(可留空): " username
            read -p "请输入密码(可留空): " password
            jq --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" '
              .outbounds += [{
                "type": "http",
                "tag": $tag,
                "server": $server,
                "server_port": $port
              }]
              | if $username != "" then .outbounds[-1].username = $username else . end
              | if $password != "" then .outbounds[-1].password = $password else . end
            ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
            ;;
        3)
            echo "请选择 Shadowsocks 加密方式:"
            echo "1) 2022-blake3-aes-128-gcm"
            echo "2) aes-128-gcm"
            read -p "请输入选项(默认 1): " method_choice
            case "${method_choice:-1}" in
                1) method="2022-blake3-aes-128-gcm" ;;
                2) method="aes-128-gcm" ;;
                *) err "无效选项"; cp "$backup" "$CONFIG_PATH"; return 1 ;;
            esac
            read -p "请输入密码: " password
            [ -z "$password" ] && err "密码不能为空" && cp "$backup" "$CONFIG_PATH" && return 1
            jq --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" '
              .outbounds += [{
                "type": "shadowsocks",
                "tag": $tag,
                "server": $server,
                "server_port": $port,
                "method": $method,
                "password": $password
              }]
            ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
            ;;
        4)
            read -p "请输入 UUID: " uuid
            [ -z "$uuid" ] && err "UUID 不能为空" && cp "$backup" "$CONFIG_PATH" && return 1
            read -p "请输入 Reality SNI: " tls_server_name
            tls_server_name="${tls_server_name:-addons.mozilla.org}"
            read -p "请输入 Reality Public Key: " reality_public_key
            [ -z "$reality_public_key" ] && err "Public Key 不能为空" && cp "$backup" "$CONFIG_PATH" && return 1
            read -p "请输入 Reality Short ID(可留空): " reality_short_id
            jq --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg tls_server_name "$tls_server_name" --arg reality_public_key "$reality_public_key" --arg reality_short_id "$reality_short_id" '
              .outbounds += [{
                "type": "vless",
                "tag": $tag,
                "server": $server,
                "server_port": $port,
                "uuid": $uuid,
                "flow": "xtls-rprx-vision",
                "tls": {
                  "enabled": true,
                  "server_name": $tls_server_name,
                  "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                  },
                  "reality": {
                    "enabled": true,
                    "public_key": $reality_public_key
                  }
                }
              }]
              | if $reality_short_id != "" then .outbounds[-1].tls.reality.short_id = $reality_short_id else . end
            ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
            ;;
        *)
            err "无效选项"
            cp "$backup" "$CONFIG_PATH"
            return 1
            ;;
    esac

    check_and_restart_or_restore "$backup"
}

action_set_chain_detour() {
    local backup target detour tmp_file="${CONFIG_PATH}.tmp"

    backup=$(backup_config)

    echo "当前出站列表:"
    print_outbounds
    echo ""

    target="$(select_outbound_tag "请选择要设置上游的出站" "" "false")" || { rm -f "$backup"; return 1; }
    detour="$(select_outbound_tag "请选择该出站的上游 detour(选 0 清空)" "" "true")" || { rm -f "$backup"; return 1; }

    if [ -n "$detour" ] && [ "$target" = "$detour" ]; then
        err "不能把出站的 detour 设置为自己"
        cp "$backup" "$CONFIG_PATH"
        return 1
    fi

    if [ -n "$detour" ] && would_create_detour_cycle "$target" "$detour"; then
        err "此设置会产生 detour 环路，已取消"
        cp "$backup" "$CONFIG_PATH"
        return 1
    fi

    if [ -z "$detour" ]; then
        jq --arg target "$target" '
          .outbounds |= map(if .tag == $target then del(.detour) else . end)
        ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
    else
        jq --arg target "$target" --arg detour "$detour" '
          .outbounds |= map(if .tag == $target then .detour = $detour else . end)
        ' "$CONFIG_PATH" > "$tmp_file" && mv "$tmp_file" "$CONFIG_PATH"
    fi

    check_and_restart_or_restore "$backup"
}

action_config_route() {
    local backup mode target values values_json field

    backup=$(backup_config)

    echo "请选择分流模式:"
    echo "1) 全部直连"
    echo "2) 全部走指定出站"
    echo "3) 国内/私网直连，其余走指定出站"
    echo "4) 广告拦截 + 国内/私网直连，其余走指定出站"
    echo "5) 追加自定义规则"
    read -p "请输入选项: " mode

    case "$mode" in
        1)
            jq '
              .route = {
                "rules": [],
                "final": "direct-out",
                "default_domain_resolver": "local-dns"
              }
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ;;
        2)
            target="$(select_outbound_tag "请选择默认出站" "direct-out" "false")" || { cp "$backup" "$CONFIG_PATH"; return 1; }
            jq --arg target "$target" '
              .route = {
                "rules": [],
                "final": $target,
                "default_domain_resolver": "local-dns"
              }
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ;;
        3)
            target="$(select_outbound_tag "请选择国外流量使用的出站" "direct-out" "false")" || { cp "$backup" "$CONFIG_PATH"; return 1; }
            jq --arg target "$target" '
              .route = {
                "rule_set": [
                  {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                    "update_interval": "1d"
                  },
                  {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                    "update_interval": "1d"
                  }
                ],
                "rules": [
                  { "action": "sniff" },
                  { "ip_is_private": true, "action": "route", "outbound": "direct-out" },
                  { "rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct-out" }
                ],
                "final": $target,
                "default_domain_resolver": "local-dns"
              }
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ;;
        4)
            target="$(select_outbound_tag "请选择国外流量使用的出站" "direct-out" "false")" || { cp "$backup" "$CONFIG_PATH"; return 1; }
            jq --arg target "$target" '
              .route = {
                  "rule_set": [
                    {
                      "tag": "geosite-category-ads-all",
                      "type": "remote",
                      "format": "binary",
                      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
                      "update_interval": "1d"
                    },
                    {
                      "tag": "geosite-cn",
                      "type": "remote",
                      "format": "binary",
                      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                      "update_interval": "1d"
                    },
                    {
                      "tag": "geoip-cn",
                      "type": "remote",
                      "format": "binary",
                      "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                      "update_interval": "1d"
                    }
                  ],
                  "rules": [
                    { "action": "sniff" },
                    { "rule_set": ["geosite-category-ads-all"], "action": "route", "outbound": "block-out" },
                    { "ip_is_private": true, "action": "route", "outbound": "direct-out" },
                    { "rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct-out" }
                  ],
                  "final": $target,
                  "default_domain_resolver": "local-dns"
                }
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ;;
        5)
            echo "请选择匹配类型:"
            echo "1) domain_suffix（域名后缀，如 google.com,github.com）"
            echo "2) domain_keyword（域名关键词，如 google,youtube）"
            echo "3) domain（完整域名）"
            echo "4) ip_cidr（IP 段，如 8.8.8.0/24）"
            read -p "请输入选项: " custom_type
            case "$custom_type" in
                1) field="domain_suffix" ;;
                2) field="domain_keyword" ;;
                3) field="domain" ;;
                4) field="ip_cidr" ;;
                *) err "无效匹配类型"; cp "$backup" "$CONFIG_PATH"; return 1 ;;
            esac

            read -p "请输入规则内容，多个用英文逗号分隔: " values
            values_json="$(csv_to_json_array "$values")"
            if [ "$values_json" = "[]" ]; then
                err "规则内容不能为空"
                cp "$backup" "$CONFIG_PATH"
                return 1
            fi

            target="$(select_outbound_tag "请选择该规则使用的出站" "direct-out" "false")" || { cp "$backup" "$CONFIG_PATH"; return 1; }
            jq --arg field "$field" --argjson values "$values_json" --arg target "$target" '
              .route = (.route // {})
              | .route.rules = ((.route.rules // []) + [
                  ({($field): $values, "action": "route", "outbound": $target})
                ])
              | .route.final = (.route.final // "direct-out")
              | .route.default_domain_resolver = (.route.default_domain_resolver // "local-dns")
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ;;
        *)
            err "无效分流模式"
            cp "$backup" "$CONFIG_PATH"
            return 1
            ;;
    esac

    check_and_restart_or_restore "$backup"
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # 检查是否启用了SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            
            # 让用户选择端口
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"
            
            info "SS 端口: $SS_PORT | 密码已自动生成"
            
            info "正在停止服务..."
            service_stop || warn "停止服务失败"
            
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            
            # 添加 SS inbound
            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # 更新缓存和协议标记
            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"
            
            # 同步更新协议标记文件
            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi
            
            # 更新当前会话变量
            ENABLE_SS=true
            
            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1
            
            # 重新读取配置
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi
    
    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-addons.mozilla.org}|g" "$RELAY_SCRIPT"
    
    chmod +x "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    MENU_MAP=()
    local option=4
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    MENU_MAP[$option]="routing_status"
    echo "$option) 查看出站/分流状态"
    option=$((option + 1))

    MENU_MAP[$option]="add_outbound"
    echo "$option) 新增代理出站节点"
    option=$((option + 1))

    MENU_MAP[$option]="chain_detour"
    echo "$option) 设置/取消链式代理"
    option=$((option + 1))

    MENU_MAP[$option]="route_config"
    echo "$option) 配置分流规则"
    option=$((option + 1))

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                routing_status) action_show_routing ;;
                add_outbound) action_add_proxy_outbound ;;
                chain_detour) action_set_chain_detour ;;
                route_config) action_config_route ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
