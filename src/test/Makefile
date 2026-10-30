all: test

test: test_snapshot test_cfg_to_cmd test_cfg_to_cmd_aarch64 test_pci_addr_conflicts test_pci_reservation test_qemu_img_convert test_migration test_restore_config test_parse_config test_nvme test_usbdisk test_emmc test_sdcard test_custom_machine test_vfio_display test_display_types

test_snapshot: run_snapshot_tests.pl
	./run_snapshot_tests.pl
	./test_get_replicatable_volumes.pl

test_cfg_to_cmd: run_config2command_tests.pl cfg2cmd/*.conf
	perl -I../ ./run_config2command_tests.pl

test_cfg_to_cmd_aarch64: run_config2command_tests.pl cfg2cmd/aarch64/*.conf
	perl -I../ ./run_config2command_tests.pl cfg2cmd/aarch64

test_qemu_img_convert: run_qemu_img_convert_tests.pl
	perl -I../ ./run_qemu_img_convert_tests.pl

test_pci_addr_conflicts: run_pci_addr_checks.pl
	./run_pci_addr_checks.pl

test_pci_reservation: run_pci_reservation_tests.pl
	./run_pci_reservation_tests.pl

MIGRATION_TEST_TARGETS := $(addprefix test_migration_,$(shell perl -ne 'print "$$1 " if /^\s*name\s*=>\s*["'\'']([^\s"'\'']+)["'\'']\s*,\s*$$/; END { print "\n" }' run_qemu_migrate_tests.pl))

test_migration: run_qemu_migrate_tests.pl MigrationTest/*.pm $(MIGRATION_TEST_TARGETS)

$(MIGRATION_TEST_TARGETS):
	./run_qemu_migrate_tests.pl $(@:test_migration_%=%)

test_restore_config: run_qemu_restore_config_tests.pl
	./run_qemu_restore_config_tests.pl

test_parse_config: run_parse_config_tests.pl
	./run_parse_config_tests.pl

test_nvme: run_nvme_tests.pl run_nvme_feature_tests.pl run_nvme_lifecycle_tests.pl run_nvme_update_tests.pl run_nvme_pi_tests.pl
	perl -I../ ./run_nvme_tests.pl
	perl -I../ ./run_nvme_feature_tests.pl
	perl -I../ ./run_nvme_lifecycle_tests.pl
	perl -I../ ./run_nvme_update_tests.pl
	perl -I../ ./run_nvme_pi_tests.pl

test_usbdisk: run_usbdisk_tests.pl
	perl -I../ ./run_usbdisk_tests.pl

test_emmc: run_emmc_tests.pl run_emmc_lifecycle_tests.pl
	perl -I../ ./run_emmc_tests.pl
	perl -I../ ./run_emmc_lifecycle_tests.pl

test_sdcard: run_sdcard_tests.pl run_sdcard_lifecycle_tests.pl
	perl -I../ ./run_sdcard_tests.pl
	perl -I../ ./run_sdcard_lifecycle_tests.pl

test_custom_machine: run_custom_machine_tests.pl
	perl -I../ ./run_custom_machine_tests.pl

test_vfio_display: run_vfio_display_tests.pl
	perl -I../ ./run_vfio_display_tests.pl

test_display_types: run_display_tests.pl
	perl -I../ ./run_display_tests.pl

.PHONY: clean
clean:
	rm -rf MigrationTest/run parse-config-output
