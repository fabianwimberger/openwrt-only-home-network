.PHONY: flash-all flash-all-dry flash bench check

# Flash order: the leaf repeaters one at a time (each verified before the next), then both wired
# APs together so clients are not pushed back and forth between a half-flashed pair.
flash-all:
	tools/flash.sh garden
	tools/flash.sh heatpump
	tools/flash.sh door
	tools/flash.sh --parallel ap-upper ap-main

flash-all-dry:
	tools/flash.sh --dry-run garden heatpump door ap-upper ap-main

flash:
	@test -n "$(NODE)" || { echo "usage: make flash NODE=<garden|heatpump|door|ap-upper|ap-main>"; exit 1; }
	tools/flash.sh $(NODE)

bench:
	bench/bench.sh --quick --phy

check:
	for f in bench/*.sh tools/*.sh wired-ap/*.sh wireless-repeater/*.sh; do bash -n "$$f" || exit 1; done
