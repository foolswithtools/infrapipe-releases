#!/bin/sh
# scrub-check.sh DIR
#
# Pre-publication leak check for the public documentation tree.
# POSIX sh; needs only grep and find. Prints file:line:rule for every hit
# (never the matched text, so a leaked secret is not echoed into logs).
# Exit status: 0 clean, 1 at least one hit, 2 usage error.

# ---------------------------------------------------------------------------
# ALLOWLIST (edit here; every entry is an extended regex that must match the
# WHOLE text the rule matched; it is anchored for you)
# ---------------------------------------------------------------------------
# The only AWS account id allowed (the documentation placeholder).
ALLOW_ACCOUNT_ID='123456789012'
# Private / link-local addresses that appear in the docs on purpose.
#   169.254.169.254 = the cloud instance-metadata (IMDS) address.
ALLOW_IPS='169\.254\.169\.254'
# The only Anthropic key text allowed.
ALLOW_SK_ANT='sk-ant-your-key-here'
# Emails allowed: anything @example.com/.org/.net, plus the placeholder GCP
# service accounts and the git SSH user used in clone examples.
ALLOW_EMAILS='[A-Za-z0-9._%+-]+@example\.(com|org|net)|deploy@(my|dev)-project\.iam\.gserviceaccount\.com|git@github\.com'
# Docker image path that legitimately contains the private repo's owner/name.
ALLOW_GHCR='ghcr\.io/foolswithtools/infrapipe([^-A-Za-z0-9_]|$)'
# ---------------------------------------------------------------------------

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
	echo "usage: $0 DIRECTORY" >&2
	exit 2
fi
DIR=$1

# report RULE : reads "file:line:match" lines on stdin, prints "file:line: RULE"
report() {
	rule=$1
	while IFS= read -r l; do
		rest=${l#*:}
		ln=${rest%%:*}
		file=${l%%":$ln:"*}
		printf '%s:%s: %s\n' "$file" "$ln" "$rule"
	done
}

# grep every regular file under DIR, emit file:line:match (match only, -o)
g() { # g [grep options...] -- pattern
	find "$DIR" -type f -exec grep -HnoIE "$@" {} +
}

# The pipelines below run in subshells; track failure through a temp file.
TMP=${TMPDIR:-/tmp}/scrub-check.$$
: >"$TMP"
trap 'rm -f "$TMP"' EXIT INT TERM
run() { # run RULE : stdin lines -> report; remember if anything printed
	out=$(report "$1")
	if [ -n "$out" ]; then
		printf '%s\n' "$out"
		echo hit >>"$TMP"
	fi
}

# 1. 12-digit AWS account ids other than the placeholder
g '(^|[^0-9])[0-9]{12}([^0-9]|$)' |
	grep -vE ":[0-9]+:[^0-9]?${ALLOW_ACCOUNT_ID}[^0-9]?\$" | run 'aws-account-id'

# 2. extra forbidden words (organisation / personal handles; case-insensitive, fixed
#    strings), one per line in the file named by SCRUB_BLOCKLIST. The list is kept on the
#    private side so this public copy does not itself publish the words; the promote
#    workflow always supplies it. When SCRUB_BLOCKLIST is set but missing or empty the
#    check refuses to run, so coverage cannot silently drop. The matched word is never
#    printed.
if [ -n "${SCRUB_BLOCKLIST:-}" ]; then
	if [ ! -s "$SCRUB_BLOCKLIST" ]; then
		echo "scrub-check: SCRUB_BLOCKLIST is set but missing or empty" >&2
		exit 2
	fi
	while IFS= read -r w; do
		case "$w" in '' | '#'*) continue ;; esac
		find "$DIR" -type f -exec grep -HniIoF -e "$w" {} + | run "forbidden-word"
	done <"$SCRUB_BLOCKLIST"
fi

# 5. links into the private source repo (infrapipe-releases is allowed)
g '[A-Za-z0-9./_-]*foolswithtools/infrapipe([^-A-Za-z0-9_]|$)' |
	grep -vE ":[0-9]+:[A-Za-z0-9./_-]*${ALLOW_GHCR}" | run 'private-repo-reference'

# 6-7. issue and pull-request links
g '/issues/' | run 'issue-link'
g '/pull/' | run 'pull-link'

# 8. private / link-local IPs outside the allowlist
g '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)' |
	grep -vE ":[0-9]+:[^0-9.]?(${ALLOW_IPS})[^0-9]?\$" | run 'private-ip'

# 9. Anthropic keys other than the placeholder
g 'sk-ant-[A-Za-z0-9_-]*' | grep -vE ":[0-9]+:(${ALLOW_SK_ANT})\$" | run 'anthropic-key'

# 10. AWS access key ids
g '(AKIA|ASIA)[0-9A-Z]{16}' | run 'aws-access-key-id'

# 11. private key blocks
g 'BEGIN [A-Z ]*PRIVATE KEY' | run 'private-key'

# 12. email addresses outside the allowlist
g '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' |
	grep -vE ":[0-9]+:(${ALLOW_EMAILS})\$" | run 'email'

if [ -s "$TMP" ]; then
	echo "scrub-check: FAILED" >&2
	exit 1
fi
echo "scrub-check: clean ($DIR)"
exit 0
