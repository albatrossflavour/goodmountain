# goodmountain

Builds Proxmox VM templates from upstream cloud images. It runs on the Proxmox host itself, pulls each image listed in `templates.csv`, customises it with `virt-customize`, and turns it into a cloud-init ready template with a predictable VMID and name.

## Why goodmountain

In Terry Pratchett's *The Truth*, Gunilla Goodmountain is the dwarf who casts the type for William de Worde's printing press. He does the foundry work nobody sees, and the press then stamps out copy after copy from what he cast.

That's this repo. goodmountain casts the templates, and every VM cloned from one is another impression off the same type. It sits alongside [igor](https://github.com/albatrossflavour/igor), which stitches the rest of a Puppet Enterprise lab together, and igor's stage 1 is a call to this builder. The name follows the same Discworld theme.

## Where it came from

The script started life in `proxform`, moved into igor as `scripts/template-generate.sh`, and was split out here in September 2026. Nothing about it is Puppet specific, so it doesn't belong inside igor. The files were copied across unchanged, so behaviour is the same as the last igor version.

## Files

| File | Purpose |
| ---- | ------- |
| `template-generate.sh` | Builds every template in `templates.csv` that doesn't already exist |
| `template-clean.sh` | Destroys existing Linux templates so they can be rebuilt from scratch |
| `templates.csv` | The list of templates to build: `Name,Version,URL,ISO` |

## Running it

The scripts expect to run from a working directory on the Proxmox host, with `templates.csv` and a file called `config` next to them. `config` holds the cloud-init password in plain text. Write it just before the run and delete it straight after (igor pipes it over SSH with `umask 077` so it never shows up in the process list).

```bash
cd /root/templates
printf '%s' "$CIPASSWORD" > config
STORAGE=ceph FORCE_REBUILD=false sh ./template-generate.sh
rm -f config
```

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `STORAGE` | `ceph` | Proxmox storage the disk is imported into |
| `FORCE_REBUILD` | `false` | Destroy and rebuild templates that already exist |

By default a run is idempotent. The existence check happens before any download or customisation, so the templates that already exist are skipped and cost nothing, and only the missing ones get built. Set `FORCE_REBUILD=true` when an upstream image has been refreshed.

## The contract with anything that clones these

Consumers clone by name, so the name and VMID scheme are the interface. Change them and every OpenTofu config that clones a template breaks without saying so.

- Name: `template-<Name>-<Version>`, for example `template-Ubuntu-2404`
- VMID: a four-digit base ID times ten, so Ubuntu 24.04 is `1250` becoming `12500`

The base ID uses a `KFVE` scheme:

- `K` is the kernel (`1` for Linux, `2` for Windows)
- `F` is the family (Red Hat `1`, Debian `2`, SUSE `3`, Arch `4`, Amazon `5`, Fedora `6`)
- `V` is the version slot within the family
- `E` is the instance, which is always `0` today

The mapping lives in `calculate_base_id()` in `template-generate.sh`.

## What it assumes about the host

These are hardcoded, not configurable. They match the lab it was written for:

- a Ceph cluster, with an RBD pool called `ceph`
- ISOs and cloud images cached in `/mnt/pve/luggage/template/iso`
- scratch space in `/root/templates`
- the `vmbr1` bridge and a `Templates` resource pool
- a cloud-init user of `tgreen`, with the SSH key at `~/.ssh/igor.pub` on the host
- `virt-customize` installed (from `libguestfs-tools`)

RedHat images have no public URL (the CSV says `NULL`). Download them from the Red Hat portal and drop them into the ISO directory before running.

## Known issues

These came across with the code and haven't been fixed yet.

- **Ubuntu can't be built from cold.** In `get_dynamic_url()` the codename check is inverted (`if ! codename=...`), so Ubuntu falls through to the CSV values, which are the literal string `DYNAMIC`. The download then fails. Ubuntu templates that already exist are skipped before this code runs, which is why nobody has noticed.
- **VMID collisions.** Alma and Oracle reuse Red Hat and Rocky slots. With the current CSV, `RedHat-8` and `Alma-9` both land on `11200`, `RedHat-9` and `Oracle-9` on `11300`, and `Oracle-8` and `Rocky-9` on `11800`. Whichever one is built first takes the slot, and the existence check then skips the other.
- **`template-clean.sh` destroys Windows too.** It keeps VMIDs of `91000` and above on the assumption that those are Windows templates, but the current scheme puts Windows 2022 at `21100`.
