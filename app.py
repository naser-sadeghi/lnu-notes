"""
lnu-notes — a deliberately small web application for 2DV705, assignment 2.

It needs exactly three things, which is the point:
  * a MySQL database, for the notes            -> a second EC2 instance
  * an S3 bucket, for the attached images      -> object storage
  * permission to use that bucket              -> an IAM role, never access keys

Everything is configured through environment variables, so the same code runs
on your laptop and on EC2 without a single edit.
"""

import os
import uuid
from datetime import datetime

import boto3
import pymysql
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, redirect, render_template, request, url_for

app = Flask(__name__)

# ---------------------------------------------------------------- configuration
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_USER = os.environ.get("DB_USER", "lnu")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "lnunotes")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-north-1")
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "5"))

app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024

# No credentials anywhere in this file. On EC2, boto3 finds the instance role
# by itself. If you ever need to paste an access key in here, something is wrong.
s3 = boto3.client("s3", region_name=AWS_REGION)


def db():
    """One short-lived connection per request. Fine at this scale, and it means
    a broken security group shows up immediately instead of at start-up."""
    return pymysql.connect(
        host=DB_HOST, user=DB_USER, password=DB_PASS, database=DB_NAME,
        connect_timeout=4, cursorclass=pymysql.cursors.DictCursor, autocommit=True,
    )


def ensure_schema():
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


# ---------------------------------------------------------------------- routes
@app.route("/")
def index():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM notes ORDER BY id DESC LIMIT 50")
        notes = cur.fetchall()

    # A presigned URL is a temporary, signed link to one object. It is how the
    # browser can show an image from a bucket that blocks all public access.
    for note in notes:
        note["image_url"] = presign(note["image_key"]) if note["image_key"] else None

    return render_template("index.html", notes=notes, bucket=S3_BUCKET, region=AWS_REGION)


@app.route("/notes", methods=["POST"])
def create_note():
    title = (request.form.get("title") or "").strip()[:120]
    body = (request.form.get("body") or "").strip()
    if not title:
        return redirect(url_for("index"))

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
    """Reports each dependency separately, so a failure names itself.
    Use this while you are configuring security groups and IAM."""
    status = {"app": "ok", "time": datetime.utcnow().isoformat() + "Z",
              "region": AWS_REGION, "bucket": S3_BUCKET or "(unset)", "db_host": DB_HOST}

    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        status["database"] = "ok"
    except Exception as exc:                                   # noqa: BLE001
        status["database"] = f"FAIL: {type(exc).__name__}: {exc}"

    try:
        s3.head_bucket(Bucket=S3_BUCKET)
        status["s3"] = "ok"
    except (BotoCoreError, ClientError) as exc:
        status["s3"] = f"FAIL: {type(exc).__name__}: {exc}"

    ok = status["database"] == "ok" and status["s3"] == "ok"
    return status, (200 if ok else 503)


def presign(key, seconds=300):
    try:
        return s3.generate_presigned_url(
            "get_object", Params={"Bucket": S3_BUCKET, "Key": key}, ExpiresIn=seconds)
    except (BotoCoreError, ClientError):
        return None


if __name__ == "__main__":
    try:
        ensure_schema()
    except Exception as exc:                                   # noqa: BLE001
        print(f"schema check failed ({exc}) — start anyway, /healthz will tell you why")
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
