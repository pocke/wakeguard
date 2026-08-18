# リリース

## いつ上げるか

利用者から見える変更を入れたら、そのたびに上げる。機能追加もバグ修正も挙動の変更も同じ。**上げない限り、その変更は誰にも届かない**。

置き場所は変更の出し方で決まる。

- PR 1 つで済むなら、その PR の中でコミットを分けて入れる
- Stack PR なら、stack のいちばん上にバージョンを上げるだけの PR を積む

どちらでも、バージョンを上げるコミットは `version` の 1 行だけにして、他の変更と混ぜない。

## 上げ方

`.claude-plugin/plugin.json` の `version` を書き換える。master に入った時点で公開される。`.claude-plugin/marketplace.json` の `source` がこのリポジトリ自身を指していて、利用者は `/plugin marketplace add pocke/wakeguard` で入れているので、別途の公開作業は無い。

Claude Code は更新の要否をバージョン文字列で判断していて、`plugin.json` → マーケットプレイスのエントリ → ソースのコミット の順に解決し、インストール済みのものと一致したら更新をスキップする。master に何を積んでも、ここが同じままなら利用者は古いものを使い続ける。`marketplace.json` には `version` を書いていないので、触るのは `plugin.json` だけ。

タグも GitHub リリースも作らない。バージョン解決はそのどちらも読まないため。

## 番号の選び方

0.x のあいだは、機能追加も互換性を壊す変更も minor。patch はバグ修正だけ。

## バージョンを上げるコミットに入れられないもの

利用者から見える前提が変わるなら、README.md と README.ja.md の**両方**を、同じ PR の中でも先のコミットで直しておく。バージョンのコミットは `version` の 1 行だけにするので、そこでは直せない。

## 上げるたびに、動いているホルダーが取り残される

Windows ホルダーの判別に使うホルダースクリプトのパスにバージョンが入るため。README.ja.md の「眠れないまま放置しないために」の末尾に書いてある。

参考: https://code.claude.com/docs/en/plugins-reference#version-management
