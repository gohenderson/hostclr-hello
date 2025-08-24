#!/usr/bin/env bash
set -euo pipefail

DOTNET_ROOT="${DOTNET_ROOT:-/usr/share/dotnet}"

HOSTFXR_LIB_DIR="$(dirname "$(find "$DOTNET_ROOT" -name libhostfxr.so -print -quit)")"
INC_DIR="$(dirname "$(find "$DOTNET_ROOT/packs" -path "*/Microsoft.NETCore.App.Host.linux-x64/*/runtimes/linux-x64/native/nethost.h" -print -quit)")"
[ -z "${INC_DIR:-}" ] && { echo "Could not locate hosting headers under $DOTNET_ROOT/packs"; exit 1; }
NETHOST_LIB_DIR="$INC_DIR"

echo "HOSTFXR_LIB_DIR=$HOSTFXR_LIB_DIR"
echo "INC_DIR=$INC_DIR"
echo "NETHOST_LIB_DIR=$NETHOST_LIB_DIR"

g++ -o host host.cpp \
  -I"$INC_DIR" \
  -L"$HOSTFXR_LIB_DIR" -L"$NETHOST_LIB_DIR" \
  -Wl,-rpath,"$HOSTFXR_LIB_DIR:$NETHOST_LIB_DIR" \
  -ldl -lhostfxr -lnethost
echo "Built ./host"
