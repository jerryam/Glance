#!/bin/zsh
# Creates a self-signed code-signing identity in the login keychain, used by build.sh.
# Signing every build with the same identity lets macOS keep 一瞥's Accessibility and
# Screen Recording permissions, instead of asking again after each rebuild.
# Nothing leaves this Mac; the certificate is only trusted for code signing.
set -euo pipefail
name="${1:-WindowHop Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -qF "\"$name\""; then
    echo "已存在签名证书：$name"
    exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $name
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
# The system LibreSSL writes a PKCS#12 file that `security import` accepts on every macOS version.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
password="windowhop-$RANDOM-$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "pass:$password"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
echo "接下来 macOS 会请你输入登录密码，用于信任这个证书（仅用于代码签名）。"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
echo "已创建签名证书：$name"
echo "重新运行 ./build.sh 后，在 系统设置 › 隐私与安全性 中为新版本重新授权一次即可，以后编译不再需要。"
