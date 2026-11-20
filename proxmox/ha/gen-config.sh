#!/usr/bin/env bash
# machine config を生成する。secrets.yaml が既にあれば再利用する
# ノードは nodes/ のファイル名で決まる: ctrl*.yaml は controlplane、worker*.yaml は worker
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME=talos-ha
ENDPOINT=https://192.168.1.110:6443

CONTROLPLANES=()
for f in nodes/ctrl*.yaml; do CONTROLPLANES+=("$(basename "$f" .yaml)"); done
WORKERS=()
for f in nodes/worker*.yaml; do WORKERS+=("$(basename "$f" .yaml)"); done

# ノードのファイルに書いた最初のアドレス（プレフィックス長を除く）
node_ip() {
  sed -n 's/^ *- address: \([0-9.]*\)\/.*/\1/p' "nodes/$1.yaml" | head -1
}

mkdir -p _out
if [ ! -f _out/secrets.yaml ]; then
  echo "_out/secrets.yaml がないため新しく作成する。既存のクラスタがある場合、新しい secrets では管理できなくなる" >&2
  talosctl gen secrets -o _out/secrets.yaml
fi

talosctl gen config "$CLUSTER_NAME" "$ENDPOINT" \
  --with-secrets _out/secrets.yaml \
  --install-disk /dev/sda \
  --config-patch @patches/common.yaml \
  --config-patch-control-plane @patches/controlplane.yaml \
  --config-patch-control-plane @patches/cilium.yaml \
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
CONTROLPLANE_IPS=()
for node in "${CONTROLPLANES[@]}"; do CONTROLPLANE_IPS+=("$(node_ip "$node")"); done
talosctl --talosconfig _out/talosconfig config endpoint "${CONTROLPLANE_IPS[@]}"
talosctl --talosconfig _out/talosconfig config node "${CONTROLPLANE_IPS[0]}"
