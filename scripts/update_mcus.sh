#!/bin/bash
# Rebuild and reflash all 3 Trident MCUs (Leviathan, Nitehawk-SB, Therm2)
# against whatever Kalico source is currently checked out at ~/klipper.
#
# Run this AFTER updating Kalico itself (e.g. via Mainsail's update_manager
# or `git -C ~/klipper pull`), never before.
#
# Therm2 has no working software DFU trigger, so this script will pause
# and wait for you to physically enter DFU mode on it (hold BOOT while
# plugging in USB - NOT the RESET button).
#
# Usage: ~/printer_data/scripts/update_mcus.sh

set -uo pipefail

KLIPPER=~/klipper
KATAPULT="$HOME/katapult-env/bin/python3 $HOME/katapult/scripts/flashtool.py"
LOG() { echo; echo "==> $*"; }
FAIL() { echo "FAILED: $*" >&2; exit 1; }

# --- Safety: refuse to run mid-print ---
STATE=$(curl -s http://localhost:7125/printer/objects/query?print_stats \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['print_stats']['state'])" 2>/dev/null)
if [ "$STATE" = "printing" ] || [ "$STATE" = "paused" ]; then
    FAIL "printer is currently '$STATE' - refusing to touch MCUs mid-print"
fi

LOG "Stopping klipper service"
sudo systemctl stop klipper

build_firmware() {
    # Writes .config from stdin, runs olddefconfig + clean + build,
    # verifies out/klipper.bin was actually produced.
    cd "$KLIPPER" || FAIL "cannot cd to $KLIPPER"
    cat > .config
    make olddefconfig >/tmp/mcu_build.log 2>&1 || { cat /tmp/mcu_build.log; FAIL "olddefconfig failed"; }
    make clean >>/tmp/mcu_build.log 2>&1
    make -j4 >>/tmp/mcu_build.log 2>&1
    if [ ! -f out/klipper.bin ]; then
        tail -40 /tmp/mcu_build.log
        FAIL "build did not produce out/klipper.bin (see /tmp/mcu_build.log) - if this is a flash-size overflow on Therm2, trim more WANT_* options in this script's Therm2 config block"
    fi
}

######################################################################
# 1. Leviathan mainboard - UART, Katapult
######################################################################
LOG "Building Leviathan firmware"
build_firmware <<'EOF'
CONFIG_LOW_LEVEL_OPTIONS=y
CONFIG_MACH_STM32=y
CONFIG_MACH_STM32F446=y
CONFIG_STM32_FLASH_START_8000=y
CONFIG_STM32_CLOCK_REF_12M=y
CONFIG_STM32_SERIAL_USART1=y
EOF

LOG "Requesting Katapult bootloader on Leviathan (/dev/ttyAMA0)"
eval $KATAPULT -r -d /dev/ttyAMA0 -b 250000 || FAIL "bootloader request failed on Leviathan"
sleep 2
LOG "Flashing Leviathan"
eval $KATAPULT -d /dev/ttyAMA0 -b 250000 -f "$KLIPPER/out/klipper.bin" || FAIL "flash failed on Leviathan"

######################################################################
# 2. Nitehawk-SB toolhead - USB, Katapult
######################################################################
LOG "Building Nitehawk-SB firmware"
build_firmware <<'EOF'
CONFIG_MACH_RPXXXX=y
CONFIG_MACH_RP2040=y
CONFIG_RPXXXX_FLASH_START_4000=y
CONFIG_RPXXXX_USB=y
EOF

NH_DEV=$(ls /dev/serial/by-id/ 2>/dev/null | grep "^usb-Klipper_rp2040_" | head -1)
if [ -z "$NH_DEV" ]; then
    FAIL "Nitehawk-SB not found in Klipper mode (no usb-Klipper_rp2040_* device) - is it plugged in?"
fi
LOG "Requesting Katapult bootloader on Nitehawk-SB ($NH_DEV)"
eval $KATAPULT -r -d "/dev/serial/by-id/$NH_DEV" || FAIL "bootloader request failed on Nitehawk-SB"
sleep 2
KAT_DEV=$(ls /dev/serial/by-id/ 2>/dev/null | grep "^usb-katapult_rp2040_" | head -1)
if [ -z "$KAT_DEV" ]; then
    FAIL "Nitehawk-SB did not re-enumerate in bootloader mode (no usb-katapult_rp2040_* device)"
fi
LOG "Flashing Nitehawk-SB ($KAT_DEV)"
eval $KATAPULT -d "/dev/serial/by-id/$KAT_DEV" -f "$KLIPPER/out/klipper.bin" || FAIL "flash failed on Nitehawk-SB"

######################################################################
# 3. Therm2 expander - USB, STM32 DFU (no software trigger available)
######################################################################
LOG "Building Therm2 firmware (trimmed - thermistor-only board, small 32KB flash)"
build_firmware <<'EOF'
CONFIG_LOW_LEVEL_OPTIONS=y
CONFIG_MACH_STM32=y
CONFIG_MACH_STM32F042=y
CONFIG_STM32_FLASH_START_0000=y
CONFIG_STM32_CLOCK_REF_12M=y
CONFIG_STM32_USB_PA11_PA12_REMAP=y
# CONFIG_WANT_SOFTWARE_SPI is not set
# CONFIG_WANT_SOFTWARE_I2C is not set
# CONFIG_WANT_HARD_PWM is not set
# CONFIG_WANT_TMCUART is not set
# CONFIG_WANT_NEOPIXEL is not set
# CONFIG_WANT_PULSE_COUNTER is not set
# CONFIG_WANT_ST7920 is not set
# CONFIG_WANT_HD44780 is not set
# CONFIG_WANT_ADXL345 is not set
# CONFIG_WANT_LIS2DW is not set
# CONFIG_WANT_MPU9250 is not set
# CONFIG_WANT_ICM20948 is not set
# CONFIG_WANT_THERMOCOUPLE is not set
# CONFIG_WANT_HX71X is not set
# CONFIG_WANT_ADS1220 is not set
# CONFIG_WANT_ADS131M0X is not set
# CONFIG_WANT_LDC1612 is not set
# CONFIG_WANT_SENSOR_ANGLE is not set
# CONFIG_WANT_GPIO_SPI is not set
# CONFIG_WANT_GPIO_I2C is not set
EOF
grep -A2 "^Memory region" /tmp/mcu_build.log | head -6

echo
echo "########################################################"
echo "  Therm2 needs manual DFU entry (no software trigger):"
echo "   1. Unplug Therm2's USB cable"
echo "   2. Hold down the BOOT button (NOT reset!)"
echo "   3. Plug USB back in while still holding BOOT"
echo "   4. Keep holding ~2-3 seconds, then release"
echo "########################################################"
echo "Waiting for DFU device (0483:df11)... Ctrl+C to abort."
until lsusb | grep -q "0483:df11"; do
    sleep 1
done
LOG "DFU device detected - flashing Therm2"
cd "$KLIPPER" || FAIL "cannot cd to $KLIPPER"
DFU_OUTPUT=$(make flash FLASH_DEVICE=0483:df11 2>&1)
echo "$DFU_OUTPUT"
if ! echo "$DFU_OUTPUT" | grep -q "File downloaded successfully"; then
    FAIL "Therm2 flash did not report a successful download - check output above"
fi
LOG "Therm2 flash succeeded (ignore any 'can't detach' error above - that part is cosmetic)"

######################################################################
# Restart and verify
######################################################################
LOG "Restarting klipper"
sudo systemctl start klipper
sleep 8

LOG "Final MCU firmware versions:"
grep "Loaded MCU " ~/printer_data/logs/klippy.log | tail -4

PSTATE=$(curl -s http://localhost:7125/printer/info | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['state'])" 2>/dev/null)
echo
echo "Printer state: $PSTATE"
if [ "$PSTATE" != "ready" ]; then
    FAIL "printer did not come back ready - check ~/printer_data/logs/klippy.log"
fi
LOG "All 3 MCUs updated successfully."
