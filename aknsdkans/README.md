# lnu-notes

A deliberately small web application for **2DV705, assignment 2**. It exists to
give the AWS services you are asked to configure something real to do.

You report on it in the five-page Word template handed out with the assignment
(`2DV705_A2_Lastname.docx`) — every answer has a box waiting for it, and the last
page is where failures go.

Notes live in **MySQL**. Attached images live in **S3**. The application reaches
the bucket through an **IAM role**, and shows images through **presigned URLs**
— so it works perfectly with public access to the bucket fully blocked, which is
the point of task 11.

```
        browser  ──80──▶  web instance (EC2)  ──3306──▶  db instance (EC2, MySQL)
                               │
                               └── HTTPS, signed by the instance role ──▶  S3 bucket
```

---

## 1 · Run it on your own machine first

Twenty minutes, and it makes every later failure legible.

**Create an environment and install the four dependencies.**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**Start a MySQL to talk to.** If you have Docker or Podman:

```bash
docker run -d --name mysql -p 3306:3306 \
  -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=lnunotes \
  -e MARIADB_USER=lnu -e MARIADB_PASSWORD=lnu mariadb:11
```

No container runtime? Skip it — start the app anyway and read `/healthz`, which
will report the database as unreachable. That is the output you will be
diagnosing on AWS, so it is worth seeing now.

**Configure and run.** Every setting comes from the environment, so the same
code runs here and on EC2 with no edit.

```bash
cp .env.example .env          # the defaults already match the container above
set -a; . ./.env; set +a      # export everything in the file
python app.py                 # http://localhost:8000
```

The four database values in `.env.example` line up with the four `-e` flags in the
`docker run` command — same user, same password, same database name. If you change
one, change both. Note that `DB_PASS` is `MARIADB_PASSWORD`, not
`MARIADB_ROOT_PASSWORD`; the application does not connect as root.

**Read the health endpoint.** This is your debugging tool for the whole
assignment:

```bash
curl -s http://localhost:8000/healthz | python3 -m json.tool
```

```json
{ "app": "ok", "database": "ok", "s3": "FAIL: ParamValidationError ..." }
```

`database: ok` is what you are checking for. The `s3` line fails because
`S3_BUCKET` is empty — there is no bucket yet, and that is correct at this stage.

| If `database` says | What is wrong |
|---|---|
| `timed out` | `DB_HOST` is not reachable — on your laptop it must be `127.0.0.1`, not an EC2 private address |
| `Access denied for user 'lnu'` | `DB_PASS` does not match `MARIADB_PASSWORD`. Using `MARIADB_ROOT_PASSWORD` here is the usual mistake |
| `Unknown database '...'` | `DB_NAME` does not match `MARIADB_DATABASE` |
| `Connection refused` | the container is not running: `docker ps`, then `docker logs mysql` |

---

## 2 · If your account is on the AWS Free plan

A new AWS account gets **$100 in credits for up to six months**, and the whole of
this project fits inside that with room to spare — two `t3.micro` instances run
for a day or two, two small disks, and a few megabytes in S3. Everything else it
uses (VPC, subnets, gateways, security groups, IAM, standard SSM parameters) is
free in every account.

Two things will end the free plan, and neither warns you clearly:

- **Enabling IAM Identity Center.** On a standalone account the recommended path
  creates an AWS organization, and AWS's own documentation says that *"creating
  an AWS organization automatically upgrades your account to a paid plan with
  pay-as-you-go pricing. Your free tier credits expire immediately."* Decline it
  and use a plain IAM user.
- **Creating or joining an AWS Organization** for any other reason.

Two practical consequences for this repository:

```bash
terraform destroy      # at the end of every working session, not just at the end
```

and when you set the budget alarm, **untick "Credits"** under *Budget scope →
Advanced options*. With credits counted, your bill reads `$0.00` until they are
gone and the alarm never fires.

---

## 3 · Point the deployment at your own copy

The instances install the application by cloning it, so the clone URL has to be
your repository. Three files carry it:

| File | Line |
|---|---|
| `terraform/variables.tf` | the `repo_url` default |
| `deploy/web-userdata.sh` | `REPO=` |
| `deploy/cloud-config-web.yaml` | the `git clone` line |

With Terraform you do not have to edit `variables.tf` — set it in
`terraform.tfvars` instead, which is where your own values belong anyway.

```bash
git clone https://github.com/<your-name>/lnu-notes.git
cd lnu-notes
grep -rn CHANGE-ME .        # the two places to edit by hand
```

---

## 4 · Deploy it — from code

This is the path the assignment takes. You do not build the environment in the
console and then describe it afterwards; you describe it and let the description
build it.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars    # fill in two values
terraform init                                  # download the AWS provider
terraform plan                                  # what WOULD change — nothing happens yet
terraform apply                                 # make reality match the file
```

`apply` prints the URL to open. Three or four minutes later — cloud-init has to
install Python and clone this repository — the application answers.

```bash
terraform output
curl -s "$(terraform output -raw health_url)" | python3 -m json.tool
```

### Read it before you run it

| File | What is in it |
|---|---|
| `main.tf` | the whole environment: VPC, subnet, gateway, route table, both security groups, the bucket and its three protections, the role, and the two instances |
| `variables.tf` | the things you are meant to change |
| `outputs.tf` | the URLs `apply` prints when it finishes |
| `cloud-config-*.yaml.tftpl` | the user data, as templates Terraform fills in |
| `README-changes.md` | where each of the later tasks lands in this directory |

The line worth finding is in the database security group:

```hcl
security_groups = [aws_security_group.web.id]
```

You never type an identifier. The reference both sets the value and tells
Terraform that the web group has to exist first — which is why the order of the
file does not matter, and why you cannot paste identifiers out of the console
without breaking the whole idea.

### The real test is destroy and rebuild

```bash
terraform destroy
terraform apply
```

If the application comes back without you touching the console, the automation
is real. If it does not, something exists that nobody wrote down.

### Drift: when reality and the file disagree

Change something in the console — remove a security-group rule, turn off a
bucket setting — and then:

```bash
terraform plan
```

The plan now offers to undo your change, because the file is the record of what
should be true and reality no longer matches it. That is not the tool
misbehaving; it is the tool reporting a disagreement. The cure is to make the
change in the file, not in the console.

---

## 4b · The by-hand files, for comparison

`deploy/` holds the same work done without Terraform. You will use the
cloud-config files (Terraform renders the `.tftpl` versions of them), and you
will read the shell ones.

| File | Use |
|---|---|
| `cloud-config-web.yaml`, `cloud-config-db.yaml` | user data — **declarative** |
| `web-userdata.sh`, `db-userdata.sh` | the same two jobs written **imperatively**, as shell |
| `lnu-notes.service` | the systemd unit the user data installs |
| `iam-policy-s3.json` | least-privilege policy for the web instance's role |
| `iam-policy-ssm.json` | for the task that takes the password out of the state file |

**The placeholders stay placeholders.** `CHANGE-ME` in these files is deliberate:
they are templates committed to git, and the copy with your real password in it is
not. Render a filled copy at deploy time rather than editing the tracked file —

```bash
sed "s/CHANGE-ME/$DBPASS/" deploy/cloud-config-db.yaml > deploy/db.local.yaml
aws ec2 run-instances ... --user-data file://deploy/db.local.yaml
```

`*.local.yaml`, `*.local.sh`, `policy.json` and `trust.json` are all git-ignored for
this reason. If you did edit a template in place, check `git diff` before you commit.

Both forms are here on purpose. One says *what the machine should look like*,
the other says *how to get there*. Run either twice and only the declarative one
is safe — which is what idempotent means.

---

## 5 · Configuration

| Variable | Meaning |
|---|---|
| `DB_HOST` | **private** IPv4 address of the database instance |
| `DB_USER`, `DB_PASS`, `DB_NAME` | the MySQL account the app uses |
| `S3_BUCKET` | your bucket name — globally unique across all of AWS |
| `AWS_REGION` | the region you chose, e.g. `eu-north-1` |

There is no variable for AWS credentials, and there must never be one. On EC2,
boto3 finds the instance role by itself.

---

## 6 · `/healthz` names what is broken

```bash
curl -s http://<web-public-ip>/healthz | python3 -m json.tool
```

| It says | What is actually wrong |
|---|---|
| `database: FAIL … timed out` | **packets are being dropped.** The 3306 rule on the database group does not name the web group as its source, `DB_HOST` points at nothing, or the two instances are in different VPCs |
| `database: FAIL … Connection refused` | the packets *arrive* — so the security group is right and MySQL is not listening. Check `systemctl status mariadb` and `cloud-init status` on the database instance |
| `database: FAIL … Access denied` | the password in `/etc/lnu-notes.env` differs from the one the database was created with |
| `s3: FAIL … NoCredentialsError` | **no role at all.** boto3 found nothing to sign with — the instance profile is not attached, or it was attached after the service started |
| `s3: FAIL … AccessDenied` | a role **is** attached, but its policy does not allow this action on this bucket |
| `s3: FAIL … NoSuchBucket` | typo in `S3_BUCKET`, the placeholder was never replaced, or the bucket is in another region |

---

## 7 · Three things here are deliberately imperfect

Find them, and discuss them in your report:

1. **The database password reaches the instance through user data**, which any
   process on that instance can read back from the metadata service.
2. **With Terraform, the generated database password is stored in
   `terraform.tfstate` in clear text** — `grep '"result"' terraform.tfstate` shows
   it. This is the one the assignment asks you to fix (task 16, see
   `terraform/README-changes.md`), and it is why the state file is git-ignored.
   On a team, state belongs in access-controlled remote storage, never beside the code.
3. **The web instance's role allows `s3:DeleteObject`.** The application never
   deletes anything. Narrowing a policy to what the code actually calls is the
   work that least privilege really is.

None of the three is dangerous behind a correct security group. All three are the
kind of thing that becomes dangerous the day something else changes.

---

## Licence

Coursework material for 2DV705 at Linnaeus University. Use it freely.
