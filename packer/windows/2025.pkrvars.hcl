# Windows Server 2025 Standard Evaluation, Desktop Experience.
vm_id         = 21200
template_name = "template-Windows-2025"
virtio_os     = "2k25"

# Staged on luggage once Tony accepted the Evaluation Center licence (2026-11-20).
# Source: https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso
# (from https://go.microsoft.com/fwlink/?linkid=2345730), build 26100.32230.
# The sha256 is hashed from Microsoft's HTTPS download, no vendor-published hash.
# packer-windows.sh checks the staged copy against it on the node before building.
iso_file     = "luggage:iso/windows-server-2025-eval-26100.32230-en-us.iso"
iso_checksum = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
