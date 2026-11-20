# Proxmox 上のシングルノード Talos クラスタ

Proxmox VE の VM 1 台で Talos Linux のコントロールプレーンを動かし、そのノードでワークロードも実行する構成。

> 2026-11-21 以降、この VM（ctrl01）は [HA 構成](../ha/) のコントロールプレーン 1 台目として使っている。このクラスタは残っていない。

## 構成

| 項目 | 値 |
|---|---|
| Proxmox ホスト | `192.168.1.101`（ノード名 `pve`） |
| VM | VMID `100` / `talos-linux-ctrl01` / 4GB RAM / 50GB ディスク（SCSI・VirtIO SCSI コントローラー, ゲストからは `/dev/sda`） |
| NIC | `net0: virtio, bridge=vmbr0`（ゲスト側 `ens18`, MAC `bc:24:11:71:32:0c`） |
| IP | `192.168.1.111/24`、GW / DNS `192.168.1.1` |
| クラスタ名 | `talos-poc` |
| エンドポイント | `https://192.168.1.111:6443` |
| Talos / Kubernetes | v1.14.6 / v1.37.1 |
| CNI | Flannel（デフォルト） |
| NTP | `ntp.nict.jp` |

## ファイル

```
patches/
├── common.yaml   # 全ノード共通: NTP
└── ctrl01.yaml   # ctrl01 固有: ホスト名、静的IP、DNS、control-plane taint の削除
_out/             # 生成物（gitignore 対象・秘密鍵を含む）
```

`_out/secrets.yaml` はクラスタの CA と鍵そのもの。失うと設定を作り直せなくなるので、リポジトリ外にバックアップしておく。

## 構築手順

コマンドはこのディレクトリで実行する。`talosctl` は v1.14.x を使う。生成される設定の形式、インストーラーのイメージ、Kubernetes のバージョンは手元の `talosctl` のバージョンで決まるため、別のバージョンだと上の表とは違う構成になる。

### 1. VM の作成と起動

1. [Image Factory](https://factory.talos.dev/) から metal 用 ISO を取得して Proxmox に置く
2. VM を作成する
   - ディスクのバスは **SCSI**（コントローラーは VirtIO SCSI）にする。VirtIO Block にするとゲストからは `/dev/vda` に見え、`--install-disk /dev/sda` へのインストールが失敗する
   - Options → Boot Order で **ディスク（`scsi0`）を CD（`ide2`）より上**にする。ディスクが空のうちは ISO から起動し、インストール後の再起動ではディスクから起動する
   - NIC のファイアウォールは無効でよい
3. ISO から起動し、コンソールに `maintenance mode` と表示されたら、**F3**（Network Config）で IP を `192.168.1.111/24` にする

疎通を確認する。

```bash
talosctl -n 192.168.1.111 -e 192.168.1.111 get disks --insecure
```

### 2. 設定ファイルの生成

```bash
mkdir -p _out
talosctl gen secrets -o _out/secrets.yaml

talosctl gen config talos-poc https://192.168.1.111:6443 \
  --with-secrets _out/secrets.yaml \
  --install-disk /dev/sda \
  --config-patch @patches/common.yaml \
  --config-patch-control-plane @patches/ctrl01.yaml \
  --with-docs=false --with-examples=false \
  -o _out

talosctl validate --config _out/controlplane.yaml --mode metal --strict

talosctl --talosconfig _out/talosconfig config endpoint 192.168.1.111
talosctl --talosconfig _out/talosconfig config node 192.168.1.111
```

### 3. インストール

```bash
talosctl apply-config --insecure -n 192.168.1.111 -e 192.168.1.111 -f _out/controlplane.yaml
```

インストーラーのイメージをダウンロードして `/dev/sda` にインストールし、再起動する。インストール中は `talosctl --talosconfig _out/talosconfig logs machined` で進み具合を確認できる。

インストール後の再起動でメンテナンスモードの画面に戻った場合は、ISO から起動している。ブート順を見直すか、CD/DVD を「Do not use any media」にしてから VM をリセットする。インストールが終わったら、ISO は外しておく。

### 4. bootstrap と kubeconfig の取得

```bash
export TALOSCONFIG=$PWD/_out/talosconfig

talosctl bootstrap              # etcd の初期化。クラスタ作成時に 1 回だけ実行する
talosctl health --wait-timeout 10m
talosctl kubeconfig _out/kubeconfig

export KUBECONFIG=$PWD/_out/kubeconfig
kubectl get nodes -o wide
```

## パッチの書き方（Talos 1.14）

Talos 1.14 では設定の多くが独立したドキュメント（`HostnameConfig`, `LinkConfig`, `ResolverConfig`, `TimeSyncConfig`, `KubeNodeConfig` など）に分かれている。従来の `machine.network.*` / `machine.time.*` / `cluster.allowSchedulingOnControlPlanes` で書くと、`--strict` の検証で「already set in v1alpha1 config」というエラーになる。

各ドキュメントのスキーマは `talosctl docs --config <dir>` で手元に出力できる。

control-plane の taint は、`KubeNodeConfig` へのパッチで `$patch: delete` を指定して消している。

## トラブルシューティング

### ARP は解決するのに ping も 50000 番ポートも応答しない

メンテナンスモードで IP をネットマスクなし（`/32`）で設定すると発生する。VM は同じセグメントの相手を on-link と見なさず、返事をゲートウェイ宛てに送ってしまい、ルーターがそれを捨てる。

Proxmox ホストで次のように確認する。echo reply の宛先 MAC がゲートウェイのものになっていれば、この問題。

```bash
tcpdump -eni tap100i0 icmp
```

対処: コンソールの F3 で `192.168.1.111/24` のようにプレフィックス長付きで設定し直す。

### NTP が `udp port 123 unreachable` になる

メンテナンスモードでは Talos がルーター（`192.168.1.1`）に NTP で問い合わせていたが、ルーター側で NTP のサービスが動いていない（DHCP で NTP サーバーとして配布されていると思われる）。`patches/common.yaml` の `TimeSyncConfig` で `ntp.nict.jp` を指定して回避している。
