# Cluster Backup

[backup-cluster-state.sh](./backup-cluster-state.sh) saves every cluster secret, app data, node config and the k3s datastore to `~/Desktop/cluster-backup/`. Run it monthly and before anything risky.

| What | Detail |
|---|---|
| Size and time | About 7GB, a few minutes |
| Datastore step | Stops k3s on `ctrl-1` for about a minute. k3s here is one server on SQLite. A copy taken mid-write can be torn |
| API server | Away near the end of the run. The script waits for `/readyz` and fails loudly if it does not return |

## Back up

1. Clear the old output, or old files mix with new.
   ```bash
   rm -rf ~/Desktop/cluster-backup
   bash ~/Developer/homelab/docs/cluster-backup/backup-cluster-state.sh
   ```
2. Encrypt. `age -p` asks for a passphrase twice. You need it to decrypt.
   ```bash
   cd ~/Desktop && tar czf - cluster-backup/ | age -p > ~/Desktop/cluster-backup.tar.gz.age
   ```
3. Prove it decrypts before deleting anything.
   ```bash
   age -d ~/Desktop/cluster-backup.tar.gz.age | tar tzf - | wc -l
   ```
4. Delete the plaintext output.
   ```bash
   rm -rf ~/Desktop/cluster-backup/
   ```
5. Move `~/Desktop/cluster-backup.tar.gz.age` somewhere safe yourself.

## Decrypt

```bash
mkdir -p ~/Desktop/unencrypted-backup
age -d ~/Desktop/cluster-backup.tar.gz.age > ~/Desktop/cluster-backup.tar.gz
tar xzf ~/Desktop/cluster-backup.tar.gz -C ~/Desktop/unencrypted-backup --strip-components=1
rm ~/Desktop/cluster-backup.tar.gz
```
