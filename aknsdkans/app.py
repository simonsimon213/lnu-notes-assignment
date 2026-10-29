"""
lnu-notes: a small notes application for 2DV705, assignment 2.

It uses three things:
  * a MySQL database for the notes
  * an S3 bucket for the attached images
  * permission to use that bucket

All settings come from environment variables, so the same code runs on your
own computer and on EC2.
"""

import os
import uuid
from datetime import datetime

import boto3
import pymysql
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, redirect, render_template, request, url_for

app = Flask(__name__)

# ---------------------------------------------------------------- configuration
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_USER = os.environ.get("DB_USER", "lnu")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "lnunotes")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-north-1")
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "5"))

app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024

# There are no credentials in this file. boto3 finds them in the environment.
s3 = boto3.client("s3", region_name=AWS_REGION,
                  config=Config(s3={"addressing_style": "virtual"}))


def db():
    """Open a new database connection."""
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASS, database=DB_NAME,
        connect_timeout=4, cursorclass=pymysql.cursors.DictCursor, autocommit=True,
    )


def ensure_schema():
    """Create the notes table if it does not exist."""
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS notes (
                   id         INT AUTO_INCREMENT PRIMARY KEY,
                   title      VARCHAR(120) NOT NULL,
                   body       TEXT,
                   image_key  VARCHAR(255),
                   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
               )"""
        )


_schema_ready = False


def schema_once():
    """Make sure the table exists before the first request that uses it."""
    global _schema_ready
    if not _schema_ready:
        ensure_schema()
        _schema_ready = True


# ---------------------------------------------------------------------- routes
@app.route("/")
def index():
    schema_once()
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM notes ORDER BY id DESC LIMIT 50")
        notes = cur.fetchall()

    for note in notes:
        note["image_url"] = presign(note["image_key"]) if note["image_key"] else None

    return render_template("index.html", notes=notes, bucket=S3_BUCKET, region=AWS_REGION)


@app.route("/notes", methods=["POST"])
def create_note():
    title = (request.form.get("title") or "").strip()[:120]
    body = (request.form.get("body") or "").strip()
    if not title:
        return redirect(url_for("index"))

    schema_once()
    image_key = None
    upload = request.files.get("image")
    if upload and upload.filename:
        ext = os.path.splitext(upload.filename)[1].lower()[:10]
        image_key = f"uploads/{uuid.uuid4().hex}{ext}"
        s3.upload_fileobj(
            upload, S3_BUCKET, image_key,
            ExtraArgs={"ContentType": upload.mimetype or "application/octet-stream",
                       "ServerSideEncryption": "AES256"},
        )

    with db() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO notes (title, body, image_key) VALUES (%s, %s, %s)",
                    (title, body, image_key))

    return redirect(url_for("index"))


@app.route("/healthz")
def healthz():
    """Report the database and the bucket separately, so a failure names itself."""
    status = {"app": "ok", "time": datetime.utcnow().isoformat() + "Z",
              "region": AWS_REGION, "bucket": S3_BUCKET or "(unset)", "db_host": DB_HOST}

    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        status["database"] = "ok"
    except Exception as exc:
        status["database"] = f"FAIL: {type(exc).__name__}: {exc}"

    try:
        s3.head_bucket(Bucket=S3_BUCKET)
        status["s3"] = "ok"
    except (BotoCoreError, ClientError) as exc:
        status["s3"] = f"FAIL: {type(exc).__name__}: {exc}"

    ok = status["database"] == "ok" and status["s3"] == "ok"
    return status, (200 if ok else 503)


def presign(key, seconds=300):
    """Return a temporary link to one image, or None if it cannot be made."""
    try:
        return s3.generate_presigned_url(
            "get_object", Params={"Bucket": S3_BUCKET, "Key": key}, ExpiresIn=seconds)
    except (BotoCoreError, ClientError):
        return None


if __name__ == "__main__":
    try:
        ensure_schema()
    except Exception as exc:
        print(f"schema check failed ({exc}) — start anyway, /healthz will tell you why")
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
