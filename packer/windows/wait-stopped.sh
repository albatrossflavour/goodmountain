#!/usr/bin/env bash
#
# Run by Packer (shell-local) after finalise.ps1: waits up to 30 minutes for
# sysprep to power the VM off. The proxmox plugin then shuts it down, a no-op
# on a stopped VM, and makes the template, so it never interrupts sysprep.
# The token goes to curl on stdin, never in its arguments.
set -euo pipefail
: "${VMID:?}" "${NODE:?}" "${PROXMOX_URL:?}" "${PROXMOX_USERNAME:?}" "${PROXMOX_TOKEN:?}"

deadline=$(($(date +%s) + 1800))
while :; do
	status="$(printf 'url = "%s/nodes/%s/qemu/%s/status/current"\nheader = "Authorization: PVEAPIToken=%s=%s"\n' \
		"${PROXMOX_URL%/}" "$NODE" "$VMID" "$PROXMOX_USERNAME" "$PROXMOX_TOKEN" |
		curl -fsS --max-time 15 --config - | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')" || status=unknown
	if [ "$status" = stopped ]; then
		echo "VM ${VMID} is stopped: sysprep finished"
		exit 0
	fi
	if [ "$(date +%s)" -ge "$deadline" ]; then
		echo "VM ${VMID} is still ${status:-unknown} after 30 minutes: sysprep has not shut it down" >&2
		exit 1
	fi
	sleep 20
done
