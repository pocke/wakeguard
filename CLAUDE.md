# リリース

`.claude-plugin/plugin.json` の `version` を書き換え、それ 1 行だけのコミットにする。master に入った時点で公開される。`.claude-plugin/marketplace.json` の `source` がこのリポジトリ自身を指していて、利用者は `/plugin marketplace add pocke/wakeguard` で入れているので、別途の公開作業は無い。

**上げない限り誰にも届かない。** Claude Code は更新の要否をバージョン文字列で判断していて、`plugin.json` → マーケットプレイスのエントリ → ソースのコミット の順に解決し、インストール済みのものと一致したら更新をスキップする。master に何を積んでも、ここが同じままなら利用者は古いものを使い続ける。`marketplace.json` には `version` を書いていないので、触るのは `plugin.json` だけ。

タグも GitHub リリースも作らない。バージョン解決はそのどちらも読まないため。

## 番号の選び方

0.x のあいだは、機能追加も互換性を壊す変更も minor。patch はバグ修正だけ。

## リリースコミットに入れられないもの

利用者から見える前提が変わるなら、README.md と README.ja.md の**両方**を機能側の PR で直しておく。リリースコミットは version の 1 行だけにするので、そこでは直せない。

## 上げるたびに、動いているホルダーが取り残される

Windows ホルダーの判別に使うホルダースクリプトのパスにバージョンが入るため。README.ja.md の「眠れないまま放置しないために」の末尾に書いてある。

参考: https://code.claude.com/docs/en/plugins-reference#version-management
