# Windows Server 2022 Standard Evaluation, Desktop Experience.
vm_id         = 21100
template_name = "template-Windows-2022"
virtio_os     = "2k22"

# Staged on luggage once Tony accepted the Evaluation Center licence (2026-11-20).
# Source: https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso
# (from https://go.microsoft.com/fwlink/p/?LinkID=2195280), build 20348.587.
# The sha256 is hashed from Microsoft's HTTPS download, no vendor-published hash.
# packer-windows.sh checks the staged copy against it on the node before building.
iso_file     = "luggage:iso/windows-server-2022-eval-20348.587-en-us.iso"
iso_checksum = "sha256:3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325"
