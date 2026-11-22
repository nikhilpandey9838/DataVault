
import argparse
import gzip
import os
import subprocess
import sys
import time
import json
import tempfile
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
RESTORE_DIR = PROJECT_DIR / "restores"

S3_BUCKET = os.getenv("S3_BUCKET", "datavault-backups-2500")
S3_PREFIX = os.getenv("S3_PREFIX", "backups")


def run_command(command, description):
    print(f"[INFO] {description}")

    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or description + " failed")

    return result.stdout


def validate_backup_filename(filename):
    if (
        not filename
        or Path(filename).name != filename
        or "/" in filename
        or "\\" in filename
        or not filename.endswith(".sql.gz")
    ):
        raise ValueError("Invalid backup filename")


def validate_database_name(database):
    import re

    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]{0,62}", database):
        raise ValueError("Invalid recovery database name")


def validate_s3_config(bucket, prefix):
    import re

    bucket_pattern = r"^(?!\d+\.\d+\.\d+\.\d+$)[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"

    if not re.fullmatch(bucket_pattern, bucket):
        raise ValueError("Invalid S3 bucket name")

    if (
        not prefix
        or prefix.startswith("/")
        or prefix.endswith("/")
        or "//" in prefix
        or "\\" in prefix
        or any(part in (".", "..") for part in prefix.split("/"))
    ):
        raise ValueError("Invalid S3 prefix")






def download_backup(filename):
    validate_backup_filename(filename)

    RESTORE_DIR.mkdir(parents=True, exist_ok=True)
    RESTORE_DIR.chmod(0o700)
    local_file = RESTORE_DIR / filename

    # Reuse an existing regular local backup without overwriting it.
    if local_file.is_symlink():
        raise RuntimeError("Symbolic links are not allowed for backup files")

    if local_file.exists():
        if not local_file.is_file():
            raise RuntimeError("Local backup path is not a regular file")

        local_file.chmod(0o600)

        print(f"[INFO] Reusing existing local backup: {local_file}")
        return local_file

    s3_uri = f"s3://{S3_BUCKET}/{S3_PREFIX}/{filename}"
    temp_file = None

    try:
        with tempfile.NamedTemporaryFile(
            dir=RESTORE_DIR,
            prefix=".datavault_download_",
            suffix=".tmp",
            delete=False
        ) as temp:
            temp_file = Path(temp.name)

        run_command(
            [
                "aws", "s3", "cp",
                s3_uri,
                str(temp_file),
                "--only-show-errors"
            ],
            "Downloading backup from AWS S3"
        )


        if not temp_file.is_file() or temp_file.stat().st_size == 0:
            raise RuntimeError("Downloaded backup is missing or empty")

        # Enforce private permissions before atomic publishing.
        temp_file.chmod(0o600)

        try:
            os.link(temp_file, local_file)
        except FileExistsError:
            raise FileExistsError(
                f"Backup already exists locally: {local_file}"
            )

        temp_file.unlink()
        temp_file = None

        return local_file

    finally:
        if temp_file and temp_file.exists():
            temp_file.unlink()







def verify_backup(backup_file):
    print("[INFO] Verifying backup integrity")

    if not backup_file.is_file() or backup_file.stat().st_size == 0:
        raise RuntimeError("Backup file is missing or empty")


    # Validate the complete gzip stream, including trailing data.
    run_command(
        ["gzip", "-t", str(backup_file)],
        "Checking complete gzip integrity"
    )

    with gzip.open(backup_file, "rt", encoding="utf-8") as backup:
        header = backup.read(4096)

    if "PostgreSQL database dump" not in header:
        raise RuntimeError("Invalid PostgreSQL dump format")

    print("[SUCCESS] Backup integrity verified")



def cleanup_recovery_database(container, database, user):
    print(f"[INFO] Cleaning up failed recovery database: {database}")

    result = subprocess.run(
        [
            "docker", "exec", container,
            "dropdb", "--if-exists",
            "-U", user, database
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    if result.returncode != 0:
        print(
            f"[WARNING] Recovery database cleanup failed: "
            f"{result.stderr.strip()}",
            file=sys.stderr
        )
        return False

    print("[SUCCESS] Failed recovery database cleaned up")
    return True




def restore_database(backup_file, container, database, user):
    run_command(
        [
            "docker", "exec", container,
            "pg_isready", "-U", user, "-d", "postgres"
        ],
        "Checking PostgreSQL availability"
    )

    run_command(
        ["docker", "exec", container, "createdb", "-U", user, database],
        f"Creating recovery database: {database}"
    )

    try:
        print("[INFO] Restoring PostgreSQL database")

        decompressor = subprocess.Popen(
            ["gzip", "-dc", str(backup_file)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            result = subprocess.run(
                [
                    "docker", "exec", "-i", container,
                    "psql", "-X", "-v", "ON_ERROR_STOP=1",
                    "-U", user, "-d", database
                ],
                stdin=decompressor.stdout,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True
            )
        finally:
            decompressor.stdout.close()

        gzip_error = decompressor.stderr.read().decode(errors="replace")
        gzip_returncode = decompressor.wait()

        if result.returncode != 0:
            raise RuntimeError(
                result.stderr.strip() or "Database restore failed"
            )

        if gzip_returncode != 0:
            raise RuntimeError(gzip_error or "Backup decompression failed")

        print("[SUCCESS] Database restore completed")

    except Exception:
        cleanup_recovery_database(container, database, user)
        raise





def validate_restore(container, source_database, recovery_database, user):
    query = """
        SELECT COALESCE(
            json_agg(
                json_build_array(id, name, email)
                ORDER BY id
            ),
            '[]'::json
        )::text
        FROM customers;
    """

    def fetch_records(database, description):
        output = run_command(
            [
                "docker", "exec", container,
                "psql", "-X", "-A", "-t",
                "-U", user, "-d", database,
                "-c", query
            ],
            description
        )

        return json.loads(output.strip())

    original_records = fetch_records(
        source_database,
        "Reading original customer records"
    )

    recovered_records = fetch_records(
        recovery_database,
        "Reading recovered customer records"
    )

    if original_records != recovered_records:
        raise RuntimeError(
            "Data integrity validation failed: "
            "Original and recovered records do not match"
        )

    count = len(recovered_records)

    if count == 0:
        raise RuntimeError("Recovery validation failed: no customer records found")

    print("[SUCCESS] Original and recovered records match")
    print("[SUCCESS] DATA INTEGRITY: VERIFIED")
    print(f"[SUCCESS] Recovered customer records: {count}")

    return count


def main():
    parser = argparse.ArgumentParser(description="DataVault Automated Restore Engine")

    parser.add_argument("--backup", required=True, help="S3 backup filename")
    parser.add_argument("--database", required=True, help="New recovery database name")
    parser.add_argument("--container", default="datavault-postgres")
    parser.add_argument("--user", default="datavault")
    parser.add_argument("--source-database", default="datavault_db", help="Original database used for integrity comparison")


    args = parser.parse_args()


    try:
        validate_backup_filename(args.backup)
        validate_database_name(args.database)
        validate_database_name(args.source_database)
        validate_s3_config(S3_BUCKET, S3_PREFIX)
    except ValueError as error:
        parser.error(str(error))


    start_time = time.perf_counter()
    recovery_database_created = False


    try:
        backup_file = download_backup(args.backup)
        verify_backup(backup_file)

        restore_database(
            backup_file,
            args.container,
            args.database,
            args.user
        )

        recovery_database_created = True

        recovered_count = validate_restore(
            args.container,
            args.source_database,
            args.database,
            args.user
        )

        duration = time.perf_counter() - start_time

        print("\n========== DATAVAULT RECOVERY REPORT ==========")
        print(f"Backup: {args.backup}")
        print(f"Recovery database: {args.database}")
        print(f"Recovered customer records: {recovered_count}")
        print(f"Total recovery time: {duration:.3f} seconds")
        print("Recovery status: SUCCESS")
        print("Data integrity: VERIFIED")
        print("===============================================\n")

    except Exception as error:
        print(f"\n[ERROR] Recovery failed: {error}", file=sys.stderr)

        if recovery_database_created:
            cleanup_recovery_database(
                args.container,
                args.database,
                args.user
            )

        sys.exit(1)





if __name__ == "__main__":
    main()
