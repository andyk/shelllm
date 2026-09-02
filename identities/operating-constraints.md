# Operating constraints

Runtime identity goals live in `.identities/<name>/goals.md` and are
gitignored. This file is a reviewable record of constraints we want to
preserve across rebuilds. It does not update runtime identity files.

## GitHub operations

On the first GitHub failure or unexpected result, including an
authentication, permission, wrong account, or 403 error, stop. Ask one
question in the originating thread. Do not make another GitHub request
until the user replies. Do not retry, change accounts, use a fork to
bypass the failure, or use another workaround.
