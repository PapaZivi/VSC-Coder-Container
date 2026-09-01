#!/usr/bin/env python3
import argparse
import json
import os
import pwd
import re
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

MARKER_NAME = '.fresh-codex-import.json'
COPY_DIRS = ('sessions', 'archived_sessions', 'attachments')


def out(msg):
    print(msg, flush=True)


def get_vscode_ids():
    try:
        p = pwd.getpwnam('vscode')
        return p.pw_uid, p.pw_gid
    except KeyError:
        return 1000, 1000


def safe_chown(path: Path, uid: int, gid: int):
    try:
        os.chown(path, uid, gid, follow_symlinks=False)
    except (PermissionError, FileNotFoundError, NotImplementedError):
        pass


def ensure_dir(path: Path, uid: int, gid: int, mode=None):
    path.mkdir(parents=True, exist_ok=True)
    safe_chown(path, uid, gid)
    if mode is not None:
        try:
            os.chmod(path, mode)
        except PermissionError:
            pass


def copy_file_incremental(src: Path, dst: Path, uid: int, gid: int):
    if src.is_symlink():
        out(f'Symlink uebersprungen: {src}')
        return False

    try:
        s = src.stat()
    except FileNotFoundError:
        return False

    copy_needed = True
    if dst.is_file() and not dst.is_symlink():
        try:
            d = dst.stat()
            # Bei identischer Groesse und mindestens gleich neuer Zieldatei
            # ist keine erneute Datenkopie noetig.
            if d.st_size == s.st_size and d.st_mtime_ns >= s.st_mtime_ns:
                copy_needed = False
        except FileNotFoundError:
            pass

    if not copy_needed:
        return False

    ensure_dir(dst.parent, uid, gid)
    tmp = dst.with_name(dst.name + '.fresh-import-tmp')
    try:
        if tmp.exists() or tmp.is_symlink():
            tmp.unlink()
        shutil.copy2(src, tmp, follow_symlinks=False)
        safe_chown(tmp, uid, gid)
        os.replace(tmp, dst)
        safe_chown(dst, uid, gid)
    finally:
        try:
            if tmp.exists() or tmp.is_symlink():
                tmp.unlink()
        except OSError:
            pass
    return True


def copy_tree_incremental(src_root: Path, dst_root: Path, uid: int, gid: int):
    if not src_root.is_dir():
        return 0, 0

    copied = 0
    skipped = 0
    ensure_dir(dst_root, uid, gid)

    for root, dirs, files in os.walk(src_root, followlinks=False):
        root_path = Path(root)
        rel = root_path.relative_to(src_root)
        target_root = dst_root / rel
        ensure_dir(target_root, uid, gid)

        # Keine Verzeichnis-Symlinks verfolgen.
        dirs[:] = [d for d in dirs if not (root_path / d).is_symlink()]

        for name in files:
            src = root_path / name
            dst = target_root / name
            if copy_file_incremental(src, dst, uid, gid):
                copied += 1
            else:
                skipped += 1

    return copied, skipped


def consistent_source_backup(source: Path, temp_dir: Path):
    consistent = temp_dir / 'source-state_5.sqlite'
    live = source / 'state_5.sqlite'

    # Bevorzugt die SQLite-Backup-API direkt auf der read-only Quelle. Das
    # liefert auch bei einer gleichzeitig laufenden lokalen Codex-Instanz einen
    # konsistenten Snapshot, ohne in den Host-Bind-Mount zu schreiben.
    try:
        src = sqlite3.connect('file:' + live.as_posix() + '?mode=ro', uri=True, timeout=10)
        dst = sqlite3.connect(str(consistent))
        try:
            src.backup(dst)
        finally:
            dst.close()
            src.close()
        return consistent
    except sqlite3.Error as exc:
        out('Direktes read-only SQLite-Backup nicht moeglich; verwende isolierte Staging-Kopie: ' + str(exc))

    # Fallback fuer read-only WAL-Datenbanken, bei denen SQLite ohne schreibbare
    # Quelle keine SHM-Datei oeffnen/anlegen kann. DB/WAL/SHM werden nur in den
    # privaten /tmp-Bereich des Helper-Containers kopiert.
    staged = temp_dir / 'source-live.sqlite'
    shutil.copy2(live, staged)
    for suffix in ('-wal', '-shm'):
        p = source / ('state_5.sqlite' + suffix)
        if p.is_file():
            shutil.copy2(p, Path(str(staged) + suffix))

    src = sqlite3.connect(str(staged), timeout=10)
    dst = sqlite3.connect(str(consistent))
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    return consistent


def cols(db, table):
    return [r[1] for r in db.execute(f'PRAGMA table_info({table})')]


def normalize_rollout(path):
    if not path:
        return path
    p = str(path).replace('\\', '/')
    while p.startswith('//?/'):
        p = p[4:]
    p = re.sub(r'/+', '/', p)
    low = p.lower()
    for marker, target in (
        ('/.codex/sessions/', '/home/vscode/.codex/sessions/'),
        ('/.codex/archived_sessions/', '/home/vscode/.codex/archived_sessions/'),
    ):
        pos = low.find(marker)
        if pos >= 0:
            return target + p[pos + len(marker):]
    return p.replace('//?//home/vscode/.codex/', '/home/vscode/.codex/')


def merge_database(source_db: Path, target_db: Path, target_root: Path, uid: int, gid: int):
    src = sqlite3.connect(str(source_db), timeout=30)
    dst = sqlite3.connect(str(target_db), timeout=30)
    backup = Path(str(target_db) + '.before-import-' + time.strftime('%Y%m%d-%H%M%S'))
    try:
        with sqlite3.connect(str(backup)) as b:
            dst.backup(b)
        safe_chown(backup, uid, gid)

        src_cols = cols(src, 'threads')
        dst_cols = cols(dst, 'threads')
        common = [c for c in src_cols if c in dst_cols]
        if not common:
            raise RuntimeError('Keine gemeinsamen Spalten in Tabelle threads gefunden.')

        quoted = ','.join('"' + c.replace('"', '""') + '"' for c in common)
        rows = src.execute(f'SELECT {quoted} FROM threads').fetchall()
        sql = 'INSERT OR IGNORE INTO threads (' + quoted + ') VALUES (' + ','.join('?' for _ in common) + ')'

        inserted = duplicates = missing = 0
        for row in rows:
            item = dict(zip(common, row))
            if 'rollout_path' in item:
                item['rollout_path'] = normalize_rollout(item['rollout_path'])
                if item['rollout_path']:
                    check_path = item['rollout_path']
                    prefix = '/home/vscode/.codex/'
                    if str(check_path).startswith(prefix):
                        check_path = str(target_root / str(check_path)[len(prefix):])
                    if not os.path.isfile(check_path):
                        missing += 1
                        continue
            if 'cwd' in item and not str(item['cwd'] or '').startswith('/workspaces'):
                item['cwd'] = '/workspaces'

            before = dst.total_changes
            dst.execute(sql, [item[c] for c in common])
            if dst.total_changes > before:
                inserted += 1
            else:
                duplicates += 1

        dst.commit()
        try:
            dst.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        except sqlite3.DatabaseError:
            pass
        integrity = dst.execute('PRAGMA integrity_check').fetchone()[0]
        return inserted, duplicates, missing, integrity, backup
    finally:
        src.close()
        dst.close()
        safe_chown(target_db, uid, gid)
        for suffix in ('-wal', '-shm'):
            safe_chown(Path(str(target_db) + suffix), uid, gid)


def load_index(path: Path):
    items = {}
    order = []
    if not path.is_file():
        return items, order
    with path.open('r', encoding='utf-8-sig', errors='replace') as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            tid = obj.get('id')
            if not tid:
                continue
            tid = str(tid)
            if tid not in items:
                order.append(tid)
            items[tid] = obj
    return items, order


def merge_index(source: Path, target: Path, uid: int, gid: int):
    items, order = load_index(target)
    src_items, src_order = load_index(source)
    added = 0
    for tid in src_order:
        if tid not in items:
            order.append(tid)
            added += 1
        items[tid] = src_items[tid]
    if not items:
        return 0

    ensure_dir(target.parent, uid, gid)
    tmp = target.with_name(target.name + '.fresh-import-tmp')
    with tmp.open('w', encoding='utf-8', newline='\n') as f:
        for tid in order:
            f.write(json.dumps(items[tid], ensure_ascii=False, separators=(',', ':')) + '\n')
    safe_chown(tmp, uid, gid)
    os.replace(tmp, target)
    safe_chown(target, uid, gid)
    return added


def source_thread_ids(db_path: Path):
    db = sqlite3.connect(str(db_path), timeout=10)
    try:
        cs = cols(db, 'threads')
        if 'id' not in cs:
            return set()
        return {str(r[0]) for r in db.execute('SELECT id FROM threads') if r[0] is not None}
    finally:
        db.close()


def target_thread_ids(db_path: Path):
    if not db_path.is_file():
        return set()
    db = sqlite3.connect(str(db_path), timeout=10)
    try:
        cs = cols(db, 'threads')
        if 'id' not in cs:
            return set()
        return {str(r[0]) for r in db.execute('SELECT id FROM threads') if r[0] is not None}
    finally:
        db.close()


def verify_existing(source: Path, target: Path, source_db: Path):
    target_db = target / 'state_5.sqlite'
    if not target_db.is_file() or target_db.stat().st_size <= 0:
        return False, 'Zieldatenbank fehlt'

    src_ids = source_thread_ids(source_db)
    dst_ids = target_thread_ids(target_db)
    missing_threads = len(src_ids - dst_ids)
    if missing_threads:
        return False, f'{missing_threads} Thread-IDs fehlen im Ziel'

    for dirname in COPY_DIRS:
        src_root = source / dirname
        if not src_root.is_dir():
            continue
        for root, dirs, files in os.walk(src_root, followlinks=False):
            root_path = Path(root)
            dirs[:] = [d for d in dirs if not (root_path / d).is_symlink()]
            for name in files:
                sp = root_path / name
                if sp.is_symlink():
                    continue
                rel = sp.relative_to(src_root)
                dp = target / dirname / rel
                if not dp.is_file() or dp.stat().st_size < sp.stat().st_size:
                    return False, f'Rollout fehlt/ist kleiner: {dirname}/{rel}'

    src_index, _ = load_index(source / 'session_index.jsonl')
    dst_index, _ = load_index(target / 'session_index.jsonl')
    missing_index = set(src_index) - set(dst_index)
    if missing_index:
        return False, f'{len(missing_index)} Session-Index-IDs fehlen im Ziel'

    return True, 'Datenbestand bereits vollständig vorhanden'


def write_marker(target: Path, fingerprint: str, uid: int, gid: int, details=None):
    marker = target / MARKER_NAME
    payload = {
        'schema': 1,
        'sourceFingerprint': fingerprint,
        'importedAtUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'helper': 'Fresh-Codex-DevContainer-Setup',
    }
    if details:
        payload['details'] = details
    tmp = marker.with_name(marker.name + '.tmp')
    with tmp.open('w', encoding='utf-8', newline='\n') as f:
        json.dump(payload, f, ensure_ascii=False, separators=(',', ':'))
        f.write('\n')
    safe_chown(tmp, uid, gid)
    os.replace(tmp, marker)
    safe_chown(marker, uid, gid)
    return marker


def read_marker(target: Path):
    p = target / MARKER_NAME
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding='utf-8-sig'))
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', default='/source')
    ap.add_argument('--target', default='/target')
    ap.add_argument('--fingerprint', required=True)
    ap.add_argument('--mode', choices=('import', 'verify'), default='import')
    args = ap.parse_args()

    source = Path(args.source)
    target = Path(args.target)
    source_db_live = source / 'state_5.sqlite'
    if not source_db_live.is_file():
        raise SystemExit('state_5.sqlite fehlt in der Importquelle.')

    uid, gid = get_vscode_ids()
    ensure_dir(target, uid, gid, 0o700)

    marker = read_marker(target)
    if marker and marker.get('sourceFingerprint') == args.fingerprint:
        out('Import-Marker passt zur aktuellen Quelle; nichts zu tun.')
        out('RESULT=ALREADY_IMPORTED')
        return 0

    with tempfile.TemporaryDirectory(prefix='codex-import-') as td:
        temp_dir = Path(td)
        source_db = consistent_source_backup(source, temp_dir)

        if args.mode == 'verify':
            ok, reason = verify_existing(source, target, source_db)
            out('Verify: ' + reason)
            if ok:
                write_marker(target, args.fingerprint, uid, gid, {'verifiedExisting': True})
                out('RESULT=VERIFIED_EXISTING')
                return 0
            out('RESULT=IMPORT_REQUIRED')
            return 10

        target_db = target / 'state_5.sqlite'
        if not target_db.is_file() or target_db.stat().st_size <= 0:
            raise RuntimeError('Zieldatenbank /target/state_5.sqlite fehlt oder ist leer.')

        total_copied = 0
        total_skipped = 0
        for dirname in COPY_DIRS:
            copied, skipped = copy_tree_incremental(source / dirname, target / dirname, uid, gid)
            total_copied += copied
            total_skipped += skipped
            out(f'{dirname}: kopiert={copied}, unveraendert={skipped}')

        inserted, duplicates, missing, integrity, backup = merge_database(source_db, target_db, target, uid, gid)
        added_index = merge_index(source / 'session_index.jsonl', target / 'session_index.jsonl', uid, gid)

        if integrity != 'ok':
            raise RuntimeError('SQLite integrity_check meldet: ' + str(integrity))
        if missing != 0:
            raise RuntimeError(f'{missing} Thread(s) konnten wegen fehlender Rollout-Datei nicht uebernommen werden.')

        marker_path = write_marker(target, args.fingerprint, uid, gid, {
            'filesCopied': total_copied,
            'filesUnchanged': total_skipped,
            'threadsInserted': inserted,
            'threadsAlreadyPresent': duplicates,
            'threadsSkippedMissingRollout': missing,
            'sessionIndexAdded': added_index,
        })

        out(f'Threads uebernommen: {inserted}')
        out(f'Bereits vorhanden: {duplicates}')
        out(f'Uebersprungen wegen fehlender Rollout-Datei: {missing}')
        out(f'Session-Index neu: {added_index}')
        out(f'Backup: {backup}')
        out(f'Integritaet: {integrity}')
        out(f'Import-Marker: {marker_path}')
        out('RESULT=IMPORTED')
        return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print('CHAT-IMPORT-HELPER-FEHLER: ' + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
