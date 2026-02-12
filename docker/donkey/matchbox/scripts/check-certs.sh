#!/bin/bash
set -euo pipefail

CERTS_DIR="/certs"

cd "$CERTS_DIR"

if [ ! -f server.crt ] || [ ! -f server.key ] || [ ! -f ca.crt ]; then
  echo "At least one of server.crt, server.key or ca.crt not found, generating..."
  ./generate-certs.sh
else
  # Check certificate expiration
  crt_valid=true
  if ! openssl x509 -checkend 0 -noout -in server.crt; then
    echo "server.crt expired."
    crt_valid=false
  fi
  if ! openssl x509 -checkend 0 -noout -in ca.crt; then
    echo "ca.crt expired."
    crt_valid=false
  fi
  if [ "$crt_valid" = false ]; then
    echo "At least one certificate expired, regenerating..."
    ./generate-certs.sh
  else
    echo "All certificates are valid."
  fi
fi

echo "Certificate check completed."
