# Claude Code に頼むときのプロンプト

Claude Code（ターミナル版、またはデスクトップアプリの Code タブ）に、次の枠の中をそのまま貼り付けてください。Claude Code が README を読みながら、入れる・設定する・初回の点検までを一緒に進めます。0.2.0 から、リポジトリに加えて Mac のセキュリティ（Homebrew の部品・PHP・証明書・macOS のアップデート）も点検します。

すでに入れている方が新しい版に更新するときは、[下の短いプロンプト](#すでに入れている人が新しい版に更新するとき)をお使いください。

```text
私の Mac に repo-health-kit を入れて設定するのを手伝ってください。
repo-health-kit は、Mac にある git リポジトリと、Mac のセキュリティ（Homebrew の部品・PHP・証明書・macOS のアップデート）を毎朝点検し、対応が必要なことがあればメールとデスクトップ通知で知らせる道具です。
公開リポジトリ: https://github.com/5dmgmt/repo-health-kit

進め方:
1. リポジトリを ~/Tools/repo-health-kit に clone し、README.md を最後まで読んでから始めてください。
2. 前提のコマンド（bash・git・python3・curl・perl。あれば node・npm・Homebrew・composer）がそろっているか確かめてください。足りないものを入れる前に、何をどう入れるかを私に確認してください。
3. 私の git リポジトリがどのフォルダにあるかを私に聞いてください。./install.sh は最後に初回の点検を行い、そのとき Homebrew の証明書リスト（ca-certificates）に更新が出ていれば自動で更新します。実行する前にそのことを私に説明し、了解を取ってから ./install.sh を実行してください。そのあと ~/.config/repo-health-kit/config.sh の RH_ROOTS を、そのフォルダにしてください。
4. メールは Resend で送ります。Resend のアカウント作成と API キーの作成は私が行います。キーの保存は、README にある security add-generic-password のコマンドを私が自分のターミナルで実行し、キーも私が自分で貼り付けます。あなたは API キーを聞かない・表示しない・ファイルや設定に書かないでください。
5. 宛先のメールアドレス（RH_MAIL_TO）を私に聞いて設定し、RH_MAIL_METHOD を resend にして、--test-mail でテスト送信してください。
6. RH_NOMAIL=1 を付けて一度点検を実行し、~/Library/Logs/repo-health-kit/repo-health-latest.md の「要対応」と、「Mac のセキュリティ」の結果（「参考」に出たものも含めて）を、専門用語を使わずに説明してください。
7. Node や Python などのセキュリティ部品も自動で更新するか（RH_AUTOFIX_SECURITY を 1 にするか）を私に聞いてください。聞く前に、有効にするとセキュリティの更新が早く入る一方で、Node や Python の版が上がり、開発中のアプリの動きが変わることがある点を説明してください。初期値は 0（自動で更新しない）です。
8. 毎朝の点検の時刻（初期値は 9:20）を変えたいか私に聞いてください。変える場合は RH_SCHEDULE を直し、./install.sh をもう一度実行してください。

守ってほしいこと:
- 私のリポジトリのファイルを消す・commit する・push する・stash を消す、といった操作はしないでください。点検で見つかったことを直したいときは、何をどう直すかを先に説明し、私の了解を取ってから進めてください。
- brew upgrade・brew uninstall など、Mac の部品を更新・削除するときは、先に何をどう変えるかを説明し、私の了解を取ってから進めてください。
- Resend の API キーを聞かない・表示しない・ファイルや設定に書かないでください。
- .env などのシークレットの中身を表示しないでください。
- 設定を変えるときは、変える前と後の内容を見せてください。
```

## 届いたメールについて相談するとき

毎朝のメールで気になることがあったら、Claude Code に次のように頼めます。

```text
~/Library/Logs/repo-health-kit/repo-health-latest.md の FAIL と WARN を読み、それぞれの原因を調べてください。作業中の変更は消さないでください。直す前に、何をどう直すかと影響する範囲を説明してください。brew upgrade・brew uninstall など Mac の部品を更新・削除するときも、先に何をどう変えるかを説明し、私の了解を取ってから進めてください。
```

## すでに入れている人が新しい版に更新するとき

0.1.0 などを入れている方は、次の枠を貼り付けてください。0.2.0 からは、新しい版が出ると毎朝のメールの WARN でお知らせします。

```text
私の Mac に入っている repo-health-kit を、新しい版に更新するのを手伝ってください。
公開リポジトリ: https://github.com/5dmgmt/repo-health-kit

進め方:
1. repo-health-kit を clone したフォルダ（たとえば ~/Tools/repo-health-kit）で git status を確かめ、私の変更が残っていなければ git pull してください。変更が残っていたら、pull する前に私に相談してください。そのあと README.md と CHANGELOG.md を読み、今回の版で増えたことを短く説明してください。
2. ./install.sh の最後の点検で、Homebrew の証明書リスト（ca-certificates）が自動で更新されることがあります。そのことを私に説明してから ./install.sh を実行してください。設定ファイルは上書きされず、新しい設定は書かなくても初期値で動きます。
3. RH_NOMAIL=1 を付けて一度点検を実行し、~/Library/Logs/repo-health-kit/repo-health-latest.md の「要対応」と「Mac のセキュリティ」の結果を、専門用語を使わずに説明してください。
4. Node や Python なども自動で更新するか（RH_AUTOFIX_SECURITY）を私に聞いてください。有効にすると開発中のアプリの動きが変わることがある点を、先に説明してください。

守ってほしいこと:
- brew upgrade・brew uninstall など、Mac の部品を更新・削除するときは、先に何をどう変えるかを説明し、私の了解を取ってから進めてください。
- Resend の API キーを聞かない・表示しない・ファイルや設定に書かないでください。
- 設定を変えるときは、変える前と後の内容を見せてください。
```
