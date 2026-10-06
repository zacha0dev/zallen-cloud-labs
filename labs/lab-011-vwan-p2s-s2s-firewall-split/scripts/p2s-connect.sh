#!/bin/bash
# lab-011: runs on vm-lab-011-client via az vm run-command.
# Downloads the P2S profile, injects the client cert/key, (re)connects OpenVPN and
# prints what the gateway pushed: PUSH_REPLY plus the kernel routes on tun0.
# Reconnecting every run matters: P2S routes are pushed at connect time only.
# __PROFILE_URL_B64__ is replaced by inspect.ps1 before the script is sent.
set -u
URL=$(echo '__PROFILE_URL_B64__' | base64 -d)
cd /etc/p2s || { echo "CERTS_MISSING"; exit 0; }
rm -rf profile profile.zip
if ! curl -sS -o profile.zip "$URL"; then echo "PROFILE_DOWNLOAD_FAIL"; exit 0; fi
unzip -q -o profile.zip -d profile
OVPN=$(find profile -iname '*.ovpn' | head -1)
echo "OVPN_FILE=$OVPN"
if [ -z "$OVPN" ]; then echo "OVPN_MISSING"; exit 0; fi
python3 - "$OVPN" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
cert = open('/etc/p2s/client.crt').read().strip()
key = open('/etc/p2s/client.key').read().strip()
s = re.sub(r'\$CLIENT_?CERTIFICATE', lambda m: cert, s)
s = re.sub(r'\$PRIVATE_?KEY', lambda m: key, s)
open('/etc/p2s/client.ovpn', 'w').write(s)
PY
echo "PROFILE_LINES_BEGIN"
grep -r -i -h -E "^[[:space:]]*route |<route|includeroutes|<Routes" profile | head -40
echo "PROFILE_LINES_END"
pkill -x openvpn >/dev/null 2>&1
sleep 2
rm -f /var/log/p2s-openvpn.log
openvpn --config /etc/p2s/client.ovpn --verb 3 --daemon --log /var/log/p2s-openvpn.log
for i in $(seq 1 45); do
  grep -q "Initialization Sequence Completed" /var/log/p2s-openvpn.log 2>/dev/null && break
  sleep 2
done
if grep -q "Initialization Sequence Completed" /var/log/p2s-openvpn.log 2>/dev/null; then
  echo "TUNNEL=UP"
else
  echo "TUNNEL=DOWN"
  tail -15 /var/log/p2s-openvpn.log
fi
echo "TUN_ADDR=$(ip -4 -br addr show tun0 2>/dev/null | awk '{print $3}')"
echo "PUSH_BEGIN"
grep -o "PUSH_REPLY[^']*" /var/log/p2s-openvpn.log | tail -1
echo "PUSH_END"
echo "TUN_ROUTES_BEGIN"
ip -4 route show dev tun0 2>/dev/null
echo "TUN_ROUTES_END"
