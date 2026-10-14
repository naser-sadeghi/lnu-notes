# Changes the assignment asks you to make

Four of the later tasks are changes to this directory rather than clicks in a
console. This file says where each one lands. Do not edit `main.tf` for the
first three — the values are already variables.

| Task | What to change | Where |
|---|---|---|
| Make a change through code alone | `instance_type`, or the admin address | `terraform.tfvars` |
| Keep the environment reproducible | nothing — just `destroy` then `apply` | — |
| Take the password out of the state file | replace `var.db_password` with a lookup | `main.tf`, `variables.tf` |
| Show drift and let the code win | nothing in the code — change it in the console, then `plan` | — |

## Taking the password out of the state file

The password reaches the state file because Terraform handles its value. The fix
is to stop handing it to Terraform: put it somewhere the *instance* can read at
boot, and give Terraform only the name.

**1 · Store it, outside Terraform.** `SecureString` encrypts it at rest with a
key AWS manages for you.

```bash
aws ssm put-parameter --name /2dv705/db_password \
  --value "pick-something-long" --type SecureString
```

**2 · Let the instance read that one parameter.** `deploy/iam-policy-ssm.json`
is the policy: one action, one parameter, and `kms:Decrypt` narrowed by a
condition to requests that arrive through SSM. Add it to the role in `main.tf`
beside the S3 policy.

**3 · Fetch it at boot instead of writing it in.** In
`cloud-config-web.yaml.tftpl`, drop `DB_PASS` from the written file and add a
`runcmd` line before the service starts:

```yaml
  - |
    echo "DB_PASS=$(aws ssm get-parameter --name /2dv705/db_password \
      --with-decryption --query Parameter.Value --output text)" \
      >> /etc/lnu-notes.env
```

**4 · Prove it worked.**

```bash
terraform apply
grep -c db_password terraform.tfstate     # expect 0
curl -s "$(terraform output -raw health_url)"
```

### What you have, and have not, fixed

You have taken the secret out of the file that sits next to the code. You have
not made it secret from the instance — anything running there can still read it,
and so can anyone who can assume that role. Say both halves in your report:
naming what a control does *not* cover is most of what an assessment is.
