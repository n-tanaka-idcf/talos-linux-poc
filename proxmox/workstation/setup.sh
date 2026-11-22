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
# インターフェース名は cloud-init の設定（今は eth0）に合わせ、デフォルトルートのものを使う
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
cat > /etc/netplan/60-talosnet-route.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      routes:
        - to: 10.10.10.0/24
          via: 192.168.1.101
EOF
chmod 600 /etc/netplan/60-talosnet-route.yaml
netplan apply
# netplan apply でネットワークが再設定されるので、名前解決できるまで待つ
for _ in $(seq 30); do getent hosts cli.github.com >/dev/null && break; sleep 2; done

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
# tofu は apt-mark hold で固定している。TOFU_VERSION を変えて実行し直したときに上げられるよう、hold を越えて入れる
apt-get install -y -q --allow-change-held-packages qemu-guest-agent git jq gh ansible "tofu=$TOFU_VERSION"
apt-mark hold tofu >/dev/null
# udev から起動される unit なので enable はできない。起動だけする
systemctl start qemu-guest-agent

# ダウンロードしたファイルをチェックサムで確かめる
# verify <ファイル> <SHA256>
verify() {
  if [ -z "$2" ]; then
    echo "$1 のチェックサムを取得できなかった" >&2
    exit 1
  fi
  echo "$2  $1" | sha256sum -c --quiet -
}

# バイナリを確かめてから /usr/local/bin に置く
# install_bin <名前> <URL> <SHA256>
install_bin() {
  curl -fsSL -o "$TMP/$1" "$2"
  verify "$TMP/$1" "$3"
  install -m 0755 "$TMP/$1" "/usr/local/bin/$1"
}

# tar.gz を確かめてから、中のバイナリを /usr/local/bin に置く
# install_tgz <名前> <URL> <SHA256> <アーカイブ内のパス>
install_tgz() {
  curl -fsSL -o "$TMP/$1.tar.gz" "$2"
  verify "$TMP/$1.tar.gz" "$3"
  tar -xzf "$TMP/$1.tar.gz" -C "$TMP" "$4"
  install -m 0755 "$TMP/$4" "/usr/local/bin/$1"
}

# talosctl: リリースの sha256sum.txt で確かめる
TALOS_URL=https://github.com/siderolabs/talos/releases/download/$TALOSCTL_VERSION
install_bin talosctl "$TALOS_URL/talosctl-linux-amd64" \
  "$(curl -fsSL "$TALOS_URL/sha256sum.txt" | awk '$2 == "talosctl-linux-amd64" {print $1}')"

KUBECTL_URL=https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
install_bin kubectl "$KUBECTL_URL" "$(curl -fsSL "$KUBECTL_URL.sha256")"

HELM_URL=https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz
install_tgz helm "$HELM_URL" "$(curl -fsSL "$HELM_URL.sha256sum" | awk '{print $1}')" linux-amd64/helm

CILIUM_URL=https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz
install_tgz cilium "$CILIUM_URL" "$(curl -fsSL "$CILIUM_URL.sha256sum" | awk '{print $1}')" cilium

echo "--- installed"
tofu version | sed -n 1p
ansible --version | sed -n 1p
gh --version | sed -n 1p
talosctl version --client --short | tail -1
kubectl version --client | sed -n 1p
helm version --short
cilium version --client | sed -n 1p
