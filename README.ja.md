# wakeguard

[English](README.md)

Claude Code がターンを処理している間だけ PC をスリープさせず、ターンが終わったらすぐにスリープできる状態へ戻す Claude Code プラグイン。アイドル中のセッションやクラッシュしたセッションが PC のスリープを阻害することはない。

対象は macOS・Windows (Git Bash)・WSL2。Linux 単体には `systemd-inhibit` によるフォールバックがある。

## 導入

```
/plugin marketplace add pocke/wakeguard
/plugin install wakeguard@wakeguard
```

## 仕組み

1 セッションにつき、フックから切り離した抑制ホルダープロセスを 1 個立て、参照カウントは OS に任せる。ホルダーが 1 個でも生きていれば PC は寝ないので、複数のセッションが同時に動いていても共有のカウンタは要らない。抑制の解除はホルダーを kill するだけ。

```
UserPromptSubmit  ->  wakeguard.sh start   ホルダーを起動し pidfile に記録する
Stop, StopFailure ->  wakeguard.sh stop    ホルダーを kill し pidfile を消す
SessionEnd        ->  wakeguard.sh stop
SessionStart      ->  wakeguard.sh reap    取り残されたホルダーを片付ける
```

環境ごとのホルダーは次のとおり。

| 環境 | ホルダー |
|---|---|
| macOS | `caffeinate -i -t <上限時間を秒にしたもの> -w <claude の PID>` |
| Windows (Git Bash) | `wakeguard-hold.ps1` を実行する `powershell.exe` |
| WSL2 | 同じ PowerShell ホルダーを、interop 経由で **Windows ホスト側**に立てる |
| Linux | `systemd-inhibit --what=idle` |

WSL2 の内部で抑制しても意味がない。Windows ホストはスリープするとき VM ごとサスペンドするため。だから WSL2 でも必ずホスト側にホルダーを置く。

pidfile は `${XDG_STATE_HOME:-~/.local/state}/wakeguard/sessions/` に置く。

## 設定

環境変数で渡すか、`${XDG_CONFIG_HOME:-~/.config}/wakeguard/config` に `KEY=value` の行として書く。同じ変数が両方にあれば環境変数が勝つ。

| 変数 | 意味 | 既定値 |
|---|---|---|
| `WAKEGUARD_CMD` | 環境判定で選ばれるホルダーの代わりに、このコマンドをホルダーとして起動する (例: `caffeinate -dims`)。空白で区切るので、引数をクォートでまとめることはできない | 未設定 |
| `WAKEGUARD_DISPLAY` | `1` にするとディスプレイも点けたままにする (`caffeinate -d` / `-KeepDisplayOn`)。Linux では効かない | `0` |
| `WAKEGUARD_MAX_HOURS` | ホルダーが自分から終了するまでの上限時間。[0.001, 168] の数値で、それ以外を書くと既定値に戻る | `8` |
| `WAKEGUARD_LOG` | 診断メッセージをこのファイルに追記する。設定しない限りログはどこにも出ないので、wakeguard が効いていないと感じたらまずこれを設定する | 未設定 |

## 効いているか確かめる

`wakeguard.sh status` は記録済みのホルダーとその状態を一覧する。プラグインは `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` の下に入るので、手元のパスを調べてから実行する。

```
ls -d ~/.claude/plugins/cache/*/wakeguard/*/bin/wakeguard.sh
bash <表示されたパス> status
```

OS 側から抑制を確認するなら、ターンの実行中に次を実行する。

- macOS: `pmset -g assertions` で `PreventUserIdleSystemSleep` を探す
- Windows: 管理者権限のプロンプトで `powercfg /requests` を実行し、`SYSTEM` の下に `powershell` が出るか見る。WSL2 から使っている場合も、確認するのは WSL の中ではなく Windows ホスト側

## 眠れないまま放置しないために

セッションの終わり方それぞれに、抑制を解除する仕組みがある。

| 終わり方 | 解除する仕組み |
|---|---|
| ターンが正常終了するか API エラーで終わる | `Stop` / `StopFailure` フック |
| exit や Ctrl-C でセッションが終わる | `SessionEnd` フック |
| Claude Code が kill された・クラッシュした | macOS では `caffeinate -w` が Claude Code と一緒に終了する。どの OS でも、次の `SessionStart` の reap が死んだ PID に気づく |
| ホルダーを記録する前にフックが kill された | 次の `SessionStart` の reap が、どの pidfile からも参照されていないホルダーをまとめて片付ける (Windows と Linux のみ)。macOS にはこの片付けがない。`caffeinate` には wakeguard 由来かどうかを見分ける目印を付けられないので、記録されなかったものは `caffeinate -w` と `-t` の期限に委ねる |
| フックが 1 つも発火しない | ホルダー自身が持つ `WAKEGUARD_MAX_HOURS` の期限。ただし `WAKEGUARD_CMD` のホルダーには期限が付かず、1 つ上の行の片付けの対象にもならない。任意のコマンドに期限を渡す方法がなく、wakeguard が名前を知らないプロセスを自分のものと判別する方法もないため |
| `wsl --shutdown` | Windows ホルダーは VM より長生きするが、次に始まる WSL のセッションが interop 経由で片付ける |

kill する前に、記録した PID が本当に自分が起動したホルダーかどうかを毎回確認する。Unix ではコマンド名で、Windows ではコマンドラインに含まれるホルダースクリプトのパスで判定する。PID が再利用されていても無関係なプロセスを kill することはない。

**把握しておくべき穴が 2 つある。** Esc でターンを中断しても `Stop` は発火しないので、ホルダーは次のターンが終わるかセッションが終わるまで残る。それまで PC は自分からは眠らない。

もう 1 つ。Windows ホルダーの判別に使うホルダースクリプトのパスにはプラグインのバージョンが含まれる。ホルダーが動いている最中にプラグインを更新すると、新しいバージョンからは wakeguard 以外が起動したプロセスに見えて、kill の対象から外れる。そうなったホルダーは `WAKEGUARD_MAX_HOURS` の期限まで残る。

## Linux について

`systemd-inhibit --what=idle` が止めるのは logind 自身の `IdleAction` だけ。GNOME や KDE のように独自のアイドルタイマーでサスペンドするデスクトップ環境はこれを見ないので、その環境では抑制が効かない。

## スコープ外

バックグラウンドタスク。その完了を知らせるフックがなく、対応すると抑制を解除し損ねる経路が増えるため。
