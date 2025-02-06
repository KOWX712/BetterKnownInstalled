#!/system/bin/busybox sh

enforce_install_from_app() {
  if [ ! "$BOOTMODE" ]; then
    ui_print "****************************************************"
    ui_print "! Install from Recovery is NOT supported !"
    ui_print "! Please install from Magisk / KernelSU / APatch !"
    abort "****************************************************"
  fi
}

enforce_install_from_app

ui_print "- Restart your device to confirm changes."
