#!/usr/bin/env bash
# IaC 作業用の Ubuntu VM を作る。Proxmox のシェルで実行する
# 使い方: ./create-vm.sh <SSH の公開鍵ファイル>
set -euo pipefail

VMID=200
NAME=iac-workstation
IP=192.168.1.120/24
GATEWAY=192.168.1.1
DNS=192.168.1.1
DISK_SIZE=40G
IMAGE_BASE_URL=https://cloud-images.ubuntu.com/resolute/current
IMAGE_NAME=resolute-server-cloudimg-amd64.img
# 中身は qcow2。import のストレージは拡張子で形式を判断し、.img は受け付けないので .qcow2 で保存する
IMAGE=resolute-server-cloudimg-amd64.qcow2
IMAGE_PATH=/var/lib/vz/import/$IMAGE

SSH_KEYS=${1:?SSH の公開鍵ファイルを指定する}

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID は既にある" >&2
  exit 1
fi

# 途中で失敗したら、作りかけの VM を消す（残ると VMID の確認で再実行できなくなる）。イメージは取り込んだら要らない
CREATED=0
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$CREATED" -eq 1 ]; then
    echo "失敗したので VM $VMID を消す" >&2
    qm destroy "$VMID" --purge || true
  fi
  rm -f "$IMAGE_PATH"
}
trap cleanup EXIT

# クラウドイメージは local ストレージの import に置く（import-from で取り込む）。Ubuntu の SHA256SUMS で確かめる
mkdir -p /var/lib/vz/import
curl -fsSL -o "$IMAGE_PATH" "$IMAGE_BASE_URL/$IMAGE_NAME"
SHA256=$(curl -fsSL "$IMAGE_BASE_URL/SHA256SUMS" | awk -v f="*$IMAGE_NAME" '$2 == f {print $1}')
if [ -z "$SHA256" ]; then
  echo "SHA256SUMS に $IMAGE_NAME がない" >&2
  exit 1
fi
echo "$SHA256  $IMAGE_PATH" | sha256sum -c --quiet -

CREATED=1
qm create "$VMID" --name "$NAME" \
  --cores 2 --cpu x86-64-v2-AES --memory 4096 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --scsi0 "local-lvm:0,import-from=local:import/$IMAGE,iothread=1" \
  --ide2 local-lvm:cloudinit --boot order=scsi0 \
  --serial0 socket --vga serial0 \
  --agent enabled=1 --onboot 1 --ostype l26
qm disk resize "$VMID" scsi0 "$DISK_SIZE"

# cloud-init で渡すのはユーザー、公開鍵、IP だけ。ルートやパッケージは起動後に setup.sh で入れる
qm set "$VMID" --ciuser ubuntu --sshkeys "$SSH_KEYS" \
  --ipconfig0 "ip=$IP,gw=$GATEWAY" --nameserver "$DNS"

qm start "$VMID"
