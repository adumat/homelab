#!/bin/bash -x
# note: Script uses -batch and -subj, instead of interactive prompts.
set -e

export SAN=DNS:navi.lan,IP:10.1.10.5

# Set working directory to the location of the script
SCRIPT_DIR=$(dirname "$(realpath "$0")")
cd "${SCRIPT_DIR}"

rm -f ca.key ca.crt server.key server.csr server.crt client.key client.csr client.crt index.* serial*
rm -rf certs crl newcerts

if [ -z "${SAN}" ]
  then echo "Set SAN with a DNS or IP for matchbox (e.g. export SAN=DNS.1:matchbox.example.com,IP.1:172.17.0.2)."
  exit 1
fi

echo "Creating example CA, server cert/key, and client cert/key..."

# basic files/directories
mkdir -p {certs,crl,newcerts}
touch index.txt
touch index.txt.attr
echo 1000 > serial

# CA private key (unencrypted)
openssl genrsa -out ca.key 4096
# Certificate Authority (self-signed certificate)
openssl req -config openssl.conf -new -x509 -days 3650 -sha256 -key ca.key -extensions v3_ca -out ca.crt -subj "/CN=matchbox-ca"

# End-entity certificates

# Server private key (unencrypted)
openssl genrsa -out server.key 2048
# Server certificate signing request (CSR)
openssl req -config openssl.conf -new -sha256 -key server.key -out server.csr -subj "/CN=matchbox-server"
# Certificate Authority signs CSR to grant a certificate
openssl ca -batch -config openssl.conf -extensions server_cert -days 365 -notext -md sha256 -in server.csr -out server.crt -cert ca.crt -keyfile ca.key

# Client private key (unencrypted)
openssl genrsa -out client.key 2048
# Signed client certificate signing request (CSR)
openssl req -config openssl.conf -new -sha256 -key client.key -out client.csr -subj "/CN=matchbox-client"
# Certificate Authority signs CSR to grant a certificate
openssl ca -batch -config openssl.conf -extensions usr_cert -days 365 -notext -md sha256 -in client.csr -out client.crt -cert ca.crt -keyfile ca.key

# Remove CSR's
rm -- *.csr

# Esporta le variabili anche in un file certs.env nella cartella matchbox
cat <<EOF > ../certs.env
CA_KEY="$(cat ca.key | base64 | tr -d '\n')"
CA_CERT="$(cat ca.crt | base64 | tr -d '\n')"
SERVER_KEY="$(cat server.key | base64 | tr -d '\n')"
SERVER_CERT="$(cat server.crt | base64 | tr -d '\n')"
CLIENT_KEY="$(cat client.key | base64 | tr -d '\n')"
CLIENT_CERT="$(cat client.crt | base64 | tr -d '\n')"
EOF

echo "*******************************************************************"
echo "WARNING: Generated credentials are self-signed. Prefer your"
echo "organization's PKI for production deployments."
