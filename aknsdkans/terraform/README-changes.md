# Changes the assignment asks you to make

Every later task is a change to this directory, not a click in the console.

| Task | What to change | Where |
|---|---|---|
| 14 · Destroy and rebuild | nothing — `terraform destroy`, then `terraform apply` | — |
| 15 · Change through code alone | `instance_type`, or `admin_cidr` | `terraform.tfvars` |
| 13 · Drift | nothing in the code — change it in the console, then `terraform plan` | — |
| 16 · Password out of the state file | the four steps below | `main.tf`, both `.tftpl` files |

## Task 16 — taking the password out of the state file

**See the problem first.** Terraform generates the database password
(`random_password.db` in `main.tf`) and its result is stored in the state file
in clear text:

```bash
grep '"result"' terraform.tfstate
```

You will see the password itself. Marking things `sensitive` hides values from
the screen, never from this file. The fix is to stop Terraform ever handling
the value: keep it in SSM Parameter Store, and let each instance read it at boot.

### 1 · Store the password outside Terraform

```bash
aws ssm put-parameter --name /2dv705/db_password --type SecureString \
  --value "$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
```

`SecureString` is encrypted at rest with a key AWS manages. If the parameter
already exists, add `--overwrite`.

### 2 · Give both instances permission to read it

Copy `task16-ssm.tf.example` to `task16-ssm.tf`. It adds a read policy to the
web role, and a new role and instance profile for the database — which had no
role before and needs one now:

```bash
cp task16-ssm.tf.example task16-ssm.tf
```

Then in `main.tf`, in `resource "aws_instance" "db"`, add one line:

```hcl
  iam_instance_profile = aws_iam_instance_profile.db.name
```

### 3 · Stop handing Terraform the value

In `main.tf`:

- delete the whole `resource "random_password" "db" { … }` block;
- in the **db** instance, change the template variables to `{ region = var.region }`;
- in the **web** instance, delete the line `db_pass = random_password.db.result`.

In `cloud-config-web.yaml.tftpl`, delete the line `DB_PASS=${db_pass}`, and
add this step directly after the `pip install` line:

```yaml
  - |
    /opt/lnu-notes/.venv/bin/python - <<'PY'
    import time, boto3
    for attempt in range(10):
        try:
            pw = boto3.client("ssm", region_name="${region}").get_parameter(
                Name="/2dv705/db_password", WithDecryption=True)["Parameter"]["Value"]
            break
        except Exception as exc:
            print("waiting for credentials:", exc); time.sleep(6)
    else:
        raise SystemExit("could not read /2dv705/db_password")
    with open("/etc/lnu-notes.env", "a") as f:
        f.write(f"DB_PASS={pw}\n")
    PY
```

In `cloud-config-db.yaml.tftpl`, add `python3-boto3` to `packages`, delete the
whole `/root/init.sql` entry from `write_files`, and replace the `runcmd` with:

```yaml
runcmd:
  - systemctl restart mariadb
  - |
    python3 - <<'PY'
    import subprocess, time, boto3
    for attempt in range(10):
        try:
            pw = boto3.client("ssm", region_name="${region}").get_parameter(
                Name="/2dv705/db_password", WithDecryption=True)["Parameter"]["Value"]
            break
        except Exception as exc:
            print("waiting for credentials:", exc); time.sleep(6)
    else:
        raise SystemExit("could not read /2dv705/db_password")
    sql = ("CREATE DATABASE IF NOT EXISTS lnunotes;"
           f"CREATE USER IF NOT EXISTS 'lnu'@'10.0.%' IDENTIFIED BY '{pw}';"
           "GRANT ALL PRIVILEGES ON lnunotes.* TO 'lnu'@'10.0.%';"
           "FLUSH PRIVILEGES;")
    subprocess.run(["mysql"], input=sql.encode(), check=True)
    PY
```

Why Python and not the `aws` command: the AWS CLI is not installed on the
Ubuntu image. boto3 is — in the app's virtual environment on the web instance,
and as `python3-boto3` on the database. The retry loop is there because a
freshly attached role can take a few seconds to reach a new instance.

### 4 · Apply, and check

```bash
terraform plan     # expect: both instances "must be replaced", random_password destroyed
terraform apply
grep '"result"' terraform.tfstate          # expect: nothing
curl -s "$(terraform output -raw health_url)"   # after 4–5 minutes: database ok
```

Both instances are **replaced**, not updated: cloud-init only runs on first
boot, so new user data needs a new machine (`user_data_replace_on_change` in
`main.tf` makes that happen).

### What you have, and have not, fixed

The secret is no longer in the file that sits next to your code. It is not
secret from the instances — anything running on them can read it — nor from
anyone who can assume either role. Say both halves in your report: naming what a
control does *not* cover is most of what an assessment is.
