#!/usr/bin/env bash
# machine config を生成する。secrets.yaml が既にあれば再利用する
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME=talos-ha
ENDPOINT=https://192.168.1.110:6443
CONTROLPLANES=(ctrl01 ctrl02 ctrl03)
WORKERS=(worker01 worker02)
CONTROLPLANE_IPS=(192.168.1.111 192.168.1.112 192.168.1.113)

mkdir -p _out
[ -f _out/secrets.yaml ] || talosctl gen secrets -o _out/secrets.yaml

talosctl gen config "$CLUSTER_NAME" "$ENDPOINT" \
  --with-secrets _out/secrets.yaml \
  --install-disk /dev/sda \
  --config-patch @patches/common.yaml \
  --config-patch-control-plane @patches/controlplane.yaml \
  --with-docs=false --with-examples=false \
  --force -o _out

for node in "${CONTROLPLANES[@]}"; do
  talosctl machineconfig patch _out/controlplane.yaml --patch "@nodes/$node.yaml" -o "_out/$node.yaml"
done
for node in "${WORKERS[@]}"; do
  talosctl machineconfig patch _out/worker.yaml --patch "@nodes/$node.yaml" -o "_out/$node.yaml"
done

for node in "${CONTROLPLANES[@]}" "${WORKERS[@]}"; do
  talosctl validate --config "_out/$node.yaml" --mode metal --strict
done

# talosctl の接続先は VIP ではなく CP の実 IP（VIP は etcd が正常なときしか動かないため）
talosctl --talosconfig _out/talosconfig config endpoint "${CONTROLPLANE_IPS[@]}"
talosctl --talosconfig _out/talosconfig config node "${CONTROLPLANE_IPS[0]}"
