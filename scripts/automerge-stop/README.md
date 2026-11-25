# automerge-stop

Stops Renovate merging anything, in every repo, until you resume it.

```bash
./automerge-stop.sh
```

1. The script opens GitHub's installed apps page.
2. Suspend Renovate there (**Renovate → Configure → Suspend**), then press Enter.
3. The script turns off auto-merge on every open Renovate PR. GitHub would merge an armed PR without Renovate.

## Resuming

Look over the open PRs first. Then choose **Unsuspend** on the same page. Renovate's next run merges whatever passes its checks.
