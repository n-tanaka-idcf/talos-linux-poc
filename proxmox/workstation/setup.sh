#!/usr/bin/env bash
# IaC 作業用 VM のセットアップ。VM の中で sudo で実行する（何度実行してもよい）
# 使い方: sudo ./setup.sh
set -euo pipefail

TOFU_VERSION=1.13.9
TALOSCTL_VERSION=v1.14.6
KUBECTL_VERSION=v1.37.1
HELM_VERSION=v4.3.2
CILIUM_CLI_VERSION=v0.20.3

if [ "$(id -u)" -ne 0 ]; then
  echo "sudo で実行する" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# VM 用ネットワーク（Talos）へのルート。ルーターを通さず Proxmox に直接送るので、行きと帰りの経路が同じになる
cat > /etc/netplan/60-talosnet-route.yaml <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      routes:
        - to: 10.10.10.0/24
          via: 192.168.1.101
EOF
chmod 600 /etc/netplan/60-talosnet-route.yaml
netplan apply

# apt のリポジトリ: GitHub CLI と OpenTofu（どちらもディストリビューションに依存しない）
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
curl -fsSL https://get.opentofu.org/opentofu.gpg -o /etc/apt/keyrings/opentofu.gpg
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | gpg --dearmor --yes -o /etc/apt/keyrings/opentofu-repo.gpg
echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
  > /etc/apt/sources.list.d/opentofu.list

apt-get update -q
apt-get install -y -q qemu-guest-agent git jq gh ansible "tofu=$TOFU_VERSION"
apt-mark hold tofu >/dev/null
# udev から起動される unit なので enable はできない。起動だけする
systemctl start qemu-guest-agent

# バイナリをダウンロードし、チェックサムを確かめてから /usr/local/bin に置く
# install_bin <名前> <URL> <SHA256>
install_bin() {
  curl -fsSL -o "$TMP/$1" "$2"
  echo "$3  $TMP/$1" | sha256sum -c --quiet -
  install -m 0755 "$TMP/$1" "/usr/local/bin/$1"
}

# talosctl: リリースの sha256sum.txt で確かめる
TALOS_URL=https://github.com/siderolabs/talos/releases/download/$TALOSCTL_VERSION
install_bin talosctl "$TALOS_URL/talosctl-linux-amd64" \
  "$(curl -fsSL "$TALOS_URL/sha256sum.txt" | awk '$2 == "talosctl-linux-amd64" {print $1}')"

KUBECTL_URL=https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
install_bin kubectl "$KUBECTL_URL" "$(curl -fsSL "$KUBECTL_URL.sha256")"

# helm と cilium は tar.gz。アーカイブのチェックサムを確かめてから展開する
HELM_TGZ=helm-$HELM_VERSION-linux-amd64.tar.gz
curl -fsSL -o "$TMP/$HELM_TGZ" "https://get.helm.sh/$HELM_TGZ"
echo "$(curl -fsSL "https://get.helm.sh/$HELM_TGZ.sha256sum" | awk '{print $1}')  $TMP/$HELM_TGZ" | sha256sum -c --quiet -
tar -xzf "$TMP/$HELM_TGZ" -C "$TMP" linux-amd64/helm
install -m 0755 "$TMP/linux-amd64/helm" /usr/local/bin/helm

CILIUM_URL=https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz
curl -fsSL -o "$TMP/cilium.tar.gz" "$CILIUM_URL"
echo "$(curl -fsSL "$CILIUM_URL.sha256sum" | awk '{print $1}')  $TMP/cilium.tar.gz" | sha256sum -c --quiet -
tar -xzf "$TMP/cilium.tar.gz" -C "$TMP" cilium
install -m 0755 "$TMP/cilium" /usr/local/bin/cilium

echo "--- installed"
tofu version | sed -n 1p
ansible --version | sed -n 1p
gh --version | sed -n 1p
talosctl version --client --short | tail -1
kubectl version --client | sed -n 1p
helm version --short
cilium version --client | sed -n 1p
