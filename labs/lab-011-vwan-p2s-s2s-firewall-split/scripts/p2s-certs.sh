#!/bin/bash
# lab-011: runs on vm-lab-011-client via az vm run-command.
# Creates a self-signed P2S root CA and a client cert signed by it (idempotent),
# installs the OpenVPN client, then prints the root cert body between markers so
# deploy.ps1 can hand it to the P2S VPN server configuration.
set -e
mkdir -p /etc/p2s
cd /etc/p2s
if [ ! -f root.crt ] || [ ! -f client.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout root.key -out root.crt -subj "/CN=lab-011-p2s-root" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout client.key -out client.csr -subj "/CN=lab-011-client" >/dev/null 2>&1
  printf "extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n" > client.ext
  openssl x509 -req -in client.csr -CA root.crt -CAkey root.key -CAcreateserial \
    -out client.crt -days 30 -sha256 -extfile client.ext >/dev/null 2>&1
  chmod 600 root.key client.key
fi
if ! command -v openvpn >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq openvpn unzip >/dev/null 2>&1 || true
fi
echo "OPENVPN=$(command -v openvpn || echo missing)"
echo "ROOTCERT_BEGIN"
grep -v -- "-----" root.crt | tr -d '\n'
echo ""
echo "ROOTCERT_END"
