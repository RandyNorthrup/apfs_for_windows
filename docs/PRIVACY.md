# Repository Privacy

This public repository and every release artifact must be free of private
workstation, account, network, credential, and test-device data.

## Prohibited Data

- local user-profile and home-directory paths;
- personal email addresses in files or Git commit metadata;
- private IPv4 addresses, internal hostnames, and VM connection details;
- passwords, tokens, private keys, certificates containing private material, and
  credential files;
- device serials or hashes derived from device serials;
- machine-specific disk numbers, partition targets, and hardware inventories;
- generated logs, crash dumps, raw test evidence, build trees, and artifacts.

Public project ownership, copyright attribution, GitHub repository URLs, generic
Windows installation paths, and placeholders are allowed.

## Verification

Run:

```powershell
.\scripts\verify-repository-privacy.ps1
```

The gate scans tracked project text, documentation, sensitive filenames, and Git
author/committer email metadata. Release automation runs the same scanner against
the staged package and checks project executables for embedded build-machine paths
and private literals before publication.

## Evidence Handling

Generated evidence belongs under ignored `artifacts/` or another private evidence
store. Public documentation may retain capability summaries but not host, user,
network, device, path, or credential details.

## Incident Response

When private data reaches public history:

1. stop release publication;
2. rotate any exposed secret immediately;
3. remove the data from the current tree;
4. rewrite reachable Git history;
5. force-update the protected branch under a controlled temporary exception;
6. restore branch protection and rerun all checks;
7. request GitHub cache removal when the exposed data was a secret.
