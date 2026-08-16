# wakeguard — Claude Code 作業中スリープ抑制ツール 設計書

## 1. 目的と要件

Claude Code が**作業中の間だけ** PC をスリープさせないツール `wakeguard` を、Claude Code プラグインとして実装する。

- 作業中 = ユーザがプロンプトを送信してから、そのターンが完了するまで。
  - Claude Code プロセスの起動中ずっと、ではない（アイドル中はスリープ可）。
- Claude Code プロセスは複数同時に起動されうる。
- 終了時（クラッシュ含む）に、そのプロセス由来のスリープ抑制を必ず解除する。「眠れないまま放置」は絶対に起こさない。
- 対象 OS: macOS / Windows(native) / WSL2。
- Windows では bash の存在（Git Bash 等）を前提とする。
- バックグラウンドタスク中の抑制はスコープ外。

## 2. アーキテクチャ

**「1 セッション = 1 抑制ホルダープロセス」。参照カウントは OS に任せる。**

実装は 2 ファイル: 本体の bash スクリプト `wakeguard.sh` と、Windows 用スリープ抑制ホルダー `wakeguard-hold.ps1`（macOS における `caffeinate` 相当）。

```
UserPromptSubmit フック
  └ wakeguard.sh start
      ├ 環境判定 (macOS / native Windows / WSL2)
      ├ 抑制ホルダーをデタッチ起動
      │    macOS:   caffeinate -i [-w <claude_pid>]
      │    Windows: powershell.exe → wakeguard-hold.ps1 (SetThreadExecutionState)
      │    WSL2:    powershell.exe (interop) → wakeguard-hold.ps1  ※抑制対象は Windows ホスト
      └ pidfile 書き込み → 即終了（bash 自体は残らない）

Stop / StopFailure / SessionEnd フック
  └ wakeguard.sh stop
      └ pidfile のホルダー PID を（同一性確認のうえ）kill → pidfile 削除

SessionStart フック
  └ wakeguard.sh reap
      └ 孤児ホルダー（親 Claude が死んでいる等）を掃除
```

設計の根拠となる性質:

- 複数セッションが同時に作業中なら、ホルダーが複数生きるだけ。**1 個でも生きていれば OS は寝ない**ので、参照カウントは OS レベルで自然に成立する。
- 抑制の解除 = ホルダープロセスの終了。macOS の caffeinate も Windows の `SetThreadExecutionState(ES_CONTINUOUS)` も、**プロセス消滅時に OS が抑制を自動クリア**するため、外部からの kill による解除は安全（PowerShell 側の finally が走らなくても眠れない状態は残らない）。
- **WSL2 内でスリープ抑制をしても無意味**（Windows ホストがスリープすると VM ごとサスペンドされる）。WSL2 では必ず interop（`powershell.exe` 呼び出し）で **Windows ホスト側**にホルダーを立てる。

## 3. リポジトリ構成（Claude Code プラグイン）

```
wakeguard/
├── .claude-plugin/
│   ├── plugin.json            # name: "wakeguard" 等のメタデータ
│   └── marketplace.json       # 自己参照 (source: "./") で配布
├── hooks/
│   └── hooks.json             # フック定義（下記）
├── bin/
│   ├── wakeguard.sh           # 本体 (start / stop / reap / status)
│   └── wakeguard-hold.ps1     # Windows 用ホルダー（caffeinate 相当）
├── .gitattributes             # ★必須: *.sh text eol=lf / *.ps1 text eol=crlf
└── README.md
```

- スクリプト直置きのため、ビルド・リリース・ダウンロード工程は不要。導入は `/plugin marketplace add <owner>/wakeguard` → `/plugin install wakeguard@wakeguard` の 2 コマンド。
- `.gitattributes` は必須。CRLF で checkout された .sh は shebang が `bash\r` になり全フックが "bad interpreter" で死ぬ（Windows の既知の罠）。

### hooks/hooks.json

```json
{
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/bin/wakeguard.sh\" start", "timeout": 10 } ] }
  ],
  "Stop": [
    { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/bin/wakeguard.sh\" stop", "timeout": 10 } ] }
  ],
  "StopFailure": [
    { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/bin/wakeguard.sh\" stop", "timeout": 10 } ] }
  ],
  "SessionEnd": [
    { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/bin/wakeguard.sh\" stop", "timeout": 10 } ] }
  ],
  "SessionStart": [
    { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/bin/wakeguard.sh\" reap", "timeout": 10 } ] }
  ]
}
```

- フックは stdin に JSON（`session_id`, `cwd`, `hook_event_name` 等）を受け取る。
- **常に exit 0**。抑制の失敗でユーザのターンを妨げない（エラーはログへ）。

## 4. bin/wakeguard.sh 仕様

### 4.1 サブコマンド

| コマンド | 動作 |
|---|---|
| `start` | 環境判定 → ホルダーをデタッチ起動 → pidfile 書き込み。既に同一セッションの pidfile があれば何もしない（冪等）。 |
| `stop` | pidfile の PID を同一性確認のうえ kill → pidfile 削除。pidfile が無ければ何もしない。 |
| `reap` | 全 pidfile を走査し、無効なもの（後述）のホルダーを kill して pidfile 削除。 |
| `status` | 現在の pidfile とホルダー生存状態を表示（デバッグ用）。 |

### 4.2 環境判定

```bash
detect_env() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo winbash ;;   # Git Bash 等 (native Windows)
    *) echo unknown ;;
  esac
}
```

- `linux`（純 Linux）はスコープ外だが、`systemd-inhibit --what=idle sleep infinity` へのフォールバックを入れておくとほぼタダで対応できる（任意）。
- native Windows で `bash` が WSL の bash に解決されてしまった場合、判定は `wsl` になるが、その経路でも powershell.exe 経由でホスト抑制になるため**結果は正しい**（この設計の利点）。

### 4.3 session_id の取得（jq 非依存）

stdin の JSON から sed で抜く（フック環境に jq を仮定しない）:

```bash
INPUT="$(cat)"   # stdin を必ず読み切る
SESSION_ID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$SESSION_ID" ] || SESSION_ID="unknown-$$"
```

### 4.4 pidfile

- 置き場所: `${XDG_STATE_HOME:-$HOME/.local/state}/wakeguard/sessions/<session_id>.pid`
- 内容（KEY=VALUE 形式）:

```
HOLDER_PID=12345          # kill 対象（macos/linux は Unix PID、winbash/wsl は Windows PID）
HOLDER_KIND=caffeinate    # caffeinate | powershell | systemd-inhibit
CLAUDE_PID=9876           # start 時に推定した Claude 本体の PID（reap 用、best effort）
ENV=macos                 # detect_env の結果
STARTED_AT=1755300000
```

- `CLAUDE_PID` の推定: フックのシェルから親を辿る（`ps -o ppid= -p $PPID` 等）。取れなければ空で可（reap は STARTED_AT ベースの判定にフォールバック）。

### 4.5 start: ホルダーのデタッチ起動

**macOS:**

```bash
# -w <pid>: Claude 本体が死んだら caffeinate も自動終了（クラッシュ保険）
nohup caffeinate -i ${CLAUDE_PID:+-w "$CLAUDE_PID"} >/dev/null 2>&1 &
HOLDER_PID=$!
disown
```

- 画面も点けたい場合は設定で `-d` を追加（§6）。

**native Windows (Git Bash) / WSL2 共通:**

interop / Git Bash どちらからも `powershell.exe` で Windows 側にホルダーを立てる。フックの寿命から切り離すため `Start-Process -WindowStyle Hidden -PassThru` でデタッチ起動し、**Windows PID** を標準出力で受け取る:

```bash
PS1_WIN="$(to_winpath "$PLUGIN_ROOT/bin/wakeguard-hold.ps1")"  # cygpath -w / wslpath -w
HOLDER_PID="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
  "(Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PS1_WIN','-TimeoutHours','8' -WindowStyle Hidden -PassThru).Id" \
  | tr -d '\r')"
```

- パスは必ず `cygpath -w`（Git Bash）/ `wslpath -w`（WSL）で Windows 形式へ変換する。MSYS のパス自動変換に任せない。
- powershell.exe の起動は数百 ms かかるが、ターン開始時に 1 回だけなので許容。

### 4.6 stop: kill と同一性確認

PID 再利用による誤爆を防ぐため、**kill 前にプロセスの正体を確認**する:

```bash
# macos/linux
ps -o comm= -p "$HOLDER_PID" 2>/dev/null | grep -q "$HOLDER_KIND" && kill "$HOLDER_PID"

# windows (winbash/wsl)
powershell.exe -NoProfile -Command \
  "if ((Get-Process -Id $HOLDER_PID -ErrorAction SilentlyContinue).ProcessName -eq 'powershell') { Stop-Process -Id $HOLDER_PID -Force }"
```

kill 後（またはプロセスが既に居ない場合）に pidfile を削除。

### 4.7 reap: 孤児掃除

各 pidfile について、以下のいずれかなら「無効」とみなしホルダーを kill（同一性確認つき）して pidfile 削除:

1. `HOLDER_PID` のプロセスが既に存在しない（→ pidfile 削除のみ）。
2. `CLAUDE_PID` が記録されており、そのプロセスが存在しない（Claude がフック発火なしに死んだケース）。
3. `STARTED_AT` から上限時間（既定 8h、§6 で設定可）を超過。
4. pidfile が壊れている。

## 5. bin/wakeguard-hold.ps1 仕様

Windows 用のスリープ抑制ホルダー。既存の Prevent-Sleep.ps1（`Add-Type` による P/Invoke で `kernel32.dll` の `SetThreadExecutionState` を呼び、`ES_CONTINUOUS -bor ES_SYSTEM_REQUIRED` を立て、失敗時 throw、finally で解除する構造）をベースに、以下を実装する:

1. **「外部から kill されるまで保持」モード**を主用途とする。`-TimeoutHours <double>` パラメータ（既定 8）を追加し、待機ループを期限付きにする:
   ```powershell
   $deadline = (Get-Date).AddHours($TimeoutHours)
   while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 30 }
   ```
   これが「フックも reap も全部すり抜けた」場合の最後の dead-man's brake になる。
2. **`-KeepDisplayOn`** スイッチでディスプレイ点灯維持（`ES_DISPLAY_REQUIRED` を追加）。wakeguard.sh の設定から渡す。
3. `-ScriptBlock` モード（`.\wakeguard-hold.ps1 { npm run build }` のように任意コマンド実行中だけ抑制）も持たせてよい。単体ツールとしての汎用性のため。wakeguard.sh からは ScriptBlock なし・Timeout 指定で起動する。
4. 通常の解除経路は **wakeguard.sh stop による Stop-Process**。この場合 finally は走らないが、`SetThreadExecutionState` の抑制はプロセス消滅で OS が自動クリアするため問題ない（finally は Ctrl+C 等の行儀よい終了時の保険として残す）。
5. `#Requires -Version 5.1`、`Set-StrictMode -Version Latest`、`$ErrorActionPreference = 'Stop'` を維持。

## 6. ユーザー設定

環境変数（または `~/.config/wakeguard/config` を source）で上書き可能にする:

| 変数 | 意味 | 既定 |
|---|---|---|
| `WAKEGUARD_CMD` | 抑制コマンドを完全に明示指定（例: `caffeinate -dims`）。指定時は環境判定より優先。 | 未設定 |
| `WAKEGUARD_DISPLAY` | `1` でディスプレイも点灯維持（mac: `-d` / win: `-KeepDisplayOn`） | `0` |
| `WAKEGUARD_MAX_HOURS` | ホルダーの自己終了上限 | `8` |
| `WAKEGUARD_LOG` | ログファイルパス（デバッグ時のみ） | 未設定 |

`WAKEGUARD_CMD` 指定時は「そのコマンドをデタッチ起動して PID を記録、stop で kill」という同じ枠組みに乗せる。

## 7. クラッシュ安全（多層防御）

| 終了の仕方 | 解除する仕組み |
|---|---|
| ターン正常/異常終了 | `Stop` / `StopFailure` フック → stop |
| セッション終了 (exit, Ctrl-C 等) | `SessionEnd` フック → stop |
| Claude 強制 kill・クラッシュ | macOS: `caffeinate -w` が自動終了 / 全 OS: 次回 `SessionStart` の reap（CLAUDE_PID 死亡検知） |
| フックが一切発火しない | ホルダー自身の `WAKEGUARD_MAX_HOURS` タイムアウトで自己終了 |
| WSL ごと消滅（`wsl --shutdown` 等） | Windows ホルダーは生き残るが、タイムアウト + 次回 reap（interop 経由で kill）で解除 |

検証コマンド: macOS `pmset -g assertions` / Windows `powercfg /requests`。

## 8. bash on Windows の既知の罠（実装時チェックリスト）

- [ ] `.gitattributes` に `*.sh text eol=lf` を入れた（CRLF → "bad interpreter" 対策）。
- [ ] powershell.exe へ渡すパスは `cygpath -w` / `wslpath -w` で明示変換している。
- [ ] pidfile 等の自前パスは `$HOME` 起点（Git Bash でも WSL でも有効）で、Windows ユーザ名をハードコードしていない。
- [ ] フックは常に exit 0（stderr 汚染も避ける。ログはファイルへ）。
- [ ] stdin の JSON を読み切ってから処理している（読まないまま exit すると SIGPIPE の恐れ）。
- [ ] `set -u` 使用時、未定義変数のデフォルトを与えている。

## 9. テスト計画

- **macOS**: ターン中に `pmset -g assertions` で PreventUserIdleSystemSleep が立つ / Stop 後に消える。2 セッション同時 → 片方 stop で継続、両方 stop で解除。`kill -9` した Claude の caffeinate が `-w` で自動終了する。
- **Windows (native)**: ターン中に `powercfg /requests` の SYSTEM に powershell が出る / Stop 後に消える。Git Bash から起動したホルダーがフック終了後も生存している（デタッチ確認）。
- **WSL2**: WSL 内のターン中に **Windows ホスト側**の `powercfg /requests` に出る。`wsl --shutdown` 後、reap or タイムアウトで解除される。
- **共通**: pidfile の PID を別プロセスが再利用しているケースで stop が誤爆しない（同一性確認）。SessionStart の reap が壊れた pidfile を掃除できる。

## 10. 実装ステップ

1. リポ雛形: `.claude-plugin/plugin.json`・`marketplace.json`・`hooks/hooks.json`・`.gitattributes`。
2. `wakeguard.sh`: 共通部（stdin パース、pidfile I/O、detect_env、ログ）→ `start`/`stop` → `reap`/`status`。
3. `wakeguard-hold.ps1`: §5 の仕様で実装。
4. macOS で結合テスト → Windows (Git Bash) → WSL2 の順に検証（§9）。
5. README（導入 2 コマンド、設定変数、検証コマンド）。

## 付録: 取らなかった選択肢

本設計に至る過程で検討し、採用しなかった案。再検討時の参考として残す。

- **中央デーモン + リースファイル + 参照カウント方式**: ホストに 1 個のスーパバイザを常駐させ、セッションごとのリースファイルを集計して抑制を一元管理する案。複数プロセスの管理は正確になるが、単一性ロック・リース回収・heartbeat 等の機構が必要でオーバーエンジニアリング。「ホルダープロセスが 1 個でも生きていれば OS は寝ない」という OS の性質でカウントを代替できるため不採用。
- **Go 実装 + GitHub Releases でのバイナリ配布**: CGO 無効の静的バイナリを GoReleaser でクロスコンパイルし、SessionStart で checksum 検証つきダウンロードする案。依存ゼロで堅牢だが、ビルド・リリース・DL・検証のパイプライン一式が必要。デーモン廃止によりロジックがシェルで足りる規模に縮小したため、スクリプト直置き配布のシンプルさを優先して不採用。
- **Node.js 実装**: Claude Code の実行環境に Node があることを利用する案。Claude Code が将来別言語で書き直される・Node が外部から利用可能な形で露出していない可能性があり、他者のランタイムへの依存は脆弱。また常駐・プロセス管理主体のツールに非同期前提の API が不向きなため不採用。
- **WSL2 内部での抑制（systemd-inhibit 等）**: Windows ホストがスリープすると WSL2 は VM ごとサスペンドされるため、Linux 側での抑制は目的を達成できず不採用。ホスト側抑制が唯一の有効手段。
- **WSL2 → ホスト間の TCP 通信**: localhost TCP はネットワークモード（NAT / mirrored）で到達性が変わり環境依存で壊れやすいため不採用。interop によるプロセス起動と共有ファイルシステムで代替。
- **バックグラウンドタスク中の抑制**: 「バックグラウンドタスク完了」を確実に検知してスリープ制御へ結びつけるフックがなく、対応すると解除漏れリスクが増すため初版ではスコープ外。将来対応する場合は、バックグラウンドプロセスの PID を対象にしたホルダー（PID 消滅で自動解除）として同じ枠組みに追加できる。
