# wakeguard

[English](README.md)

Claude Code がターンを処理している間だけ PC をスリープさせず、ターンが終わったらすぐにスリープできる状態へ戻す Claude Code プラグイン。アイドル中のセッションやクラッシュしたセッションが PC のスリープを阻害することはない。

対象は macOS・Windows (Git Bash)・WSL2。Linux 単体には `systemd-inhibit` によるフォールバックがある。

## 導入

Claude Code のセッション内のプロンプトに打ち込む。

```
/plugin marketplace add pocke/wakeguard
/plugin install wakeguard@wakeguard
```

## 必要なもの

リポジトリに入っているものがそのまま動く。リポジトリを取ってくる以外にビルドもダウンロードも起きないし、追加のランタイムも要らない。

- **どの環境でも**: `bash` と基本的な Unix コマンド (`grep`、`sed`、`awk`、`ps` など)。Windows ではこれらは Git Bash に付いてくる
- **Claude Code 2.1.196 以上**。2 つのものがこのバージョンまでに揃っている。1 つはバックグラウンドで走るフックへの stdin。2.1.72 より前は届かず、セッション ID を読めない wakeguard は何もしないまま黙って終わる。もう 1 つはフック入力の `prompt_id` で、これがあるから前のターンの `stop` が次のターンのホルダーに手を出さずに済む。無いと、続けて 2 ターン走らせたときに抑制が 1 つも残らないことがある
- **Windows と WSL2 では、これに加えて**: Windows に同梱の Windows PowerShell 5.1。追加のモジュールも要らない。WSL2 は interop 経由で呼び、パスの変換に `wslpath` を使う。Git Bash は `cygpath` を使う

スリープの抑制そのものは、OS が既に持っている仕組みに任せる。macOS なら `caffeinate`、Linux なら `systemd-inhibit`、Windows と WSL2 なら PowerShell 経由の `SetThreadExecutionState`。

## 仕組み

1 セッションにつき、フックから切り離した抑制ホルダープロセスを 1 個立て、参照カウントは OS に任せる。ホルダーが 1 個でも生きていれば PC は寝ないので、複数のセッションが同時に動いていても共有のカウンタは要らない。抑制の解除はホルダーを kill するだけ。

```
UserPromptSubmit  ->  wakeguard.sh start        ホルダーを起動し pidfile に記録する
Stop, StopFailure ->  wakeguard.sh stop         そのターンのホルダーを kill する
SubagentStart     ->  wakeguard.sh agent-start  サブエージェント用のホルダーを起動する
SubagentStop      ->  wakeguard.sh agent-stop   そのサブエージェントのホルダーを kill する
SessionEnd        ->  wakeguard.sh end          このセッションのホルダーを全部 kill する
SessionStart      ->  wakeguard.sh reap         取り残されたホルダーを片付ける
```

`agent-start` を除く全部をバックグラウンドで走らせるので、Claude Code はフックの終了を待たない。Windows ホストにホルダーを置くには `powershell.exe` との往復が要り、測ったマシンでは 1 回 0.3 秒かかる。1 ターンで 2 回もこれを待たされる理由はない。`end` も別の形でバックグラウンドに逃がしている。SessionEnd のフックは 1.5 秒のバジェットを共有していて、プラグイン側からは広げられない。ホルダーを何個も解放するにはこれでは足りないので、フックは作業を切り離したプロセスに渡してすぐ返る。

バックグラウンドで走るということは、あるターンの `stop` と次のターンの `start` が重なるということでもある。ターンが終わりかけたところに次のプロンプトが投入されると実際にそうなる。pidfile ごとにロックを置いて 1 つずつ順番に処理し、さらに pidfile にそのホルダーを握っているターンの `prompt_id` を記録して、どちらが先に走ったかに結果が左右されないようにしてある。記録と違う `prompt_id` を持つ `stop` は後続のターンに追い越された側なので、ホルダーには手を出さない。

`agent-start` だけが例外なのは、サブエージェントのホルダーには帰属するターンが無いため。`stop` が名乗るターンは `start` のそれと違うので、`prompt_id` では対にできない。代わりにフックをブロックさせている。すぐ失敗するサブエージェントだと `SubagentStop` が、ホルダーを記録している最中の `SubagentStart` を追い越しかねず、そうなるとそのホルダーを解放するものが無くなる。

環境ごとのホルダーは次のとおり。

| 環境 | ホルダー |
|---|---|
| macOS | `caffeinate -i -t <上限時間を秒にしたもの> -w <claude の PID>` |
| Windows (Git Bash) | `wakeguard-hold.ps1` を実行する `powershell.exe` |
| WSL2 | 同じ PowerShell ホルダーを、interop 経由で **Windows ホスト側**に立てる |
| Linux | `systemd-inhibit --what=idle` |

WSL2 の内部で抑制しても意味がない。Windows ホストはスリープするとき VM ごとサスペンドするため。だから WSL2 でも必ずホスト側にホルダーを置く。

サブエージェントは、それを起動したターンが終わったあとも走り続ける。だからサブエージェント 1 つにつき別のホルダーを立て、`SubagentStop` が来るまで生かしておく。レビューや調査をサブエージェントに投げて結果を待っている間も PC は眠らない。

pidfile は `${XDG_STATE_HOME:-~/.local/state}/wakeguard/sessions/` に置く。ターン用が `<session_id>.pid`、サブエージェント用が `<session_id>.<agent_id>.pid`。ロックは `${XDG_STATE_HOME:-~/.local/state}/wakeguard/locks/` にディレクトリとして作る。pidfile 1 つにつき 1 個で、握っていたプロセスが自分で外し、誰も戻ってこないものは `reap` が掃除する。

## 設定

環境変数で渡すか、`${XDG_CONFIG_HOME:-~/.config}/wakeguard/config` に `KEY=value` の行として書く。同じ変数が両方にあれば環境変数が勝つ。

| 変数 | 意味 | 既定値 |
|---|---|---|
| `WAKEGUARD_CMD` | 環境判定で選ばれるホルダーの代わりに、このコマンドをホルダーとして起動する (例: `caffeinate -dims`)。空白で区切るので、引数をクォートでまとめることはできない | 未設定 |
| `WAKEGUARD_DISPLAY` | `1` にするとディスプレイも点けたままにする (`caffeinate -d` / `-KeepDisplayOn`)。Linux では効かない | `0` |
| `WAKEGUARD_MAX_HOURS` | ホルダーが自分から終了するまでの上限時間。[0.001, 168] の数値で、それ以外を書くと既定値に戻る | `8` |
| `WAKEGUARD_LOG` | 診断メッセージをこのファイルに追記する。設定しない限りログはどこにも出ず、バックグラウンドで走るフックの出力は端末にも流れないので、wakeguard が何をしたか見る手段はこれだけ | 未設定 |

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
| exit や Ctrl-C でセッションが終わる | `SessionEnd` フック。このセッションのホルダーを、サブエージェント用も含めて全部片付ける。そのとき別の wakeguard がロックを握っている pidfile だけは飛ばして reap に回す |
| サブエージェントが終わる | `SubagentStop` フック |
| Claude Code が kill された・クラッシュした | macOS では `caffeinate -w` が Claude Code と一緒に終了する。どの OS でも、次の `SessionStart` の reap が死んだ PID に気づく |
| ホルダーを記録する前にフックが kill された | 次の `SessionStart` の reap が、どの pidfile からも参照されていないホルダーをまとめて片付ける (Windows と Linux のみ)。macOS にはこの片付けがない。`caffeinate` には wakeguard 由来かどうかを見分ける目印を付けられないので、記録されなかったものは `caffeinate -w` と `-t` の期限に委ねる |
| フックが 1 つも発火しない | ホルダー自身が持つ `WAKEGUARD_MAX_HOURS` の期限。ただし `WAKEGUARD_CMD` のホルダーには期限が付かず、1 つ上の行の片付けの対象にもならない。任意のコマンドに期限を渡す方法がなく、wakeguard が名前を知らないプロセスを自分のものと判別する方法もないため |
| バックグラウンドのフックが走っている最中にセッションが閉じる | Claude Code がそのフックを kill する (`claude -p` については明文化されていて、wakeguard を試した限りではどの実行でも同じだった)。行き着く先は「ホルダーを記録する前にフックが kill された」と同じ。そもそも踏めるだけの隙間が空くのは interop の往復を待っている間なので、実際に問題になるのは Windows と WSL2、つまり片付けが動く環境 |
| `wsl --shutdown` | Windows ホルダーは VM より長生きするが、次に始まる WSL のセッションが interop 経由で片付ける |

kill する前に、記録した PID が本当に自分が起動したホルダーかどうかを毎回確認する。Unix ではコマンド名で、Windows ではコマンドラインに含まれるホルダースクリプトのパスで判定する。PID が再利用されていても無関係なプロセスを kill することはない。

表の半分は reap に頼っていて、reap が走るのはセッションが始まるときだけ。次のセッションを始めなければ、解除されずに残ったホルダーはホルダー自身の `WAKEGUARD_MAX_HOURS` の期限まで残る。

**把握しておくべき穴が 3 つある。** Esc でターンを中断しても `Stop` は発火しないので、ホルダーは次のターンが終わるかセッションが終わるまで残る。それまで PC は自分からは眠らない。サブエージェントごと中断した場合に `SubagentStop` が届くかは未確認で、届かなければサブエージェント用のホルダーも同じだけ残る。3 つめは、`Stop` フック (wakeguard のものとは限らない) が block を返してターンをモデルに差し戻す経路。継続にあたって新しいプロンプトは投入されないので、wakeguard はターンが終わったものとしてホルダーを解除し、モデルはその後も動き続ける。

もう 1 つ。Windows ホルダーの判別に使うホルダースクリプトのパスにはプラグインのバージョンが含まれる。ホルダーが動いている最中にプラグインを更新すると、新しいバージョンからは wakeguard 以外が起動したプロセスに見えて、kill の対象から外れる。そうなったホルダーは `WAKEGUARD_MAX_HOURS` の期限まで残る。

## 開発

```
bash test/wakeguard_test.sh
```

テストは `WAKEGUARD_CMD` にただの `sleep` を指定して走るので、PowerShell も `caffeinate` も `systemd-inhibit` も使わずに pidfile・ロック・reap を動かせる。どの環境でも同じように通り、15 秒ほどで終わる。

## Linux について

`systemd-inhibit --what=idle` が止めるのは logind 自身の `IdleAction` だけ。GNOME や KDE のように独自のアイドルタイマーでサスペンドするデスクトップ環境はこれを見ないので、その環境では抑制が効かない。

## スコープ外

**`Bash` のバックグラウンド実行**。完了を確実に知らせるフックがなく、対応すると抑制を解除できないまま残す経路が増えるため。

**`TaskCreated` / `TaskCompleted`**。これはタスクリストへの書き込みと完了のイベントで、何かが走り始めた・終わったことを表さない。抑制のきっかけには使えない。
