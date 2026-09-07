# Cluster Backup

## backup-cluster-state.sh

Captures every cluster secret, app data, node config, and the k3s control-plane datastore to
`~/Desktop/cluster-backup/`. About 7GB, a few minutes. Run it monthly and before anything that
could damage the cluster.

The datastore step stops k3s on `ctrl-1` for about a minute, so the API server is away near the
end of the run - k3s here is a single server on SQLite, and a copy taken while it writes can be
torn. The script waits for `/readyz` and fails loudly if it does not come back.

### 1. Run the backup

Clear the previous output first, or old files mix with new.

```bash
rm -rf ~/Desktop/cluster-backup
bash ~/Developer/homelab/docs/cluster-backup/backup-cluster-state.sh
```

### 2. Encrypt

> `age -p` will prompt for a passphrase twice. Remember it - you need it to decrypt.

```bash
cd ~/Desktop && tar czf - cluster-backup/ | age -p > ~/Desktop/cluster-backup.tar.gz.age
```

Prove it decrypts before deleting anything. An unverified backup is not a backup.

```bash
age -d ~/Desktop/cluster-backup.tar.gz.age | tar tzf - | wc -l
```

### 3. Delete the plaintext output

```bash
rm -rf ~/Desktop/cluster-backup/
```

Move `~/Desktop/cluster-backup.tar.gz.age` somewhere safe yourself.

---

### Decrypt (when you need to restore)

**1. Create the destination:**
```bash
mkdir -p ~/Desktop/unencrypted-backup
```

**2. Decrypt to a tar:**
```bash
age -d ~/Desktop/cluster-backup.tar.gz.age > ~/Desktop/cluster-backup.tar.gz
```

**3. Untar:**
```bash
tar xzf ~/Desktop/cluster-backup.tar.gz -C ~/Desktop/unencrypted-backup --strip-components=1
```

**4. Clean up:**
```bash
rm ~/Desktop/cluster-backup.tar.gz
```
