#!/bin/sh

# Template cleanup script - destroys Linux templates but preserves Windows templates
# Keeps manually managed Terraform configuration files

echo "Cleaning up Linux templates (preserving Windows templates)..."

# Linux templates only. The leading VMID digit is the kernel (1 Linux, 2
# Windows), so Windows templates sit at 20000 and above. Match on the
# template- name prefix rather than grepping the whole line, so a VM that just
# happens to have "template" somewhere in its row is left alone.
TEMPLATES_TO_DESTROY=$(qm list | awk '$1 ~ /^[0-9]+$/ && $1 < 20000 && $2 ~ /^template-/ {print $1}')

if [ -z "$TEMPLATES_TO_DESTROY" ]; then
	echo "No Linux templates found to destroy."
else
	echo "Found templates to destroy: $TEMPLATES_TO_DESTROY"
	echo "Destroying templates..."

	for template_id in $TEMPLATES_TO_DESTROY; do
		echo "Destroying template $template_id..."
		if qm destroy "$template_id" --destroy-unreferenced-disks 1 --purge 2>/dev/null; then
			echo "✓ Successfully destroyed template $template_id"
		else
			echo "✗ Failed to destroy template $template_id"
			# Try alternative cleanup for stuck templates
			echo "  Attempting alternative cleanup..."
			qm template "$template_id" --disk scsi0 2>/dev/null || true
			qm destroy "$template_id" --purge 2>/dev/null || echo "  Manual cleanup may be required"
		fi
	done
fi

echo "Template cleanup completed!"
echo ""
echo "Run './template-generate.sh' to recreate templates with consistent numbering."
