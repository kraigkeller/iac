#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")/ansible"

cd "$ANSIBLE_DIR"

ansible --version | head -n 1
ansible-playbook playbook.yml --syntax-check || exit 1

for role in common security docker k8s_prereqs observability ad_auth; do
    [ -d "roles/$role" ] || exit 1
done

[ -f "roles/k8s_prereqs/vars/main.yml" ] || exit 1

for env in dev staging production; do
    [ -f "inventory/$env/hosts.yml" ] && ansible-inventory -i "inventory/$env/hosts.yml" --list > /dev/null 2>&1
done

command -v ansible-lint &> /dev/null && ansible-lint playbook.yml || true
