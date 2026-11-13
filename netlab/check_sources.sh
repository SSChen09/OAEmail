#!/bin/bash
echo "### OS: $(cat /etc/redhat-release 2>/dev/null)"
echo "### repo files:"
ls -1 /etc/yum.repos.d/*.repo 2>/dev/null || echo "(none)"
for f in /etc/yum.repos.d/*.repo; do
  [ -e "$f" ] || continue
  echo "--- $f"
  grep -E '^\[|^name|^baseurl|^mirrorlist|^enabled|^gpgcheck|^gpgkey|^metal|^priority' "$f" | sed 's/^/    /'
done
echo "### yum repolist (timeout 20s):"
timeout 20 yum -q repolist 2>&1 | head -20
echo "### pip config files:"
for f in /etc/pip.conf /etc/pip/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf; do
  if [ -f "$f" ]; then echo "--- $f"; sed 's/^/    /' "$f"; fi
done
echo "### pip executables:"
command -v pip3 pip 2>/dev/null
pip3 --version 2>/dev/null || pip --version 2>/dev/null || echo "(no pip)"
echo "### pip config list:"
(pip3 config list 2>/dev/null || pip config list 2>/dev/null) || echo "(empty)"
echo "### pip env:"
env | grep -Ei '^(PIP_|http_proxy|https_proxy|no_proxy)' || echo "(none)"
