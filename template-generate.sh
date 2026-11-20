#!/bin/sh

# Don't use set -e globally, but check critical operations explicitly

# Function to handle cleanup and exit
cleanup_and_exit() {
	exit_code="$1"
	error_msg="$2"

	echo ""
	echo "CRITICAL ERROR: $error_msg"
	echo "Template generation aborted to prevent further damage."
	echo ""

	# Clean up any temp files
	rm -f "${BASEDIR}"/prod-*.qcow2 2>/dev/null || true

	exit "$exit_code"
}

# Function to check critical prerequisites
check_prerequisites() {
	# Check if we can access Ceph
	if ! ceph -s >/dev/null 2>&1; then
		cleanup_and_exit 1 "Cannot access Ceph cluster"
	fi

	# Check if storage pool exists
	if ! rbd ls ceph >/dev/null 2>&1; then
		cleanup_and_exit 1 "Cannot access RBD pool 'ceph'"
	fi

	# Check if we have required directories
	if [ ! -d "$ISODIR" ]; then
		cleanup_and_exit 1 "ISO directory $ISODIR does not exist"
	fi

	echo "✓ Prerequisites check passed"
}

BASEDIR=${BASEDIR:-/root/templates} # Scratch space and lock; override to build from a separate directory
TEMPLATES='./templates.csv'
ISODIR=${ISODIR:-/mnt/pve/luggage/template/iso} # The image cache, shared between the Proxmox nodes
KEYDIR=${KEYDIR:-./keys}                        # The pinned distro signing keys (keys/fingerprints)
STORAGE=${STORAGE:-ceph}              # Allow override with: STORAGE=local-lvm ./template-generate.sh
FORCE_REBUILD=${FORCE_REBUILD:-false} # Set FORCE_REBUILD=true to rebuild templates that already exist
INSTANCE=${INSTANCE:-00}              # EE in KFVEE: 00 is the primary template, 01 to 99 build a parallel copy beside it
NAME_SUFFIX=${NAME_SUFFIX:-}          # Appended to the template name, for example -v2. Required when INSTANCE is not 00
TARGETS=${TARGETS:-}                  # Build only these, each at its own VMID: "ubuntu-2404=12501 rocky-9=11800"

if [ -n "$TARGETS" ] && { [ -n "${INSTANCE#00}" ] || [ -n "$NAME_SUFFIX" ]; }; then
	echo "TARGETS gives each template its own VMID, so it can't be combined with INSTANCE or NAME_SUFFIX" >&2
	exit 1
fi

case "$INSTANCE" in
[0-9][0-9]) ;;
*)
	echo "INSTANCE must be two digits, 00 to 99 (got '${INSTANCE}')" >&2
	exit 1
	;;
esac
if [ "$INSTANCE" != "00" ] && [ -z "$NAME_SUFFIX" ]; then
	echo "INSTANCE=${INSTANCE} needs NAME_SUFFIX (for example -v2): two templates must never share a name" >&2
	exit 1
fi
# Decimal value of INSTANCE (08 and 09 are not valid octal in shell arithmetic)
INSTANCE_NUM=$(echo "$INSTANCE" | sed 's/^0*//; s/^$/0/')

# Run a command quietly, but print the tail of its output if it fails, so the
# reason a qm step failed is never thrown away.
quiet() {
	out=$("$@" 2>&1) && return 0
	rc=$?
	printf '%s\n' "$out" | tail -n 5 | sed 's/^/     /'
	return $rc
}

# ID Calculation Functions - KFVEE format
# K=Kernel (1=Linux,2=Windows), F=Family(0-9), V=Version(0-9), EE=Instance(00-99)
calculate_base_id() {
	name="$1"
	version="$2"

	# RHEL and Rocky 10+ live in family 9 (see below)
	case "$name" in
	RedHat | Rocky)
		case "$version" in
		10) name="${name}10" ;;
		esac
		;;
	esac

	case "$name" in
	# Red Hat Family (F=1): RHEL, CentOS, Rocky, Alma, Oracle
	"RedHat")
		case "$version" in
		7) echo 1110 ;;
		8) echo 1120 ;;
		9) echo 1130 ;;
		*) echo 1190 ;;
		esac
		;;
	"CentOS")
		case "$version" in
		6) echo 1140 ;;
		7) echo 1150 ;;
		Stream) echo 1160 ;;
		*) echo 1190 ;;
		esac
		;;
	"Rocky")
		case "$version" in
		8) echo 1170 ;;
		9) echo 1180 ;;
		*) echo 1190 ;;
		esac
		;;
	# RHEL rebuilds that no longer fit in family 1, which has every version
	# slot taken. They used to share RHEL and Rocky slots, so whichever built
	# first claimed the VMID and the existence check skipped the other.
	"Alma")
		case "$version" in
		8) echo 1710 ;;
		9) echo 1720 ;;
		10) echo 1730 ;;
		*) echo 1790 ;;
		esac
		;;
	"Oracle")
		case "$version" in
		7) echo 1810 ;;
		8) echo 1820 ;;
		9) echo 1830 ;;
		10) echo 1840 ;;
		*) echo 1890 ;;
		esac
		;;

	# Debian Family (F=2): Debian, Ubuntu
	"Debian")
		case "$version" in
		11) echo 1210 ;;
		12) echo 1220 ;;
		*) echo 1290 ;;
		esac
		;;
	"Ubuntu")
		case "$version" in
		2004) echo 1230 ;;
		2204) echo 1240 ;;
		2404) echo 1250 ;;
		*) echo 1290 ;;
		esac
		;;

	# SUSE Family (F=3): OpenSUSE, SLES
	"OpenSUSE")
		case "$version" in
		15.6) echo 1310 ;;
		*) echo 1390 ;;
		esac
		;;
	"SLES")
		case "$version" in
		15) echo 1320 ;;
		*) echo 1390 ;;
		esac
		;;

	# Arch Family (F=4)
	"Arch") echo 1410 ;;

	# Amazon Family (F=5)
	"AmazonLinux")
		case "$version" in
		2) echo 1510 ;;
		*) echo 1590 ;;
		esac
		;;

	# EL10 onwards for RHEL and Rocky (F=9). Family 1 is full, so their newer
	# releases continue here. 1990 stays the unknown Linux fallback.
	"RedHat10") echo 1910 ;;
	"Rocky10") echo 1920 ;;

	# Fedora Family (F=6)
	"Fedora")
		case "$version" in
		36) echo 1610 ;;
		40) echo 1620 ;;
		*) echo 1690 ;;
		esac
		;;

	# Windows Family (K=2, F=1)
	"Windows")
		case "$version" in
		2022) echo 2110 ;;
		2025) echo 2120 ;;
		*) echo 2190 ;;
		esac
		;;

	*) echo 1990 ;; # Unknown Linux
	esac
}

# URL Discovery Functions
get_ubuntu_codename() {
	case $1 in
	2004) echo "focal" ;;
	2204) echo "jammy" ;;
	2404) echo "noble" ;;
	*) return 1 ;;
	esac
}

get_dynamic_url() {
	name="$1"
	version="$2"
	fallback_url="$3"
	fallback_iso="$4"

	case "$name-$version" in
	"Rocky-8" | "Rocky-9" | "Rocky-10")
		echo "https://dl.rockylinux.org/pub/rocky/$version/images/x86_64/"
		echo "Rocky-$version-GenericCloud-Base.latest.x86_64.qcow2"
		return 0
		;;
	"Alma-8" | "Alma-9" | "Alma-10")
		echo "https://repo.almalinux.org/almalinux/$version/cloud/x86_64/images/"
		echo "AlmaLinux-$version-GenericCloud-latest.x86_64.qcow2"
		return 0
		;;
	"CentOS-Stream")
		echo "https://cloud.centos.org/centos/9-stream/x86_64/images/"
		echo "CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
		return 0
		;;
	"Fedora-"*)
		echo "https://download.fedoraproject.org/pub/fedora/linux/releases/$version/Cloud/x86_64/images/"
		echo "Fedora-Cloud-Base-Generic.x86_64-$version-1.2.qcow2"
		return 0
		;;
	"Ubuntu-"*)
		if codename=$(get_ubuntu_codename "$version"); then
			echo "https://cloud-images.ubuntu.com/$codename/current/"
			echo "$codename-server-cloudimg-amd64.img"
			return 0
		fi
		;;
	esac

	# Fallback to CSV values
	echo "$fallback_url"
	echo "$fallback_iso"
	return 1
}

# Image verification
#
# Every image is checked against a checksum before it's used, and the checksum
# is only trusted when it's signed by a distro key pinned in keys/fingerprints,
# or pinned in templates.csv. A mismatch fails that template loudly and the
# image is never used.

# How a distro publishes checksums for an image, as
# "ALGO SUMS_URL SIG_URL SIGNED KEY": SIGNED says what the signature covers
# (sums, or the image itself), and "-" means upstream publishes none. Names
# not listed publish nothing usable, so they need a SHA256 in templates.csv.
verification_for() {
	name="$1"
	version="$2"
	url="$3"
	iso="$4"
	case "$name" in
	Rocky)
		case "$version" in
		8) echo "sha256 ${url}CHECKSUM - - -" ;; # Rocky 8 doesn't sign its image checksums
		*) echo "sha256 ${url}CHECKSUM ${url}CHECKSUM.asc sums rocky-${version}" ;;
		esac
		;;
	Alma) echo "sha256 ${url}CHECKSUM ${url}CHECKSUM.asc sums alma-${version}" ;;
	Ubuntu) echo "sha256 ${url}SHA256SUMS ${url}SHA256SUMS.gpg sums ubuntu-cloud-images" ;;
	Debian) echo "sha512 ${url}SHA512SUMS - - -" ;; # Debian doesn't sign its cloud image checksums
	Arch) echo "sha256 ${url}${iso}.SHA256 ${url}${iso}.sig image arch-boxes" ;;
	AmazonLinux) echo "sha256 ${url}SHA256SUMS ${url}SHA256SUMS.RSASSA_PKCS1_V1_5_SHA_256 sums amazon-linux-2" ;;
	*) echo "sha256 - - - -" ;;
	esac
}

lower() {
	tr '[:upper:]' '[:lower:]'
}

# Check SIG over DATA with the key pinned as KEY, using WORK for scratch.
# OpenPGP keys must make a VALIDSIG whose primary key is the pinned
# fingerprint; Amazon's RSA key must have the pinned DER SHA256.
verify_signature() {
	key="$1"
	sig="$2"
	data="$3"
	work="$4"
	pinned=$(awk -v k="$key" '$1 == k {print $2; exit}' "${KEYDIR}/fingerprints" 2>/dev/null | lower)
	if [ -z "$pinned" ]; then
		echo "  ✗ No pinned fingerprint for key '${key}' in ${KEYDIR}/fingerprints"
		return 1
	fi
	if [ -f "${KEYDIR}/${key}.pem" ]; then
		have=$(openssl pkey -pubin -in "${KEYDIR}/${key}.pem" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
		if [ "$have" != "$pinned" ]; then
			echo "  ✗ ${KEYDIR}/${key}.pem is not the pinned key (${pinned})"
			return 1
		fi
		if ! openssl dgst -sha256 -verify "${KEYDIR}/${key}.pem" -signature "$sig" "$data" >/dev/null 2>&1; then
			echo "  ✗ Bad signature on $(basename "$data"): not signed by the pinned ${key} key"
			return 1
		fi
		return 0
	fi
	if ! gpg --batch --quiet --dearmor <"${KEYDIR}/${key}.asc" >"${work}/${key}.gpg" 2>/dev/null; then
		echo "  ✗ Could not read ${KEYDIR}/${key}.asc"
		return 1
	fi
	if ! status=$(gpgv --status-fd 1 --keyring "${work}/${key}.gpg" "$sig" "$data" 2>/dev/null); then
		echo "  ✗ Bad signature on $(basename "$data"): not signed by the ${key} key"
		return 1
	fi
	if ! printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $NF}' | lower | grep -qx "$pinned"; then
		echo "  ✗ $(basename "$data") is signed, but not by the pinned ${key} key (${pinned})"
		return 1
	fi
}

# The one checksum SUMS lists for ISO, in GNU (hash  name, hash *name) or BSD
# (SHA256 (name) = hash) format.
sum_for() {
	sums="$1"
	iso="$2"
	algo=$(echo "$3" | tr '[:lower:]' '[:upper:]')
	awk -v f="$iso" -v a="$algo" '
		NF == 2 && ($2 == f || $2 == "*" f) { print $1 }
		NF == 4 && $1 == a && $2 == "(" f ")" && $3 == "=" { print $4 }
	' "$sums" | lower | sort -u
}

# Fetch and check what ISO should hash to, setting SUM_ALGO, EXPECTED_SUM,
# SIGNED, and SIGN_KEY. PINNED is the SHA256 from templates.csv, if any. Runs
# before the image is downloaded, so a bad checksum file costs nothing.
expected_sum() {
	name="$1"
	version="$2"
	url="$3"
	iso="$4"
	pinned_sum=$(echo "$5" | lower)
	work="$6"
	read -r SUM_ALGO sums_url sig_url SIGNED SIGN_KEY <<-SPEC
		$(verification_for "$name" "$version" "$url" "$iso")
	SPEC
	EXPECTED_SUM=""
	if [ "$url" != "NULL" ] && [ "$sums_url" != "-" ]; then
		if ! quiet curl -fsSL -o "${work}/sums" "$sums_url"; then
			echo "  ✗ Could not fetch the checksums at ${sums_url}"
			return 1
		fi
		if [ "$sig_url" = "-" ]; then
			echo "  ! ${name} ${version} doesn't sign its checksums: checking against ${sums_url} over HTTPS only"
		elif ! quiet curl -fsSL -o "${work}/sig" "$sig_url"; then
			echo "  ✗ Could not fetch the signature at ${sig_url}"
			return 1
		elif [ "$SIGNED" = "sums" ]; then
			verify_signature "$SIGN_KEY" "${work}/sig" "${work}/sums" "$work" || return 1
		fi
		EXPECTED_SUM=$(sum_for "${work}/sums" "$iso" "$SUM_ALGO")
		case "$(printf '%s\n' "$EXPECTED_SUM" | grep -c .)" in
		1) ;;
		0)
			echo "  ✗ ${sums_url} lists no checksum for ${iso}"
			return 1
			;;
		*)
			echo "  ✗ ${sums_url} lists more than one checksum for ${iso}"
			return 1
			;;
		esac
	fi
	if [ -n "$pinned_sum" ]; then
		if [ -n "$EXPECTED_SUM" ] && [ "$EXPECTED_SUM" != "$pinned_sum" ]; then
			echo "  ✗ The SHA256 pinned in templates.csv for ${iso} isn't the one upstream publishes"
			return 1
		fi
		SUM_ALGO=sha256
		EXPECTED_SUM="$pinned_sum"
	fi
	if [ -z "$EXPECTED_SUM" ]; then
		echo "  ✗ Nothing to check ${iso} against: upstream publishes no checksum, so pin its SHA256 in templates.csv"
		return 1
	fi
}

# Check FILE against what expected_sum found, and against the signature when
# upstream signs the image itself (Arch).
check_image() {
	file="$1"
	work="$2"
	have=$("${SUM_ALGO}sum" "$file" | awk '{print $1}')
	if [ "$have" != "$EXPECTED_SUM" ]; then
		echo "  ✗ CHECKSUM MISMATCH for $(basename "$file"): ${SUM_ALGO} is ${have}, upstream says ${EXPECTED_SUM}. Not using it."
		return 1
	fi
	if [ "$SIGNED" = "image" ]; then
		verify_signature "$SIGN_KEY" "${work}/sig" "$file" "$work" || return 1
	fi
	return 0
}

if [ ! -f "${TEMPLATES}" ]; then
	echo "Couldn't find ${TEMPLATES} : exiting" >&2
	exit 1
fi

if [ ! -d "${ISODIR}" ]; then
	echo "Couldn't find ${ISODIR} : exiting" >&2
	exit 1
fi

# Build one template. LINE is its templates.csv row, INST its instance (the
# EE in KFVEE) and SUFFIX what goes on the end of its name. Returns 1 when the
# template fails, so the run can say so.
process_template() {
	LINE="$1"
	INST="$2"
	SUFFIX="$3"
	NAME=$(echo "$LINE" | awk -F, '{print $1}')
	LCNAME=$(echo "$NAME" | tr "[:upper:]" "[:lower:]")
	VER=$(echo "$LINE" | awk -F, '{print $2}')

	# Calculate template ID
	BASE_ID=$(calculate_base_id "$NAME" "$VER")
	TPROD=$((BASE_ID * 10 + INST))
	TNAME="template-${NAME}-${VER}${SUFFIX}"

	# Consumers clone by name, so two templates with the same name make every
	# clone ambiguous. If this name already exists under a different VMID (left
	# behind by an older numbering scheme), refuse rather than build a second
	# one. This applies under FORCE_REBUILD too, which only ever destroys
	# ${TPROD}. The old template may have linked clones hanging off it, so
	# removing it is left to the operator.
	OTHER_IDS=$(qm list 2>/dev/null | awk -v n="$TNAME" -v id="$TPROD" '$2 == n && $1 != id {printf "%s ", $1}')
	if [ -n "$OTHER_IDS" ]; then
		echo "  ✗ ${TNAME} already exists as VMID ${OTHER_IDS}but belongs at ${TPROD} - skipping"
		echo "     Destroy the old one (after moving any linked clones off it), then rerun"
		return 1
	fi

	# Skip templates that already exist unless a rebuild is explicitly forced.
	# This runs before the ISO download and virt-customize, so a warm host only
	# pays for templates that are actually missing. Set FORCE_REBUILD=true to
	# refresh a template that already exists (for example after an upstream image
	# update).
	if [ "${FORCE_REBUILD}" != "true" ] && qm status "${TPROD}" >/dev/null 2>&1; then
		echo "  ✓ Template ${TPROD} (${TNAME}) already exists - skipping"
		return
	fi

	# CSV parsing (Name,Version,URL,ISO,SHA256)
	CSV_URL=$(echo "$LINE" | awk -F, '{print $3}')
	CSV_ISO=$(echo "$LINE" | awk -F, '{print $4}')
	CSV_SHA256=$(echo "$LINE" | awk -F, '{print $5}')

	# Get dynamic URL or fallback to CSV
	DYNAMIC_RESULT=$(get_dynamic_url "$NAME" "$VER" "$CSV_URL" "$CSV_ISO")
	URL=$(echo "$DYNAMIC_RESULT" | head -n1)
	# Line two, not the last line: a row with no ISO (Windows) gives one line,
	# and the last line would then be its URL.
	ISO=$(echo "$DYNAMIC_RESULT" | sed -n 2p)

	if [ -z "${ISO}" ]; then
		echo "  ✗ No ISO definition - skipping"
		return
	fi

	# Work out what the image must hash to before touching it: fetch the
	# distro's checksums and check their signature against the pinned key.
	WORK=$(mktemp -d "${BASEDIR}/verify.XXXXXX") || {
		echo "  ✗ Could not make a scratch directory in ${BASEDIR}"
		return 1
	}
	expected_sum "$NAME" "$VER" "$URL" "$ISO" "$CSV_SHA256" "$WORK" || return 1

	# Fetch the image, or refresh the cached copy when upstream has a newer one.
	# Most upstream names (latest, current) never change, so a cache keyed on
	# the file existing would build from the same old image forever. curl -R
	# keeps upstream's timestamp on the file and -z only downloads when
	# upstream is newer than it. Download to a .part file and only rename it
	# into place once complete and verified, so neither a partial nor a
	# tampered download reaches the cache. It goes in 0644: the cache is a
	# shared NFS export, and the server would otherwise make it 0777 (see the
	# README). NULL means no public URL (RedHat): the image must already be in
	# the cache.
	if [ "${URL}" != "NULL" ]; then
		echo "  → Checking ${ISO} upstream..."
		rm -f "${ISODIR}/${ISO}.part"
		if [ -f "${ISODIR}/${ISO}" ]; then
			set -- -z "${ISODIR}/${ISO}"
		else
			set --
		fi
		if ! quiet curl -fsSL -R "$@" -o "${ISODIR}/${ISO}.part" "${URL}${ISO}"; then
			rm -f "${ISODIR}/${ISO}.part"
			echo "  ✗ Download failed"
			return 1
		elif [ -s "${ISODIR}/${ISO}.part" ]; then
			if ! check_image "${ISODIR}/${ISO}.part" "$WORK"; then
				rm -f "${ISODIR}/${ISO}.part"
				return 1
			fi
			chmod 0644 "${ISODIR}/${ISO}.part"
			mv "${ISODIR}/${ISO}.part" "${ISODIR}/${ISO}"
			echo "  → Downloaded a newer ${ISO} (verified)"
		else
			rm -f "${ISODIR}/${ISO}.part"
		fi
	fi
	if [ ! -f "${ISODIR}/${ISO}" ]; then
		echo "  ✗ ${ISO} is not in ${ISODIR}"
		return 1
	fi

	TMPISO="${BASEDIR}/prod-${ISO}"

	# Verify the private working copy, not the cache: the copy is what gets
	# built, and anything that can write to the share could swap the cached
	# file after it was checked.
	cp "${ISODIR}/${ISO}" "${TMPISO}"
	if ! check_image "${TMPISO}" "$WORK"; then
		echo "     The cached ${ISODIR}/${ISO} doesn't match upstream. Remove it to download it again."
		return 1
	fi

	echo "  → Customizing image (ID: $TPROD)..."

	# Build virt-customize command with batched operations
	VIRT_CMD="virt-customize -a $TMPISO"

	# Patch the image up to date and add the packages every template needs,
	# so a clone doesn't boot hundreds of updates behind. RedHat is skipped:
	# it has no repositories without a subscription.
	case "${NAME}" in
	RedHat) ;;
	Debian | Ubuntu)
		# A full-upgrade, because virt-customize --update only runs apt-get
		# upgrade, which holds back a new kernel.
		PACKAGES="qemu-guest-agent,unzip"
		[ "${NAME}" = "Debian" ] && PACKAGES="${PACKAGES},gnupg"
		VIRT_CMD="${VIRT_CMD} --run-command 'export DEBIAN_FRONTEND=noninteractive; apt-get -q -y update && apt-get -q -y -o Dpkg::Options::=--force-confnew full-upgrade && apt-get -q -y autoremove --purge && apt-get -q -y clean'"
		VIRT_CMD="${VIRT_CMD} --install ${PACKAGES}"
		;;
	Arch)
		# The image has no keyring (pacman-init.service makes one at first
		# boot), and pacman's sandbox needs Landlock, which the libguestfs
		# appliance kernel lacks. Build a throwaway keyring, run pacman without
		# the sandbox, and remove the keyring so each clone generates its own.
		VIRT_CMD="${VIRT_CMD} --run-command 'pacman-key --init && pacman-key --populate archlinux && pacman --disable-sandbox -Syu --noconfirm qemu-guest-agent unzip && pacman --disable-sandbox -Scc --noconfirm; rc=\$?; rm -rf /etc/pacman.d/gnupg; exit \$rc'"
		;;
	AmazonLinux)
		# virt-customize doesn't recognise Amazon Linux, so its --update and
		# --install can't find a package manager. Call yum directly.
		VIRT_CMD="${VIRT_CMD} --run-command 'yum -y -q update && yum -y -q install qemu-guest-agent unzip && yum clean all'"
		;;
	*)
		VIRT_CMD="${VIRT_CMD} --update --install qemu-guest-agent,unzip"
		;;
	esac

	# SELinux stays enforcing. Packages are installed by virt-customize, so the
	# files it writes need correct labels at first boot.
	if [ "${VER}" = "10" ] || [ "${VER}" = "9" ] || [ "${VER}" = 8 ] || [ "${VER}" = "Stream" ]; then
		VIRT_CMD="${VIRT_CMD} --selinux-relabel"
		# Both consoles: the image only carries console=ttyS0, so the noVNC
		# console (vga std) would stay blank. grubby replaces a repeated
		# console= argument, so both are passed together. It fixes the existing
		# boot entries and the /etc/default/grub edit covers kernels installed later.
		VIRT_CMD="${VIRT_CMD} --run-command 'grubby --update-kernel=ALL --args=\"console=ttyS0,115200n8 console=tty0\"'"
		VIRT_CMD="${VIRT_CMD} --edit '/etc/default/grub:s/^(GRUB_CMDLINE_LINUX_DEFAULT=\".*)\"\$/\$1 console=tty0\"/'"
	fi

	# Machine ID and random seed cleanup (all systems)
	# Empty, not removed, so systemd makes a new one at first boot. Some
	# images (Arch) ship without the file, and then there's nothing to empty.
	VIRT_CMD="${VIRT_CMD} --run-command 'if [ -e /etc/machine-id ]; then : >/etc/machine-id; fi'"
	VIRT_CMD="${VIRT_CMD} --run-command 'rm -f /var/lib/dbus/machine-id'"

	# Additional cleanup for Debian-based systems
	if [ "${NAME}" = "Debian" ] || [ "${NAME}" = "Ubuntu" ]; then
		# Both consoles, as for EL: console=tty0 for noVNC and ttyS0 for the
		# serial console (last console= wins /dev/console). Ubuntu sets
		# console=tty1 in grub.d and Debian sets its own in GRUB_CMDLINE_LINUX,
		# so strip whatever console= is there and add the pair, then rebuild
		# grub.cfg so the change is in the boot menu and not only the defaults.
		VIRT_CMD="${VIRT_CMD} --run-command 'sed -i -E \"/^GRUB_CMDLINE_LINUX(_DEFAULT)?=.*console=/ { s/ ?console=(tty[0-9]+|ttyS0(,[0-9a-z]+)?)//g; s/\\\"[[:space:]]*\$/ console=tty0 console=ttyS0,115200n8\\\"/; s/=\\\" /=\\\"/ }\" /etc/default/grub /etc/default/grub.d/*.cfg'"
		VIRT_CMD="${VIRT_CMD} --run-command 'update-grub'"
		VIRT_CMD="${VIRT_CMD} --run-command 'rm -f /var/lib/systemd/random-seed /var/lib/urandom/random-seed'"
	fi

	# Execute single batched virt-customize command. Output goes to a log that
	# is only shown on failure. A failed customise must stop here: carrying on
	# builds a template without qemu-guest-agent, and every clone then sits out
	# the provider's agent timeout.
	if ! eval "$VIRT_CMD" >"${TMPISO}.log" 2>&1; then
		echo "  ✗ virt-customize failed for ${TNAME}:"
		tail -n 5 "${TMPISO}.log" | sed 's/^/     /'
		rm -f "$TMPISO" "${TMPISO}.log"
		return 1
	fi
	rm -f "${TMPISO}.log"

	# Destroy the existing template before rebuilding. We only reach this point
	# when the template did not exist, or when FORCE_REBUILD=true, so this is the
	# forced-refresh path (the early skip above handles the default warm case).
	if qm status ${TPROD} >/dev/null 2>&1; then
		# Only ever destroy a VM that carries the name this run would give it.
		EXISTING_NAME=$(qm config ${TPROD} 2>/dev/null | awk '/^name:/ {print $2}')
		if [ "$EXISTING_NAME" != "$TNAME" ]; then
			echo "  ✗ VMID ${TPROD} is '${EXISTING_NAME}', not ${TNAME}: refusing to destroy it"
			return 1
		fi
		echo "  → Destroying existing template ${TPROD} (force rebuild)..."
		quiet qm destroy ${TPROD} --destroy-unreferenced-disks 1 || {
			echo "  ✗ Could not destroy template ${TPROD}, it may be in use"
			return 1
		}
	fi

	echo "  → Creating VM ${TPROD}..."
	if ! quiet qm create ${TPROD} --memory 1024 --core 2 --name "${TNAME}" --net0 virtio,bridge=vmbr1 --pool Templates --cpu cputype=host --machine q35 --rng0 source=/dev/urandom; then
		echo "  ✗ Failed to create template ${TPROD}"
		# Check if this is a critical error (VM ID already exists)
		if qm status ${TPROD} >/dev/null 2>&1; then
			cleanup_and_exit 1 "VM ${TPROD} already exists. Run template-clean.sh first."
		fi
		return 1
	fi
	echo "  → Importing disk..."
	if ! IMPORT_OUTPUT=$(qm importdisk ${TPROD} "${TMPISO}" "${STORAGE}" 2>&1); then
		echo "  ✗ Failed to import disk for template ${TPROD}"
		echo "     Try: STORAGE=local-lvm ./template-generate.sh"
		qm destroy ${TPROD} --destroy-unreferenced-disks 1 2>/dev/null
		rm -f "$TMPISO"
		return 1
	fi

	# Extract the actual disk name from import output
	IMPORTED_DISK=$(echo "$IMPORT_OUTPUT" | grep "unused.*successfully imported disk" | sed "s/.*'\([^']*\)'.*/\1/")
	if [ -z "$IMPORTED_DISK" ]; then
		echo "  ✗ Could not determine imported disk name for template ${TPROD}"
		echo "     Try: STORAGE=local-lvm ./template-generate.sh"
		qm destroy ${TPROD} --destroy-unreferenced-disks 1 2>/dev/null
		rm -f "$TMPISO"
		return 1
	fi

	echo "  → Configuring template..."
	if ! quiet qm set $TPROD --scsihw virtio-scsi-single --scsi0 "${IMPORTED_DISK}"; then
		echo "  ✗ Could not attach disk to template ${TPROD}"
		qm destroy ${TPROD} --destroy-unreferenced-disks 1 2>/dev/null
		rm -f "$TMPISO"
		return 1
	fi
	if ! quiet qm set $TPROD --ide3 "${STORAGE}":cloudinit; then
		echo "  ✗ Could not create cloud-init disk for template ${TPROD}"
		qm destroy ${TPROD} --destroy-unreferenced-disks 1 2>/dev/null
		rm -f "$TMPISO"
		return 1
	fi
	quiet qm set $TPROD --boot c --bootdisk scsi0 || {
		echo "  ✗ Error setting boot"
		return 1
	}
	quiet qm set $TPROD --serial0 socket --vga std || {
		echo "  ✗ Error setting serial"
		return 1
	}
	quiet qm set $TPROD --agent enabled=1 || {
		echo "  ✗ Error setting agent"
		return 1
	}
	quiet qm set $TPROD --tag "template,${LCNAME}" || {
		echo "  ✗ Error setting tags"
		return 1
	}
	quiet qm set $TPROD --ciupgrade 0 || {
		echo "  ✗ Error setting ciupgrade"
		return 1
	}
	quiet qm set $TPROD --ipconfig0 ip=dhcp || {
		echo "  ✗ Error setting network"
		return 1
	}

	echo "  → Converting to template..."
	quiet qm template $TPROD || {
		echo "  ✗ Failed to convert VM ${TPROD} to template"
		return 1
	}

	echo "  ✓ Successfully created template ${TPROD}"
	rm "$TMPISO"

}

# Main execution - sequential processing

# One run at a time. Two runs share BASEDIR and the same VMIDs, so an
# overlapping run can destroy the other's template or its working copy.
exec 9>"${BASEDIR}/.goodmountain.lock"
if ! flock -n 9; then
	echo "Another template-generate.sh run holds ${BASEDIR}/.goodmountain.lock; not starting." >&2
	exit 1
fi

echo "Starting template generation..."

# Check prerequisites before starting
check_prerequisites

ROWS=$(grep -Ev "^[[:space:]]*#" "$TEMPLATES" | grep -v "^[[:space:]]*$" | grep -v "Name,Version")
FAILED=""

# What to build, one "INSTANCE|SUFFIX|CSV row" per line. Without TARGETS that's
# every row at INSTANCE. With TARGETS it's only the rows named, each at the
# VMID given: its instance is what the VMID adds to the row's base ID, and a
# non-zero instance n is named -v<n+1>, so 12501 is template-Ubuntu-2404-v2.
if [ -z "$TARGETS" ]; then
	JOBS=$(printf '%s\n' "$ROWS" | sed "s/^/${INSTANCE_NUM}|${NAME_SUFFIX}|/")
else
	JOBS=""
	for target in $TARGETS; do
		key=${target%%=*}
		vmid=${target#*=}
		row=$(printf '%s\n' "$ROWS" | awk -F, -v k="$key" 'tolower($1) "-" $2 == k')
		case "$vmid" in
		"" | *[!0-9]*)
			echo "  ✗ Target '${target}' needs a VMID, as in ubuntu-2404=12501"
			FAILED="${FAILED} ${key}"
			continue
			;;
		esac
		if [ -z "$row" ] || [ "$key" = "$target" ]; then
			echo "  ✗ Target ${key} has no row in ${TEMPLATES}"
			FAILED="${FAILED} ${key}"
			continue
		fi
		base=$(calculate_base_id "$(echo "$row" | awk -F, '{print $1}')" "$(echo "$row" | awk -F, '{print $2}')")
		inst=$((vmid - base * 10))
		if [ "$inst" -lt 0 ] || [ "$inst" -gt 99 ]; then
			echo "  ✗ Target ${key}=${vmid}: ${key} builds at ${base}00 to ${base}99, not ${vmid}"
			FAILED="${FAILED} ${key}"
			continue
		fi
		suffix=""
		[ "$inst" -ne 0 ] && suffix="-v$((inst + 1))"
		JOBS="${JOBS}${inst}|${suffix}|${row}
"
	done
fi
JOBS=$(printf '%s\n' "$JOBS" | grep -v '^$')

TEMPLATE_COUNT=0
TOTAL_TEMPLATES=$(printf '%s\n' "$JOBS" | grep -c .)
echo "Processing $TOTAL_TEMPLATES templates sequentially"

# Process templates one by one. The loop reads a here-document rather than a
# pipe so it runs in this shell and FAILED survives it, and each template's
# commands read /dev/null so none of them can eat the rest of the list.
while IFS='|' read -r JOB_INST JOB_SUFFIX LINE; do
	[ -n "$LINE" ] || continue
	TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
	echo ""
	echo "=== [$TEMPLATE_COUNT/$TOTAL_TEMPLATES] Processing: $(echo "$LINE" | awk -F, '{print $1" "$2}') ==="
	TMPISO=""
	WORK=""
	if ! process_template "$LINE" "$JOB_INST" "$JOB_SUFFIX" </dev/null; then
		FAILED="${FAILED} $(echo "$LINE" | awk -F, '{print $1"-"$2}')"
	fi
	# Remove this template's working copy whatever the outcome. Only this one:
	# a glob here once deleted another run's copy mid-import.
	[ -n "$TMPISO" ] && rm -f "$TMPISO" "${TMPISO}.log"
	[ -n "$WORK" ] && rm -rf "$WORK"
done <<EOF_JOBS
$JOBS
EOF_JOBS

echo ""
if [ -n "$FAILED" ]; then
	echo "Template generation FAILED for:${FAILED}" >&2
	exit 1
fi
echo "Template generation completed!"
