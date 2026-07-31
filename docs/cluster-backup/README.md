# Cluster Backup

## backup-cluster-state.sh

Captures all cluster secrets, app data, and node config to `~/Desktop/cluster-backup/`.

### 1. Run the backup

```bash
bash ~/Developer/homelab/docs/cluster-backup/backup-cluster-state.sh
```

### 2. Encrypt

> `age -p` will prompt for a passphrase twice. Remember it — you need it to decrypt.

```bash
cd ~/Desktop && tar czf - cluster-backup/ | age -p > ~/Desktop/cluster-backup.tar.gz.age
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
