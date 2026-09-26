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
| `template-clean.sh` | Destroys every Linux template (VMID below `20000`, name starting `template-`) so they can be rebuilt from scratch. Windows templates are left alone |
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
- `F` is the family (Red Hat `1`, Debian `2`, SUSE `3`, Arch `4`, Amazon `5`, Fedora `6`, Alma `7`, Oracle `8`, RHEL and Rocky 10 onwards `9`)
- `V` is the version slot within the family
- `E` is the instance, which is always `0` today

Alma and Oracle are Red Hat rebuilds, but family 1 has all nine version slots taken, so each gets a family of its own. RHEL and Rocky keep their 8 and 9 slots in family 1, and their 10 releases continue in family 9 (`19100` and `19200`). `1990` remains the fallback for unknown Linux. The mapping lives in `calculate_base_id()` in `template-generate.sh`.

Names have to be unique on the host. Before building, the generator checks whether a template with the same name exists under a different VMID. If it does, it refuses to build and tells you, even with `FORCE_REBUILD=true`, because a second copy would make every clone by that name ambiguous. It won't remove the old one for you. Your VMs are linked clones (`full_clone = false` in igor), so the old template may still have disks depending on it.

## Moving off the old numbering

Before September 2026, Alma used `11100`/`11200` and Oracle used `11700`, `11800` and `11300`, sharing slots with Red Hat and Rocky. On a host built under that scheme, the generator flags the old ones and skips them. To move each one over:

1. Check nothing is a linked clone of it (`qm config` on your VMs, or destroy the environment first).
2. `qm destroy <old vmid> --destroy-unreferenced-disks 1`
3. Run `template-generate.sh` again. It builds the template at the new VMID under the same name, so nothing that clones it needs to change.

`template-clean.sh` does the same job in bulk. It destroys every Linux template, old numbering included, and leaves Windows alone.

## What it assumes about the host

These are hardcoded, not configurable. They match the lab it was written for:

- a Ceph cluster, with an RBD pool called `ceph`
- ISOs and cloud images cached in `/mnt/pve/luggage/template/iso`
- scratch space in `/root/templates`
- the `vmbr1` bridge and a `Templates` resource pool
- a cloud-init user of `tgreen`, with the SSH key at `~/.ssh/igor.pub` on the host
- `virt-customize` installed (from `libguestfs-tools`)

RedHat images have no public URL (the CSV says `NULL`). Download them from the Red Hat portal and drop them into the ISO directory before running. RHEL 10 has a VMID slot but no CSV row. Add one with the filename of the image you download, for example `RedHat,10,NULL,rhel-10.1-x86_64-kvm.qcow2`.

EL10 (RHEL, Rocky, Alma and Oracle 10) needs an x86-64-v3 CPU, which means AVX2. All three nodes in the current cluster support it. The templates use `cputype=host`, so clones get the real CPU flags. AlmaLinux also publishes an `x86_64_v2` build for older hardware, which the CSV doesn't use.

