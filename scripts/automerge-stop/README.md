# automerge-stop

Stops Renovate merging anything, in every repo, until you resume it.

```bash
./automerge-stop.sh
```

It opens GitHub's installed apps page. Suspend Renovate there (**Renovate → Configure → Suspend**), then press Enter. The script then disarms auto-merge on every open Renovate PR, since GitHub merges an armed PR without Renovate.

## Resuming

On the same page, choose **Unsuspend**. Renovate picks up on its next run and merges whatever passes its checks, so look over the open PRs first.
