#!/system/bin/busybox sh

# MODPATH is already defined in post-fs-data.sh
TOOL_PATH="$MODPATH/common/addon/abx/tools"

# Determine architecture
current_arch=$(get_arch)
get_arch_status=$?

if [ $get_arch_status -ne 0 ]; then
  exit 1 # Exit if get_arch failed
fi

# Check if binaries exist in the determined path
if [ ! -f "$TOOL_PATH/abx2xml-$current_arch" ] || [ ! -f "$TOOL_PATH/xml2abx-$current_arch" ]; then
  ui_print "Error: Binaries for $current_arch not found in $TOOL_PATH"
  exit 1
fi

# Prepend the architecture-specific bin directory to PATH
export PATH="$TOOL_PATH:$PATH"

# Rename the right binaries arch to abx2xml and xml2abx
ln -sf "$TOOL_PATH/abx2xml-$current_arch" "$TOOL_PATH/abx2xml"
ln -sf "$TOOL_PATH/xml2abx-$current_arch" "$TOOL_PATH/xml2abx"

ui_print "Successfully installed abx tools for $current_arch."
ui_print "Credit: rhythmcache/android-xml-converter for the binaries."
