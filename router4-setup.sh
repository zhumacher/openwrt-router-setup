#!/bin/sh
# Run locally on router 4 as root. No firmware upgrades or network restart.
# OpenWrt shell helpers read optional arguments and unset cache variables.
# Do not enable nounset (-u) when sourcing /lib/functions/network.sh.
set -e
umask 077
export LC_ALL=C
PORT=22024
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTGbWGrOzSvOiLw0do3O7TVLjLbjESFt8sROm/Ba9qt podkop-bot-router4'

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Run as root on router 4.'
[ -f /etc/openwrt_release ] || die 'This script requires OpenWrt.'
[ -r /dev/tty ] || die 'Run from an interactive SSH terminal.'
for tool in uci ubus jsonfilter sysupgrade fw4; do
    command -v "$tool" >/dev/null || die "Missing OpenWrt tool: $tool"
done
[ -x /etc/init.d/dropbear ] || die 'Dropbear is missing.'
[ -z "$(uci changes)" ] || die 'Save or revert pending LuCI/UCI changes first.'
. /lib/functions/network.sh
network_find_wan WAN_IF || die 'No active IPv4 WAN interface found.'
network_get_device WAN_DEV "$WAN_IF" || die 'No WAN device found.'
network_get_ipaddr WAN_IP "$WAN_IF" || die 'No WAN IPv4 address found.'
# Require the normal WAN firewall zone and confirm it contains this interface.
WAN_ZONE=''
for section in $(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
    [ "$(uci -q get "firewall.$section.name")" = wan ] || continue
    for iface in $(uci -q get "firewall.$section.network"); do
        [ "$iface" != "$WAN_IF" ] || WAN_ZONE=wan
    done
done
[ "$WAN_ZONE" = wan ] || die 'Active WAN is not in the normal wan firewall zone; manual review needed.'
for section in $(uci show dropbear | sed -n 's/^dropbear\.\([^=]*\)=dropbear$/\1/p'); do
    [ "$section" != router4_remote ] || continue
    [ "$(uci -q get "dropbear.$section.Port")" != "$PORT" ] || die "SSH port $PORT is already configured; manual review needed."
done

printf 'DuckDNS name (example: friend4 or friend4.duckdns.org): ' >/dev/tty
IFS= read -r DOMAIN </dev/tty
DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')
DOMAIN=${DOMAIN%.duckdns.org}
case "$DOMAIN" in ''|*[!a-z0-9-]*|-*|*-) die 'Invalid DuckDNS name.';; esac
[ "${#DOMAIN}" -le 63 ] || die 'DuckDNS name is too long.'
case "$DOMAIN" in
    x-ui-zhumacher|zhumacher|ivan-zhumacher|gruzdev)
        die 'This domain belongs to an existing server/router. Register a separate name for router 4.';;
esac
trap 'unset TOKEN' EXIT
trap 'exit 130' INT TERM HUP
printf 'DuckDNS token (hidden): ' >/dev/tty
IFS= read -r -s TOKEN </dev/tty
printf '\n' >/dev/tty
printf '%s\n' "$TOKEN" | grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' || die 'Invalid token format.'

BACKUP_DIR=$(mktemp -d /root/router4-before-ddns-XXXXXX)
sysupgrade -b "$BACKUP_DIR/openwrt-settings.tar.gz"
cp -p /etc/config/dropbear "$BACKUP_DIR/dropbear"
cp -p /etc/config/firewall "$BACKUP_DIR/firewall"
[ ! -f /etc/config/ddns ] || cp -p /etc/config/ddns "$BACKUP_DIR/ddns"
[ ! -f /etc/dropbear/authorized_keys ] || cp -p /etc/dropbear/authorized_keys "$BACKUP_DIR/authorized_keys"
restore_access() {
    cp -p "$BACKUP_DIR/firewall" /etc/config/firewall
    cp -p "$BACKUP_DIR/dropbear" /etc/config/dropbear
    if [ -f "$BACKUP_DIR/authorized_keys" ]; then
        cp -p "$BACKUP_DIR/authorized_keys" /etc/dropbear/authorized_keys
    else
        rm -f /etc/dropbear/authorized_keys
    fi
    /etc/init.d/dropbear reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
}
printf 'Backup: %s\n' "$BACKUP_DIR"

if command -v apk >/dev/null 2>&1; then
    apk update
    apk add curl ca-bundle ddns-scripts luci-app-ddns
elif command -v opkg >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle ddns-scripts luci-app-ddns
else
    die 'Neither opkg nor apk found.'
fi

# Installing curl can leave an older libcurl4 because its dependency is unversioned.
# Repair only this pair if the executable cannot load, then verify before DDNS.
if ! curl --version >/dev/null 2>&1; then
    printf 'Repairing incompatible curl/libcurl4 packages...\n'
    if command -v apk >/dev/null 2>&1; then
        apk upgrade libcurl4 curl
    else
        opkg upgrade libcurl4 curl
    fi
fi
curl --version >/dev/null 2>&1 || die 'curl still cannot start after updating libcurl4 and curl. Send this output to the administrator.'

# Test HTTPS credentials before enabling external SSH. Token is never printed.
REQUEST=$(mktemp /tmp/router4-duckdns-request.XXXXXX)
trap 'rm -f "$REQUEST"; unset TOKEN' EXIT
printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip=&verbose=true"\n' "$DOMAIN" "$TOKEN" > "$REQUEST"
REPLY=$(curl -4 --noproxy '*' --interface "$WAN_DEV" --connect-timeout 10 --max-time 25 -fsS --config "$REQUEST") || die 'DuckDNS HTTPS update failed.'
rm -f "$REQUEST"
[ "$(printf '%s\n' "$REPLY" | head -n 1 | tr -d '\r')" = OK ] || die 'DuckDNS rejected the name/token.'
PUBLIC_IP=$(printf '%s\n' "$REPLY" | sed -n '2p' | tr -d '\r')
printf '%s\n' "$PUBLIC_IP" | awk -F. 'NF != 4 {exit 1} {for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i>255) exit 1}' || die 'DuckDNS did not return an IPv4 address.'

uci set ddns.router4_duckdns=service
uci set ddns.router4_duckdns.enabled=1
uci set ddns.router4_duckdns.lookup_host="$DOMAIN.duckdns.org"
uci set ddns.router4_duckdns.domain="$DOMAIN"
uci set ddns.router4_duckdns.username=unused
uci set ddns.router4_duckdns.password="$TOKEN"
uci -q delete ddns.router4_duckdns.service_name || true
uci set ddns.router4_duckdns.update_url='https://www.duckdns.org/update?domains=[DOMAIN]&token=[PASSWORD]&ip=[IP]'
uci set ddns.router4_duckdns.interface="$WAN_IF"
uci set ddns.router4_duckdns.bind_network="$WAN_IF"
uci set ddns.router4_duckdns.ip_source=web
uci set ddns.router4_duckdns.ip_url='https://api.ipify.org'
uci set ddns.router4_duckdns.use_ipv6=0
uci set ddns.router4_duckdns.use_https=1
uci set ddns.router4_duckdns.cacert=/etc/ssl/certs/ca-certificates.crt
uci set ddns.router4_duckdns.force_ipversion=1
uci -q get ddns.global >/dev/null 2>&1 || uci set ddns.global=ddns
uci set ddns.global.use_curl=1
uci set ddns.router4_duckdns.check_interval=5
uci set ddns.router4_duckdns.check_unit=minutes
uci set ddns.router4_duckdns.force_interval=24
uci set ddns.router4_duckdns.force_unit=hours
uci commit ddns
chmod 600 /etc/config/ddns
unset TOKEN

mkdir -p /etc/dropbear
touch /etc/dropbear/authorized_keys
grep -qF "$PUBKEY" /etc/dropbear/authorized_keys || printf '%s\n' "$PUBKEY" >> /etc/dropbear/authorized_keys
chmod 700 /etc/dropbear
chmod 600 /etc/dropbear/authorized_keys
uci set dropbear.router4_remote=dropbear
uci set dropbear.router4_remote.enable=1
uci set dropbear.router4_remote.Interface="$WAN_IF"
uci set dropbear.router4_remote.Port="$PORT"
uci set dropbear.router4_remote.PasswordAuth=off
uci set dropbear.router4_remote.RootPasswordAuth=off
uci set dropbear.router4_remote.RootLogin=on
uci set dropbear.router4_remote.GatewayPorts=off
uci commit dropbear
uci set firewall.router4_remote_ssh=rule
uci set firewall.router4_remote_ssh.name='Router4-SSH-KeyOnly'
uci set firewall.router4_remote_ssh.src=wan
uci set firewall.router4_remote_ssh.proto=tcp
uci set firewall.router4_remote_ssh.dest_port="$PORT"
uci set firewall.router4_remote_ssh.family=ipv4
uci set firewall.router4_remote_ssh.target=ACCEPT
uci commit firewall
if ! fw4 check; then
    restore_access
    die 'Firewall validation failed. Firewall and SSH configs restored.'
fi
/etc/init.d/dropbear enable
if ! /etc/init.d/dropbear reload || ! /etc/init.d/firewall reload; then
    restore_access
    die 'SSH/firewall reload failed. Previous access settings restored.'
fi
/etc/init.d/ddns enable
/etc/init.d/ddns restart

if [ "$WAN_IP" != "$PUBLIC_IP" ] && ! command -v upnpc >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add miniupnpc || printf 'UPnP package unavailable; upstream port forwarding may need manual setup.\n'
    else
        opkg install miniupnpc || printf 'UPnP package unavailable; upstream port forwarding may need manual setup.\n'
    fi
fi

cat > /root/router4-maintain-upnp.sh <<'UPNP'
#!/bin/sh
set -e
command -v upnpc >/dev/null || exit 1
. /lib/functions/network.sh
network_find_wan iface || exit 1
network_get_ipaddr addr "$iface" || exit 1
printf '%s\n' "$addr" | awk -F. '
    $1==10 || ($1==192 && $2==168) || ($1==172 && $2>=16 && $2<=31) || ($1==100 && $2>=64 && $2<=127) { private=1 }
    END { exit !private }
' || exit 0
gateway=$(ip -4 route show default | awk 'NR==1 {print $3}')
# A short lease is renewed every five minutes. Never delete an existing mapping.
if upnpc -m "$addr" -e Router4-SSH-KeyOnly -a "$addr" 22024 22024 TCP 900; then
    exit 0
fi
# Some upstream routers do not answer SSDP but expose this description URL.
[ -n "$gateway" ] || exit 1
upnpc -u "http://$gateway:5000/Public_UPNP_gatedesc.xml" -e Router4-SSH-KeyOnly -a "$addr" 22024 22024 TCP 900
UPNP
chmod 700 /root/router4-maintain-upnp.sh
touch /etc/crontabs/root
grep -qF '/root/router4-maintain-upnp.sh' /etc/crontabs/root ||
    printf '*/5 * * * * /root/router4-maintain-upnp.sh 2>&1 | logger -t router4-upnp\n' >> /etc/crontabs/root
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/95-router4-upnp <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = ifup ] || exit 0
. /lib/functions/network.sh
network_find_wan iface || exit 0
[ "$INTERFACE" = "$iface" ] || exit 0
(/root/router4-maintain-upnp.sh 2>&1 | logger -t router4-upnp) &
HOTPLUG
chmod 700 /etc/hotplug.d/iface/95-router4-upnp
touch /etc/sysupgrade.conf
for saved in /root/router4-maintain-upnp.sh /etc/hotplug.d/iface/95-router4-upnp; do
    grep -qxF "$saved" /etc/sysupgrade.conf || printf '%s\n' "$saved" >> /etc/sysupgrade.conf
done
/etc/init.d/cron enable
/etc/init.d/cron restart
if [ "$WAN_IP" != "$PUBLIC_IP" ]; then
    if /root/router4-maintain-upnp.sh > /tmp/router4-upnp-result.log 2>&1; then
        printf 'UPnP request sent. External connectivity still needs checking.\n'
    else
        printf 'UPnP failed. Forward TCP %s to %s:%s on the upstream router.\n' "$PORT" "$WAN_IP" "$PORT"
        tail -n 8 /tmp/router4-upnp-result.log
    fi
fi
printf '\nDDNS: %s.duckdns.org\nWAN IPv4: %s\nPublic IPv4: %s\nSSH port: %s (key only)\nBackup: %s\n' "$DOMAIN" "$WAN_IP" "$PUBLIC_IP" "$PORT" "$BACKUP_DIR"
printf '\nRouter information for the next Podkop upgrade:\n'
ubus call system board | jsonfilter -e '@.model' -e '@.board_name' -e '@.release.description'
if command -v opkg >/dev/null 2>&1; then
    opkg print-architecture
    opkg list-installed | grep -E '^(podkop|luci-app-podkop|sing-box|podkop-engine) ' || true
else
    apk --print-arch
    apk info | grep -E '^(podkop|luci-app-podkop|sing-box|podkop-engine)$' || true
fi
df -h /overlay
printf 'Podkop configuration SHA256 (not modified):\n'
[ ! -f /etc/config/podkop ] || sha256sum /etc/config/podkop
printf '\nSSH host fingerprints (send these with the DDNS name):\n'
for key in /etc/dropbear/dropbear_*_host_key; do
    [ ! -f "$key" ] || dropbearkey -y -f "$key" 2>/dev/null | grep 'Fingerprint:' || true
done
printf '\nIf the upstream ISP uses CGNAT, DDNS/UPnP alone cannot enable inbound SSH.\nSend the DDNS name and this output to the administrator for an external SSH test.\n'
