#!/bin/bash

if [ 0 == $UID ]; then
    echo -e "当前用户是root用户，进入安装流程"
    sleep 3
else
    echo -e "当前用户不是root用户，请切换到root用户后重新执行脚本"
    exit 1    
fi

read -p "请输入域名(eg:www.google.com):" domain
domain_ip=`ping ${domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
local_ip=`curl -4 ip.sb`
echo -e "域名dns解析IP：${domain_ip}"
echo -e "本机IP: ${local_ip}"
if [[ $(echo ${local_ip}|tr '.' '+'|bc) -eq $(echo ${domain_ip}|tr '.' '+'|bc) ]];then
    echo -e "域名dns解析IP 与 本机IP 匹配"
else
    echo -e "请确保域名添加了正确的 A 记录，否则将无法正常使用 V2ray"
    echo -e "域名dns解析IP 与 本机IP 不匹配 是否继续安装？（y/n）" && read install
    case $install in
    [yY][eE][sS]|[yY])
        echo -e "继续安装"
        ;;
    *)
        echo -e "安装终止"
        exit 2
        ;;
    esac
fi

read -p "请输入订阅源（default:rss）:" rss
[[ -z ${rss} ]] && rss="rss"
read -p "请输入UUID（default:random）:" UUID
[[ -z ${UUID} ]] && UUID=$(uuidgen -n @dns -N ${domain} -s)
read -p "请输入伪装路径（default:random）:" camouflage
[[ -z ${camouflage} ]] && camouflage="cat /dev/urandom | head -n 10 | md5sum | head -c 8"

apt update && apt upgrade -y && apt autoremove -y
apt install iputils-ping uuid-runtime haproxy cron socat tzdata -y
timedatectl set-timezone Asia/Shanghai
bash <(curl -L -s https://install.direct/go.sh)
curl  https://get.acme.sh | sh

cat > /etc/v2ray/config.json <<EOF
{
	"log": {
    	"access": "/var/log/v2ray/access.log",
        "error": "/var/log/v2ray/error.log",
    	"loglevel": "warning"
    },
	"inbounds": [
	{
		"port": 10808, 
		"listen": "127.0.0.1",
		"protocol": "vmess", 
		"settings": {
        	"clients": [
    		{
        		"id": "${UUID}", 
    			"alterId": 0
        	}
        	]
    	}, 
    	"streamSettings": {
        	"network": "ws", 
        	"wsSettings": {
        	"path": "/${camouflage}"
        }
      }
    }
	], 
	"outbounds": [
    {
    	"protocol": "freedom"
    }
	]
}
EOF

cat > /etc/v2ray/vmess.json <<EOF
{
  "v": "2",
  "ps": "${rss}",
  "add": "${domain}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "${domain}",
  "path": "/${camouflage}",
  "tls": "tls"
}
EOF

cat > /etc/haproxy/errors/${rss}.http <<EOF
HTTP/1.0 200 OK
Cache-Control: no-cache
Connection: close
Content-Type: text/plain

EOF

cat > /etc/haproxy/errors/401.http <<EOF
HTTP/1.0 401 Unauthorized
Cache-Control: no-cache
Connection: close
Content-Type: text/html

<html><body><h1>401 Unauthorized</h1>
If you see this message, it indicates that your network connection to the server is OK but the device authentication failed.<br>
Please check your settings or contact the administrator.
</body></html>
EOF

cat > /etc/haproxy/errors/200.http <<EOF
HTTP/1.0 200 OK
Cache-Control: no-cache
Connection: close
Content-Type: text/html

<html><body><h1>200 OK</h1>
Device authorized.
</body></html>
EOF

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    daemon
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options no-sslv3 no-tlsv10 no-tlsv11 no-tls-tickets
    ssl-dh-param-file /etc/haproxy/dhparam.pem
    
defaults
    mode http
    maxconn 100000

frontend http
    bind *:80
    http-request redirect scheme https unless { path_beg /.well-known/acme-challenge/ }
    default_backend acme

frontend https
    bind *:443 
    http-response set-header Strict-Transport-Security max-age=63072000
    use_backend ws if { path_beg /${camouflage} }
    use_backend rss if { path_end ${rss}.http }
    use_backend authsuccess if { src ${local_ip} } 
    default_backend authfail

backend rss
    errorfile 503 /etc/haproxy/errors/${rss}.http

backend authsuccess
    errorfile 503 /etc/haproxy/errors/200.http

backend authfail
    errorfile 503 /etc/haproxy/errors/401.http

backend ws
    server ws 127.0.0.1:10808

backend acme
    server acme 127.0.0.1:10800
EOF

echo -n "vmess://$(cat /etc/v2ray/vmess.json | base64 -w 0)" > /etc/v2ray/vmess.url
echo -n "${vmess_link}"| base64 >> /etc/haproxy/errors/${rss}.http
curl https://ssl-config.mozilla.org/ffdhe2048.txt > /etc/haproxy/dhparam.pem

systemctl start v2ray
systemctl start haproxy
systemctl reload haproxy
sed -i 's/443/& ssl crt \/etc\/haproxy\/haproxy.pem alpn h2,http\/1.1/' /etc/haproxy/haproxy.cfg
sudo $HOME/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --httpport 10800
sudo $HOME/.acme.sh/acme.sh --installcert -d ${domain} --ecc --fullchainpath /etc/haproxy/fullchain.pem --keypath /etc/haproxy/key.pem --reloadcmd "cat /etc/haproxy/fullchain.pem /etc/haproxy/key.pem > /etc/haproxy/haproxy.pem && systemctl reload haproxy"
systemctl enable v2ray
systemctl enable haproxy

sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_retries2/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
sed -i '/fs.file-max/d' /etc/sysctl.conf
sed -i '/fs.inotify.max_user_instances/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syncookies/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_tw_buckets/d' /etc/sysctl.conf
sed -i '/net.ipv4.route.gc_timeout/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_synack_retries/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syn_retries/d' /etc/sysctl.conf
sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_timestamps/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_orphans/d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 32768
EOF
sysctl -p

echo -e "v2ray + haproxy + bbr加速 安装成功"
echo -e "vmess导入链接: $(cat /etc/v2ray/vmess.url)"
echo -e "订阅链接: https://${domain}/${rss}.http)"
