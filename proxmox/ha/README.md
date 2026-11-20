# Proxmox 上の HA Talos クラスタ

Proxmox VE 上の VM 5 台（コントロールプレーン 3 台 + ワーカー 2 台）で Talos Linux の HA クラスタを動かす構成。Kubernetes API のエンドポイントは、Talos 組み込みの Layer2 VIP で冗長化する。

Proxmox ホストは 1 台なので、物理ホストの障害には耐えられない。この構成で確かめられるのは、VM / OS の障害への耐性と、ノード単位のローリング再起動・アップグレード。

## 構成

```
                 VIP 192.168.1.110:6443  (Layer2VIPConfig)
                          │
      ┌───────────────────┼───────────────────┐
  ctrl01 .111         ctrl02 .112         ctrl03 .113      ← etcd 3 台
      └───────────────────┼───────────────────┘
                ┌─────────┴─────────┐
           worker01 .121       worker02 .122
```

| VMID | 名前 | 役割 | IP | vCPU / RAM / ディスク |
|---|---|---|---|---|
| 100 | talos-linux-ctrl01 | controlplane | 192.168.1.111 | 2 / 4GB / 50GB |
| 101 | talos-linux-ctrl02 | controlplane | 192.168.1.112 | 2 / 4GB / 20GB |
| 102 | talos-linux-ctrl03 | controlplane | 192.168.1.113 | 2 / 4GB / 20GB |
| 111 | talos-linux-worker01 | worker | 192.168.1.121 | 2 / 4GB / 50GB |
| 112 | talos-linux-worker02 | worker | 192.168.1.122 | 2 / 4GB / 50GB |

| 項目 | 値 |
|---|---|
| クラスタ名 | `talos-ha` |
| エンドポイント | `https://192.168.1.110:6443`（VIP） |
| GW / DNS | `192.168.1.1` |
| Talos / Kubernetes | v1.14.6 / v1.37.1 |
| CNI | Flannel（デフォルト） |
| NTP | `ntp.nict.jp` |

ctrl01 は [stand-alone](../stand-alone/) 構成の VM をリセットして使い回しているため、ディスクが 50GB になっている。

## ファイル

```
gen-config.sh              # machine config の生成（secrets.yaml があれば再利用する）
patches/common.yaml        # 全ノード共通: NTP, DNS
patches/controlplane.yaml  # CP 共通: Layer2 VIP
nodes/<ノード名>.yaml       # ノードごと: ホスト名, 静的 IP
_out/                      # 生成物（gitignore 対象・秘密鍵を含む）
```

`gen config` で役割ごとの共通設定（`controlplane.yaml` / `worker.yaml`）を作り、そこに `talosctl machineconfig patch` でノードごとのパッチを当てて `_out/<ノード名>.yaml` を作る。

ノードの一覧と役割は `nodes/` のファイル名で決まる（`ctrl*.yaml` は controlplane、`worker*.yaml` は worker）。ノードを増やすときは `nodes/` にファイルを足すだけでよい。

`talosconfig` の接続先は VIP ではなく CP の実 IP にしている。VIP は etcd が正常なときしか動かないため、障害時に Talos API へ入れなくなるのを避けるため。接続先の IP は `nodes/ctrl*.yaml` から読み取る。

`_out/secrets.yaml` はクラスタの CA と鍵そのもの。リポジトリ外にバックアップしておく。`gen-config.sh` は `secrets.yaml` がないと新しく作るため、失ったまま実行すると、既存のクラスタを管理できない設定ができてしまう。

## 構築手順

`talosctl` は v1.14.6 を使う。インストールされる Talos のバージョンは ISO（1.14.5）ではなく、手元の `talosctl` のバージョンで決まる（インストーラーのイメージがそのバージョンになる）。コマンドはこのディレクトリで実行する。

固定 IP（`.110`〜`.122`）はルーターの DHCP の払い出し範囲に入っている（[既知の問題](#固定-ip-がルーターの-dhcp-の払い出し範囲に入っている)）。構築を始める前に、これらの IP、特に VIP の `.110` が使われていないことを確認する。

### 1. VM の作成

#### ctrl01（stand-alone 構成の VM を使い回す場合）

[stand-alone](../stand-alone/) のクラスタを消して、メンテナンスモードに戻す。stand-alone のクラスタはここで消える。

```bash
talosctl --talosconfig ../stand-alone/_out/talosconfig -n 192.168.1.111 -e 192.168.1.111 \
  reset --graceful=false --reboot \
  --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
```

インストール済みの Talos がディスクから起動し、設定がないのでメンテナンスモードになる（ISO は不要）。IP は DHCP で付く。

新しく VM を作る場合は、下の `qm create` のループに `"100 talos-linux-ctrl01 20"` を足す。

#### ctrl02 以降

Proxmox のシェルで実行する。ISO は `local:iso/talos-linux-1.14.5.iso` を使う。

```bash
for spec in "101 talos-linux-ctrl02 20" "102 talos-linux-ctrl03 20" "111 talos-linux-worker01 50" "112 talos-linux-worker02 50"; do
  set -- $spec
  qm create $1 --name $2 \
    --sockets 2 --cores 1 --cpu x86-64-v2-AES --memory 4096 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single --scsi0 local-lvm:$3,iothread=1 \
    --ide2 local:iso/talos-linux-1.14.5.iso,media=cdrom \
    --boot 'order=scsi0;ide2;net0' --ostype l26
  qm start $1
done
```

メンテナンスモードでは DHCP で IP が付く。コンソールで IP を手で設定する必要はない。MAC アドレスから仮の IP を探す。

```bash
# Proxmox で MAC を確認する
for id in 100 101 102 111 112; do echo "$id $(qm config $id | grep -oP 'virtio=\K[^,]+')"; done
```

macOS の `arp` は MAC を小文字で、各オクテットの先頭の 0 を省いて表示する（`BC:24:11:02:2A:03` は `bc:24:11:2:2a:3`）。次のように書式を揃えてから照合する。

```bash
# 手元でサブネットに ping を打って ARP テーブルを埋める
for i in $(seq 1 254); do ping -c1 -t1 192.168.1.$i >/dev/null 2>&1 & done; wait

# Proxmox で確認した MAC から仮の IP を引く
mac2ip() {
  local m=$(echo "$1" | tr 'A-Z' 'a-z' | sed -E 's/(^|:)0([0-9a-f])/\1\2/g')
  arp -an | grep " at $m " | grep -oE '\([0-9.]+\)' | tr -d '()'
}
mac2ip BC:24:11:02:2A:03
```

ARP テーブルには古いエントリが残るため、1 つの MAC に複数の IP が出ることがある。そのときは `talosctl -n <IP> -e <IP> get disks --insecure` に応答する IP がメンテナンスモードのもの。

### 2. 設定ファイルの生成

```bash
./gen-config.sh
```

### 3. 設定の適用

各ノードの仮の IP に対して実行する。適用するとインストールと再起動が行われ、`nodes/` で指定した固定 IP に切り替わる。

```bash
talosctl apply-config --insecure -n <仮IP> -e <仮IP> -f _out/ctrl01.yaml
# ctrl02, ctrl03, worker01, worker02 も同様
```

DHCP で付いた仮の IP が、他のノードの固定 IP と同じになることがある。その場合は、そのノードに先に適用して IP を空けてから、他のノードに適用する。

### 4. bootstrap と kubeconfig の取得

```bash
export TALOSCONFIG=$PWD/_out/talosconfig

talosctl -n 192.168.1.111 bootstrap    # etcd の初期化。クラスタ作成時に 1 回、1 台だけで実行する
talosctl -n 192.168.1.111 health \
  --control-plane-nodes 192.168.1.111,192.168.1.112,192.168.1.113 \
  --worker-nodes 192.168.1.121,192.168.1.122 \
  --wait-timeout 15m
talosctl kubeconfig _out/kubeconfig

export KUBECONFIG=$PWD/_out/kubeconfig
kubectl get nodes -o wide
```

## 動作確認

### VIP のフェイルオーバー

VIP を持っているノードを確認し、そのノードを再起動する。再起動中も VIP 経由で API に届くことを確認する。

```bash
talosctl -n 192.168.1.111,192.168.1.112,192.168.1.113 get addresses | grep 192.168.1.110
talosctl -n <VIP を持っているノード> reboot --wait=false
while :; do kubectl get --raw /readyz --request-timeout=2s && echo " $(date +%T)"; sleep 2; done
```

2026-11-21 の確認結果: ctrl01 を再起動すると、VIP は即座に ctrl03 に移った。約 3 分の監視中、VIP 経由の `/readyz` は一度も失敗しなかった。`talosctl reboot` は graceful なシャットダウンなので VIP がすぐに手放される。Proxmox の `qm stop` などで強制停止した場合は、VIP が移るまでに数十秒かかる見込み（未確認）。

## 既知の問題

### 固定 IP がルーターの DHCP の払い出し範囲に入っている

構築時、ctrl03 に DHCP で `192.168.1.112`（ctrl02 の固定 IP）が割り当てられた。`192.168.1.110`〜`.122` はルーターの DHCP の払い出し範囲に含まれている。PoC なのでこのまま使っているが、ルーターが他の機器にこれらの IP を払い出すと、ノードや VIP と IP がぶつかる。

特定のノードや VIP にときどき届かなくなったら、まず IP の衝突を疑う。恒久的には、ルーターの DHCP の払い出し範囲から `192.168.1.100`〜`.149` を外す。
