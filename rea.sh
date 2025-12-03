#!/bin/bash
BASEURL="https://gitea.com/pinkdog/xrayinstaller/raw/branch/main/"
export XRAYVER=""
# Check OS
if [[ ! -f /etc/debian_version ]]; then
	echo "此脚本仅适用于 Debian/Ubuntu"
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "此简易脚本仅限 root 用户运行"
	exit 1
fi

SEED=${SEED:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}
PORT=${PORT:-"443"}
UPDATE=1

if [[ -f /usr/local/bin/xray && $1 == "@lock" ]]; then
	UPDATE=0
fi

has_ipv6_github() {
	ping -6 -c1 -w2 api.github.com >/dev/null 2>&1
}

add_github_ipv6_hosts() {
	# 添加 GitHub IPv6 访问
	sed -i '/^# ==== GitHub IPv6 fallback ====$/,/^# ==== End GitHub IPv6 fallback ====$/d' /etc/hosts
	if has_ipv6_github; then
		return
	fi

	status=$(curl -sS --resolve "api.github.com:443:2a01:4f8:c010:d56::3" --max-time 5 -o /dev/null -w "%{http_code}" "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null || echo "")
	# api.github.com 不成功时的处理
	if [[ "$status" != "200" && $UPDATE -eq 1 ]]; then
		echo "现在无法获取Xray版本号，请手动设置或稍后再试"
		read -rp "例如 v25.10.15 留空脚本将退出：" version_input
		if [[ -z "$version_input" ]]; then
			exit 1
		else
			XRAYVER="--version $version_input"
		fi
	fi

	echo "setting GitHub IPv6 hosts"
	cat <<EOF >>/etc/hosts
# ==== GitHub IPv6 fallback ====
2a01:4f8:c010:d56::2 github.com
2a01:4f8:c010:d56::3 api.github.com
2a01:4f8:c010:d56::4 codeload.github.com
2a01:4f8:c010:d56::6 ghcr.io
2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com
2a01:4f8:c010:d56::8 uploads.github.com
2606:50c0:8000::133 objects.githubusercontent.com www.objects.githubusercontent.com release-assets.githubusercontent.com gist.githubusercontent.com repository-images.githubusercontent.com camo.githubusercontent.com private-user-images.githubusercontent.com avatars0.githubusercontent.com avatars1.githubusercontent.com avatars2.githubusercontent.com avatars3.githubusercontent.com cloud.githubusercontent.com desktop.githubusercontent.com support.github.com
2606:50c0:8000::154 support-assets.githubassets.com github.githubassets.com opengraph.githubassets.com github-registry-files.githubusercontent.com github-cloud.githubusercontent.com
# ==== End GitHub IPv6 fallback ====
EOF
}

get_warp_outbound_config() {
	# 生成WARP出口配置
	local CONFIG_FILE="./warp-config.json"
		if [[ -f "$CONFIG_FILE" ]]; then
		local WARP_JSON=$(cat "$CONFIG_FILE")
	else
		local WARP_JSON=$(bash -c "$(curl -L https://github.com/chise0713/warp-reg.sh/raw/refs/heads/master/warp-reg.sh)")
		echo "$WARP_JSON" >"$CONFIG_FILE"
	fi

	local PRIVATE_KEY=$(echo "$WARP_JSON" | jq -r '.private_key')
	local PUBLIC_KEY=$(echo "$WARP_JSON" | jq -r '.public_key')
	local V4=$(echo "$WARP_JSON" | jq -r '.v4')
	local V6=$(echo "$WARP_JSON" | jq -r '.v6')
	local ENDPOINT_V6=$(echo "$WARP_JSON" | jq -r '.endpoint.v6')
	local RESERVED=$(echo "$WARP_JSON" | jq -c '.reserved_dec')

	local OUTBOUND_CONFIG=$(
		cat <<EOF
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "$PRIVATE_KEY",
        "address": [
          "$V4/32",
          "$V6/128"
        ],
        "peers": [
          {
            "publicKey": "$PUBLIC_KEY",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "$ENDPOINT_V6:500",
            "keepAlive": 25
          }
        ],
        "reserved": $RESERVED,
        "mtu": 1280,
        "domainStrategy": "ForceIP"
      }
    }
  ]
EOF
	)
	echo "$OUTBOUND_CONFIG"
}

# 获取基本网络信息
TRACE4=$(curl -4 -s https://dash.cloudflare.com/cdn-cgi/trace)
TRACE6=$(curl -6 -s https://dash.cloudflare.com/cdn-cgi/trace)
TRACE="${TRACE4:-$TRACE6}"

IPV4=$(echo "$TRACE4" | grep '^ip=' | cut -d= -f2)
IPV6=$(echo "$TRACE6" | grep '^ip=' | cut -d= -f2)
TS=$(echo "$TRACE" | grep '^ts=' | cut -d= -f2 | cut -d. -f1)
WARP=$(echo "$TRACE" | grep '^warp=' | cut -d= -f2)
COLO=$(echo "$TRACE" | grep '^colo=' | cut -d= -f2)

# 当检测到warp时且HOST未设置时，询问用户HOST值
if [[ "$WARP" != "off" && -z "$HOST" ]]; then
	echo "无法获取本机IP地址，请手动输入HOST用于生成节点链接"
	read -rp "DDNS域名或者IP: " HOST
	# 如果HOST是IPv6地址，确保加上中括号
	if [[ "$HOST" == *:* && "$HOST" != *\]* ]]; then
		HOST="[$HOST]"
	fi
fi

# 当没有IPv4时，引导用户选择是否使用WARP出站。
if [[ -z "$IPV4" ]]; then
	read -rp "IPv6 only的机器，是否使用Cloudflare WARP出口流量? (Y/n): " warp_choice
fi

# 当没有SNI时，交互式引导用户设置一个域名。
if [[ -z "$SNI" ]]; then
    echo "必须设置SNI，使用您自己的域名或创作一个假想域名"
	read -rp "请输入想使用的SNI: " SNI
fi

is_valid_domain() {
	local domain="$1"
	IFS='.' read -ra parts <<<"$domain"
	for part in "${parts[@]}"; do
		[[ -z "$part" ]] && return 1
		[[ "$part" == -* || "$part" == *- ]] && return 1
		if ! [[ "$part" =~ ^[a-zA-Z0-9-]+$ ]]; then
			return 1
		fi
	done

	return 0
}

while ! is_valid_domain "$SNI"; do
	read -rp "SNI格式不合法，请重新输入: " SNI
done

# 检查SNI域名解析
DNS_IPV4=$(curl -s "https://dns.google/resolve?name=${SNI}&type=A" | grep -oP '"data":"\K[^"]+' | head -1)
DNS_IPV6=$(curl -s "https://dns.google/resolve?name=${SNI}&type=AAAA" | grep -oP '"data":"\K[^"]+' | head -1)

AUTOTLS="tls internal"
# SNI解析匹配本机IP时，自动申请可信任证书
if [[ "$IPV4" == "$DNS_IPV4" ]] || [[ "$IPV6" == "$DNS_IPV6" ]]; then
	echo -e "\033[32m检测到 ${SNI} 解析到本机，即将自动申请可信任证书...\033[0m"
	echo -e "\033[32m如不需要请即刻使用 Ctrl+C 终止\033[0m"
	for ((i = 10; i > 0; i--)); do
		echo -ne "\r${i}  "
		sleep 1
	done
	AUTOTLS=""
fi

# 安装基础组件
apt update -qq
apt install -qq -y unzip qrencode vim xxd jq gpg

# 配置outbound
OUTBOUND=$(
	cat <<EOF
"outbounds": [
    {
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIPv4v6"},
      "tag": "direct"
    }
  ]
EOF
)
OUTBOUNDV6=$(
	cat <<EOF
"outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
EOF
)

# 针对v6only的机器的处理
if [[ -z "$IPV4" ]]; then
	add_github_ipv6_hosts
	if [[ "${warp_choice}" == "n" ]] || [[ "${warp_choice}" == "N" ]]; then
		OUTBOUND=$OUTBOUNDV6
	else
		OUTBOUND=$(get_warp_outbound_config)
	fi
elif [[ "$WARP" != "off" ]]; then
	# 若本机为WARP全局则优先使用v6出口
	OUTBOUND=$OUTBOUNDV6
fi

# Install Xray
if [[ $UPDATE -eq 1 ]]; then
	bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install $XRAYVER
fi

UUID=$(xray uuid -i $SEED)

args=("$@")
# Generate guest accounts if needed
if [[ ${#args[@]} -gt 0 ]]; then
	guests=""
	for arg in "${args[@]}"; do
		if [[ ${#arg} -gt 20 ]]; then
			echo "一些参数过长"
			exit 1
		fi

		if [[ "$arg" == "@lock" ]]; then
			continue
		fi

		guest_uuid=$(xray uuid -i "${arg}")
		guests+=", { \"id\": \"${guest_uuid}\", \"email\": \"${arg}\", \"flow\": \"xtls-rprx-vision\" }"
		((i++))
	done
fi

CADDYPORT=$((RANDOM + 10000))
if [[ $AUTOTLS == "tls internal" ]]; then
	CADDYPORT=444
	BINDLOCAL="bind 127.0.0.1 [::1]"
	warning000="Caddy 监听在 127.0.0.1:444 可用作其他配置的DEST"
else
	warning000="Caddy 监听在随机端口，并可能在重装后改变"
fi
DEST="127.0.0.1:$CADDYPORT"

# Install Caddy
if [[ -f /etc/caddy/Caddyfile ]]; then
	mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.$TS.bak
	warning001="Backup of previous Caddyfile created at /etc/caddy/Caddyfile.$TS.bak"
fi
if [[ $UPDATE -eq 1 ]]; then
	apt install -qq -y debian-keyring debian-archive-keyring apt-transport-https
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
	chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	chmod o+r /etc/apt/sources.list.d/caddy-stable.list
	apt update -qq
	apt install -qq -y caddy
fi
# Caddyfile
cat >/etc/caddy/Caddyfile <<-EOF
	{
	        skip_install_trust
	        auto_https disable_redirects
	        servers {
	                protocols h1 h2
	        }
	}

	https://${SNI}:${CADDYPORT} {
	    ${AUTOTLS}
	    ${BINDLOCAL} 
	    respond "" 200
	}
EOF
systemctl enable caddy
systemctl restart caddy

# Deriving public and private keys.
priv_hex=$(echo -n "$SEED" | sha256sum | cut -c1-64)
priv_b64=$(echo "$priv_hex" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=')
tmp_key=$(xray x25519 -i "$priv_b64")
private_key=$(echo "$tmp_key" | awk -F': *' '/^PrivateKey:/ {print $2}')
public_key=$(echo "$tmp_key" | awk -F': *' '/^Password:/   {print $2}')

# Xray config.json
if [[ -f /usr/local/etc/xray/config.json ]]; then
	mv /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.$TS.bak
	warning002="Backup of previous config.json created at /usr/local/etc/xray/config.json.$TS.bak"
fi

cat >/usr/local/etc/xray/config.json <<-EOF
	{
	  "log": {
	    "access": "none",
	    "error": "/var/log/xray/error.log",
	    "loglevel": "warning"
	  },
	  "stats": {},
	  "policy": {
	    "levels": {
	      "0": {
	        "statsUserUplink": true,
	        "statsUserDownlink": true
	      }
	    },
	    "system": {
	      "statsInboundUplink": true,
	      "statsInboundDownlink": true
	    }
	  },
	  "api": {
	    "tag": "api",
	    "services": ["StatsService"]
	  },
	  "inbounds": [
	    {
	      "listen": "0.0.0.0",
	      "port": ${PORT},
	      "protocol": "vless",
	      "settings": {
	        "clients": [
	          { "id": "${UUID}", "email": "admin@example.com", "flow": "xtls-rprx-vision" }${guests}
	        ],
	        "decryption": "none"
	      },
	      "streamSettings": {
	        "network": "tcp",
	        "security": "reality",
	        "realitySettings": {
	          "show": false,
	          "dest": "${DEST}",
	          "xver": 0,
	          "serverNames": ["${SNI}"],
	          "privateKey": "${private_key}",
	          "shortIds": [""]
	        }
	      }
	    },
	    {
	      "listen": "127.0.0.1",
	      "port": 10085,
	      "protocol": "dokodemo-door",
	      "settings": {
	        "address": "127.0.0.1"
	      },
	      "tag": "api-in"
	    }
	  ],
	  ${OUTBOUND},
	  "routing": {
	    "domainStrategy": "AsIs",
	    "rules": [
	      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }
	    ]
	  }
	}
EOF

systemctl enable xray
systemctl restart xray

# enable BBR
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
sysctl -p

# 调试信息
systemctl status xray --no-pager -l
systemctl status caddy --no-pager -l

# 清理 GitHub IPv6 临时设置
sed -i '/^# ==== GitHub IPv6 fallback ====$/,/^# ==== End GitHub IPv6 fallback ====$/d' /etc/hosts

# 生成 VLESS Reality URL
insert="SEED=$SEED SNI=$SNI"
[[ $PORT -ne 443 ]] && insert+=" PORT=$PORT"

if [[ -z "$HOST" ]]; then
	if [[ -z "$IPV4" ]]; then
		HOST="[$IPV6]"
	else
		HOST=$IPV4
	fi
else
	insert+=" HOST=$HOST"
fi

vless_reality_url="vless://${UUID}@${HOST}:${PORT}?flow=xtls-rprx-vision&type=tcp&security=reality&fp=firefox&sni=${SNI}&pbk=${public_key}#${COLO}"

qrencode -t UTF8 -s 1 -l L -m 2 "$vless_reality_url" >~/_xray_url_
echo "---------- VLESS Reality URL ----------" >>~/_xray_url_
echo $vless_reality_url >>~/_xray_url_
echo >>~/_xray_url_
echo "以上节点信息保存在 ~/_xray_url_ 文件中, 以后使用 cat _xray_url_ 查看" >>~/_xray_url_
#对于Guest用户，输出一对一的url信息
if [[ -n "$guests" ]]; then
	echo "" >>~/_xray_url_
	echo "Guest 用户信息 ----------" >>~/_xray_url_
	echo "空间有限将不生成二维码" >>~/_xray_url_
	i=1
	for arg in "${args[@]}"; do
		if [[ "$arg" == "@lock" ]]; then
			continue
		fi
		guest_uuid=$(xray uuid -i "${arg}")
		guest_url="vless://${guest_uuid}@${HOST}:${PORT}?flow=xtls-rprx-vision&type=tcp&security=reality&fp=firefox&sni=${SNI}&pbk=${public_key}#${COLO}-${arg}"
		echo "${arg} : ${guest_url}" >>~/_xray_url_
		((i++))
	done

	echo "查询自重启至今的统计流量：（字节）" >>~/_xray_url_
	echo "xray api statsquery --server=127.0.0.1:10085" >>~/_xray_url_
fi

echo "" >>~/_xray_url_
echo "妥善保管下面的重装指令：" >>~/_xray_url_
echo -n "$insert bash <(curl -fsSL ${BASEURL}reality-lite.sh) " >>~/_xray_url_
if [[ ${#args[@]} -gt 0 ]]; then
	echo -n "${args[*]}" >>~/_xray_url_
fi
echo "" >>~/_xray_url_
echo "------------------------------------" >>~/_xray_url_
echo $warning000 >>~/_xray_url_
echo $warning001 >>~/_xray_url_
echo $warning002 >>~/_xray_url_
cat ~/_xray_url_
if [[ $UPDATE -eq 0 ]]; then
	echo ""
	echo "===== 由于 @lock 标签，没有更新主程序 ======"
fi
echo "VPS IPv4:    $IPV4"
echo "VPS IPv6:    [$IPV6]"
