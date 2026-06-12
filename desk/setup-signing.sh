#!/bin/bash
# 一次性:创建本地自签名代码签名证书「VibeNotch Local Signing」。
# install.sh 检测到该证书后会用它签名,签名身份稳定 → 辅助功能等
# TCC 授权跨构建持续有效(ad-hoc 签名每次都变,每次重装都要重新授权)。
set -e

SIGN_ID="VibeNotch Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "✓ 证书已存在: $SIGN_ID"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.conf <<'EOF'
[ req ]
distinguished_name = req_name
x509_extensions = ext
prompt = no
[ req_name ]
CN = VibeNotch Local Signing
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config cert.conf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -passout pass:vntemp -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -passout pass:vntemp
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P vntemp -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem

echo "✓ 已创建并信任: $SIGN_ID(有效期 10 年)"
echo "  之后运行 ./install.sh 会自动用它签名。"
