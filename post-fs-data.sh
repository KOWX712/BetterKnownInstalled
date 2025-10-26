#!/system/bin/busybox sh

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
WARNINGS_XML="/data/system/packages-warnings.xml"
BACKUP_DIR="$MODPATH/backup" # Directory to store backups
MAX_BACKUP_FILES=4           # Maximum number of backup files to keep per type
CURRENT_TIMESTAMP=$(date +%s)

# If MODPATH is empty or is not default modules path, use current path
[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
  MODPATH="$(dirname "$(readlink -f "$0")")"

# Using util_functions.sh
[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

# Check if /data is mounted and accessible
wait_for_data() {
  max_wait_time=30 # Maximum time to wait in seconds
  wait_interval=1  # Seconds to wait between checks

  i=0
  while [ "$i" -lt "$max_wait_time" ]; do
    if mount | grep -q "/data " && [ -f "$PACKAGES_XML" ]; then
      ui_print "/data is mounted and accessible."
      return 0
    fi
    ui_print "Waiting for /data to become accessible..."
    sleep "$wait_interval"
    i=$((i + wait_interval))
  done

  ui_print "Error: /data or $PACKAGES_XML did not become accessible within $max_wait_time seconds."
  return 1
}

process_xml() {
  xml_file="$1"
  base_name=$(basename "$xml_file")
  base_name_no_ext="${base_name%.*}"

  xml_temp="$MODPATH/temp_${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
  xml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
  abxml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.abxml"

  ui_print "Starting to process XML file: $xml_file"

  # Create backup *before* any modifications
  ui_print "Creating backup of $xml_file..."
  backup_file_path=$(backup_file "$xml_file" "bak")
  backup_status=$?

  if [ $backup_status -eq 0 ]; then
    ui_print "Backup file path: $backup_file_path"
    abxml_original_backup_file="$backup_file_path"
  else
    ui_print "Error: backup_file failed."
    return 1
  fi

  # Determine the file type early on
  file_type=$(file -b "$abxml_original_backup_file")
  is_text_xml=false
  if echo "$file_type" | grep -q -E "XML .* text|text"; then
    is_text_xml=true
  fi

  # Log original backup file type
  ui_print "abxml_original_backup_file is: Text XML"

  # Convert to text XML if necessary
  if boolval "$is_text_xml"; then
    ui_print "File is already text XML. Proceeding with modifications."
    cp "$abxml_original_backup_file" "$xml_temp"
  else
    ui_print "Converting ABX to text: $abxml_original_backup_file -> $xml_temp"
    if ! abx_to_text "$abxml_original_backup_file" "$xml_temp"; then
      ui_print "Error: abx_to_text failed!"
      cat "$abxml_original_backup_file" >"$MODPATH/abx_to_text_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.abx"
      rm "$xml_temp" 2>/dev/null
      return 1
    fi
  fi

  # Check if the file is packages-warnings.xml
  if [ "$xml_file" = "$WARNINGS_XML" ]; then
    ui_print "Processing $WARNINGS_XML: Setting content to '<packages />' (empty)."

    # Set content of packages-warnings.xml to be empty packages
    echo "<packages />" >"$xml_temp"

    ui_print "Content of $WARNINGS_XML set to '<packages />'."
  else
    # Get the userId of com.android.vending from packages.xml
    ui_print "Finding userId for com.android.vending in $xml_temp..."
    vending_uid=$(sed -n -E '/<package / {
    /name="com\.android\.vending"/ {
      s/.*userId="([^"]*)".*/\1/p
      q
    }
  }' "$xml_temp")

    if [ -z "$vending_uid" ]; then
      ui_print "Error: Could not find userId for com.android.vending in $xml_temp"
      rm "$xml_temp"
      return 1
    else
      ui_print "Found userId for com.android.vending: $vending_uid"
    fi

    # Check if type is specified in XML
    type="$(grep -q ".*-bool=" "$xml_temp" && echo "-bool" || echo "")"

    # Modify XML
    ui_print "Starting to modify XML..."

    # Only modify if the package has installer attribute, revert changes to system app
    awk -v VENDING_UID="$vending_uid" -v TYPE="$type" '
        BEGIN {
            RS="</package>"
            ORS=""
        }
        {
            if ($0 ~ /<package /) {
                # 1: Handle installer attributes
                if ($0 ~ /installer=/) {
                    gsub(/installer="[^"]*"/, "installer=\"com.android.vending\"")
                    gsub(/installInitiator="[^"]*"/, "installInitiator=\"com.android.vending\"")
                    gsub(/installerUid-int="[^"]*"/, "installerUid-int=\"" VENDING_UID "\"")
                    gsub(/installerUid="[^"]*"/, "installerUid=\"" VENDING_UID "\"")
                    gsub(/[ \r\n\t]+installOriginator="[^"]*"/, "")
                    gsub(/[ \r\n\t]+isOrphaned-bool="true"/, "")
                    gsub(/[ \r\n\t]+isOrphaned="true"/, "")
                    gsub(/[ \r\n\t]+installInitiatorUninstalled-bool="true"/, "")
                    gsub(/[ \r\n\t]+installInitiatorUninstalled="true"/, "")
                    gsub(/packageSource-int="[^"]*"/, "packageSource-int=\"2\"")
                    gsub(/packageSource="[^"]*"/, "packageSource=\"2\"")
                }
                # 2: Revert changes to system apps
                if ($0 !~ /codePath=\"\/data\/app\//) {
                    gsub(/[ \r\n\t]+installer=\"[^\"]*\"/, "")
                    gsub(/[ \r\n\t]+installInitiator=\"[^\"]*\"/, "")
                    gsub(/[ \r\n\t]+installerUid-int=\"[^\"]*\"/, "")
                    gsub(/[ \r\n\t]+installerUid=\"[^\"]*\"/, "")
                    gsub(/[ \r\n\t]+installOriginator=\"[^\"]*\"/, "")
                    if ($0 !~ /isOrphaned/) {
                        sub(/<package /, "<package isOrphaned" TYPE "=\"true\" ")
                    }
                }
                printf "%s</package>", $0
            } else {
                # header or footer of the XML file.
                printf "%s", $0
            }
        }
    ' "$xml_temp" > "$xml_temp.tmp" && mv "$xml_temp.tmp" "$xml_temp"
  fi

  # Rotate backups
  ui_print "Rotating backups..."
  rotate_files "${base_name_no_ext}_*.xml" "$MAX_BACKUP_FILES"
  rotate_files "${base_name_no_ext}_*.abxml" "$MAX_BACKUP_FILES"

  # Replace and verify based on original file type
  if boolval "$is_text_xml"; then
    # It was originally a text XML file
    ui_print "Original file was text XML. Replacing with modified text XML."
    cp "$xml_temp" "$xml_backup_file" # Backup modified text XML
    replacement_source="$xml_backup_file"
  else
    # It was originally an ABX file
    ui_print "Original file was ABX. Converting text to ABX before replacing."
    text_to_abx "$xml_temp" "$abxml_backup_file" # Convert modified text to ABX
    replacement_source="$abxml_backup_file"
  fi

  # Replace and verify
  ui_print "Replacing original file: $xml_file <- $replacement_source"
  if ! cp -f "$replacement_source" "$xml_file"; then
    ui_print "Error: Failed to copy modified file. Permissions issue?"
    rm "$xml_temp" 2>/dev/null
    return 1
  fi

  ui_print "Verifying replacement: $xml_file vs $replacement_source"
  if ! cmp -s "$xml_file" "$replacement_source"; then
    ui_print "Error: Verification failed after replacement!"
    diff -u "$xml_file" "$replacement_source" >"$MODPATH/diff_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.diff"
    rm "$xml_temp" 2>/dev/null
    return 1
  fi

  ui_print "Cleaning up temporary files..."
  rm "$xml_temp" 2>/dev/null

  ui_print "Successfully processed XML file: $xml_file"
  return 0
}

# Check for required commands and use included binaries if necessary
if ! command_exists abx2xml || ! command_exists xml2abx; then
  ui_print "Error: abx2xml and xml2abx are required. Installing from addons..."

  # Running addons
  for addon in "$MODPATH"/common/addon/*/install.sh; do
    if [ -f "$addon" ]; then
      addon_basedirname=$(basename "$(dirname "$addon")")
      ui_print "Running $addon_basedirname addon..."
      . "$addon"
      if [ $? -ne 0 ]; then
        ui_print "Error: Addon $addon_basedirname failed to install."
        exit 1
      fi
    fi
  done

  # Check again if the commands exist after running addons
  if ! command_exists abx2xml || ! command_exists xml2abx; then
    ui_print "Error: abx2xml and xml2abx are still missing after running addons."
    exit 1
  fi
fi

# Wait for /data to become mounted and accessible
wait_for_data

# Process packages.xml
if [ -f "$PACKAGES_XML" ]; then
  ui_print "Processing $PACKAGES_XML..."
  process_xml "$PACKAGES_XML"
fi

# Process packages-warnings.xml
if [ -f "$WARNINGS_XML" ]; then
  ui_print "Processing $WARNINGS_XML..."
  process_xml "$WARNINGS_XML"
fi

# Restore permissions and SELinux context (if applicable)
ui_print "Restoring permissions and SELinux context..."
for file in "$PACKAGES_XML" "$WARNINGS_XML"; do
  [ -f "$file" ] || continue
  chown system:system "$file"
  chmod 640 "$file"
  if command_exists restorecon; then
    restorecon "$file"
  fi
done

ui_print "----------------------------------------"
ui_print "Process completed successfully."
ui_print "Original and modified files backed up to: $BACKUP_DIR"
ui_print "It is recommended to reboot your device for changes to take effect."
ui_print "by @T3SL4"
ui_print "----------------------------------------"
