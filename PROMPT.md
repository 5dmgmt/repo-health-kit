# Claude Code に頼むときのプロンプト

Claude Code（ターミナル版、またはデスクトップアプリの Code タブ）に、次の枠の中をそのまま貼り付けてください。Claude Code が README を読みながら、入れる・設定する・初回の点検までを一緒に進めます。

```text
私の Mac に repo-health-kit を入れて設定するのを手伝ってください。
repo-health-kit は、Mac にある git リポジトリを毎朝点検し、対応が必要なことがあればメールとデスクトップ通知で知らせる道具です。
公開リポジトリ: https://github.com/5dmgmt/repo-health-kit

進め方:
1. リポジトリを ~/Tools/repo-health-kit に clone し、README.md を最後まで読んでから始めてください。
2. 前提のコマンド（bash・git・python3・curl。あれば node・npm）がそろっているか確かめてください。足りないものを入れる前に、何をどう入れるかを私に確認してください。
3. 私の git リポジトリがどのフォルダにあるかを私に聞いてから、./install.sh を実行してください。そのあと ~/.config/repo-health-kit/config.sh の RH_ROOTS を、そのフォルダにしてください。
4. メールは Resend で送ります。Resend のアカウント作成と API キーの作成は私が行います。キーの保存は、README にある security add-generic-password のコマンドを私が自分のターミナルで実行し、キーも私が自分で貼り付けます。あなたは API キーを聞かない・表示しない・ファイルや設定に書かないでください。
5. 宛先のメールアドレス（RH_MAIL_TO）を私に聞いて設定し、RH_MAIL_METHOD を resend にして、--test-mail でテスト送信してください。
6. RH_NOMAIL=1 を付けて一度点検を実行し、~/Library/Logs/repo-health-kit/repo-health-latest.md の「要対応」を、専門用語をなるべく使わずに説明してください。
7. 毎朝の点検の時刻（初期値は 9:20）を変えたいか私に聞いてください。変える場合は RH_SCHEDULE を直し、./install.sh をもう一度実行してください。

守ってほしいこと:
- 私のリポジトリのファイルを消す・commit する・push する・stash を消す、といった操作はしないでください。点検で見つかったことを直したいときは、何をどう直すかを先に説明し、私の了解を取ってから進めてください。
- .env などのシークレットの中身を表示しないでください。
- 設定を変えるときは、変える前と後の内容を見せてください。
```

## 届いたメールについて相談するとき

毎朝のメールで気になることがあったら、Claude Code に次のように頼めます。

```text
~/Library/Logs/repo-health-kit/repo-health-latest.md の FAIL と WARN を読み、それぞれの原因を調べてください。作業中の変更は消さないでください。直す前に、何をどう直すかと影響する範囲を説明してください。
```
