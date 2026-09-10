#!/usr/bin/env bash
# Skill integrity + privacy check. Public Telegram/gateway ranges and localhost are legal.
cd "$(dirname "$0")" || exit 1
rc=0
echo "== broken links =="
while read -r r; do [ -f "$r" ] || { echo "  BROKEN: $r"; rc=1; }; done \
  < <(grep -rhoE "reference/[a-z0-9-]+\.md" SKILL.md reference/*.md 2>/dev/null | sort -u)
echo "== orphan reference files =="
for f in reference/*.md; do grep -rqF "$f" SKILL.md reference/*.md 2>/dev/null || { echo "  orphan: $f"; rc=1; }; done
echo "== private data leak =="
leaks=$(grep -rhnE "/Users/[a-z]+/|/home/[a-z]+/|\b7[0-9]{9,10}\b|sshpass|BEGIN (RSA|OPENSSH) PRIVATE KEY|[0-9]+:AA[A-Za-z0-9_-]{30,}" --include="*.md" . 2>/dev/null)
[ -n "$leaks" ] && { echo "$leaks" | sed 's/^/  /'; rc=1; }
ips=$(grep -rhoE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" --include="*.md" . 2>/dev/null \
  | grep -vE "^127\.|^0\.0\.0\.0|^203\.0\.113\.|^91\.108\.|^149\.154\.|^10\.|^192\.168\." | sort -u)
[ -n "$ips" ] && { echo "  suspicious IPs:"; echo "$ips" | sed 's/^/    /'; rc=1; }
[ $rc -eq 0 ] && echo "OK" || echo "issues found"
exit $rc
