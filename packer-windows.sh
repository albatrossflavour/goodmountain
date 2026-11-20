#!/usr/bin/env bash
#
# packer-windows.sh - build template-Windows-<version> with Packer, from the
# workstation.
#
#   op run --account thegreens.1password.com --env-file packer/windows/proxmox.env -- ./packer-windows.sh 2022|2025
#
# Run it with OP_SERVICE_ACCOUNT_TOKEN unset. The proxmox plugin reads
# PROXMOX_URL, PROXMOX_USERNAME, and PROXMOX_TOKEN from the environment, which
# op run fills from igor's existing token, so no variable is set on the
# command line and no credential reaches argv. The build's Administrator password is generated
# here, handed to Packer as PKR_VAR_build_password, never printed, and the
# account is disabled before sysprep. PACKER_LOG is unset, since a debug log
# would carry every request.
#
# The VMID is calculate_base_id from template-generate.sh, times ten, so the
# numbering has one home. A template that already exists is skipped.
# FORCE_REBUILD=true replaces it only with CONFIRM_DESTROY=<that VMID>, and
# only when that VMID holds a template of exactly the expected name. Nothing
# else is ever deleted.

set -euo pipefail
cd "$(dirname "$0")"

version="${1:-}"
case "$version" in
2022 | 2025) ;;
*)
	echo "usage: ./packer-windows.sh 2022 or 2025" >&2
	exit 2
	;;
esac

missing=()
for v in PROXMOX_URL PROXMOX_USERNAME PROXMOX_TOKEN; do
	[ -n "${!v:-}" ] || missing+=("$v")
done
if [ "${#missing[@]}" -gt 0 ]; then
	echo "Not set: ${missing[*]}. Run through op run with packer/windows/proxmox.env." >&2
	exit 1
fi
unset PACKER_LOG PACKER_LOG_PATH

eval "$(sed -n '/^calculate_base_id() {/,/^}/p' template-generate.sh)"
vmid=$(($(calculate_base_id Windows "$version") * 10))
name="template-Windows-${version}"
varfile="packer/windows/${version}.pkrvars.hcl"
node=ankh

# The var file must agree with the numbering.
if ! grep -qE "^vm_id[[:space:]]*=[[:space:]]*${vmid}\$" "$varfile" ||
	! grep -qE "^template_name[[:space:]]*=[[:space:]]*\"${name}\"\$" "$varfile"; then
	echo "${varfile} must have vm_id = ${vmid} and template_name = \"${name}\"" >&2
	exit 1
fi

# The Proxmox API, with the token on curl's stdin, never in its arguments.
pve() {
	local method="$1" path="$2"
	printf 'url = "%s/%s"\nrequest = "%s"\nheader = "Authorization: PVEAPIToken=%s=%s"\n' \
		"${PROXMOX_URL%/}" "$path" "$method" "$PROXMOX_USERNAME" "$PROXMOX_TOKEN" |
		curl -fsS --max-time 30 --config -
}

resources="$(pve GET 'cluster/resources?type=vm')"
at_vmid="$(jq -r --argjson id "$vmid" '.data[] | select(.vmid == $id) | "\(.name)\t\(.template // 0)\t\(.node)"' <<<"$resources")"
elsewhere="$(jq -r --arg n "$name" --argjson id "$vmid" '.data[] | select(.name == $n and .vmid != $id) | .vmid' <<<"$resources" | paste -sd' ' -)"

if [ -n "$elsewhere" ]; then
	echo "${name} already exists as VMID ${elsewhere}, but belongs at ${vmid}. Remove the old one first." >&2
	exit 1
fi

if [ -n "$at_vmid" ]; then
	IFS=$'\t' read -r have_name have_template have_node <<<"$at_vmid"
	if [ "${FORCE_REBUILD:-false}" != true ]; then
		echo "Template ${vmid} (${have_name}) already exists - skipping"
		exit 0
	fi
	if [ "${CONFIRM_DESTROY:-}" != "$vmid" ]; then
		echo "FORCE_REBUILD=true destroys VMID ${vmid}. Set CONFIRM_DESTROY=${vmid} to confirm." >&2
		exit 1
	fi
	if [ "$have_name" != "$name" ] || [ "$have_template" != 1 ]; then
		echo "VMID ${vmid} holds ${have_name} (template=${have_template}), not the template ${name}. Nothing destroyed." >&2
		exit 1
	fi
	echo "Destroying template ${vmid} (${name}) on ${have_node} to rebuild it"
	pve DELETE "nodes/${have_node}/qemu/${vmid}?purge=1&destroy-unreferenced-disks=1" >/dev/null
	for _ in $(seq 1 60); do
		jq -e --argjson id "$vmid" '.data | any(.vmid == $id)' <<<"$(pve GET 'cluster/resources?type=vm')" >/dev/null || break
		sleep 5
	done
fi

# Letters and digits, at least one of each case and a digit, so Windows'
# complexity rule never refuses it.
build_password=''
until [[ "$build_password" =~ [A-Z] && "$build_password" =~ [a-z] && "$build_password" =~ [0-9] ]]; do
	build_password="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
done
export PKR_VAR_build_password="$build_password"
unset build_password

echo "Building ${name} at VMID ${vmid} on ${node}"
packer init packer/windows
packer build -on-error=cleanup -var-file="packer/windows/${version}.pkrvars.hcl" packer/windows
