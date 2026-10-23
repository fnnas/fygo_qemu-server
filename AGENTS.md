# Repository guidance

Keep this file focused on repository-wide workflow and conventions. Document individual features in code, tests, and the relevant product documentation.

## Layout

- This is a customized Proxmox VE `qemu-server` backend, primarily Perl. The web UI lives in a separate `pve-manager` repository.
- `src/PVE/API2/` defines REST endpoints; `src/PVE/CLI/` and `src/bin/` provide commands such as `qm`.
- `src/PVE/QemuServer.pm` orchestrates VM configuration and lifecycle; `src/PVE/QemuServer/` contains device, block storage, PCI, monitor, and machine helpers.
- `src/PVE/QemuConfig.pm`, `src/PVE/QemuMigrate*`, and `src/PVE/VZDump/` handle configuration, migration, and backups.
- `src/test/` contains regression tests and fixtures. `src/qmeventd/` and `src/query-machine-capabilities/` contain C helpers; `debian/` contains packaging metadata.

## Build and validation

Keep the existing package version when building or rebuilding packages. Change version numbers or add version suffixes only when the user explicitly requests it; a request for a new `.deb` does not authorize a version change.

Run commands below from the repository root in Linux, WSL, or an isolated Proxmox container. Use `debian/control` as the source of truth for dependencies and version requirements; ordinary Perl installations lack the required PVE modules. Tests use `Test::More` and `Test::MockModule`.

For Proxmox dependencies, try `makedie/proxmox_ve` with a tag matching the current build requirements. Check its installed packages against `debian/control` and install missing build/test tools inside the container as needed.

The image defaults to a systemd entrypoint. Override it with `/bin/bash` for build/test use. Set `PVE_IMAGE_TAG` to the selected tag, then run `docker run --rm -it --entrypoint /bin/bash "makedie/proxmox_ve:${PVE_IMAGE_TAG}"`.

```sh
make -C src test                         # Complete tests, including CLI API validation
make deb                                # Debian packages, followed by lintian
```

- The root default `make` target does not build or test anything. Packaging reuses a versioned source copy; use a fresh `BUILDDIR` when rebuilding changed sources.
- For C changes, build the affected helper using its own Makefile.
- Select focused tests from `src/test/Makefile` and follow the relevant test documentation. Run the complete suite for shared or cross-module changes; documentation-only changes need a diff review, not runtime tests.
- Review generated or updated expected outputs and rerun the affected tests. Do not regenerate baselines merely to accommodate the local environment; report mocked conditions separately from actual execution results.
- When preparing Linux/WSL test copies from Windows, use LF line endings and preserve Git executable modes.

## Code conventions

- Inspect `git status` first and preserve unrelated modifications and untracked files. Keep generated packages, binaries, temporary test environments, and test output out of commits.
- Match surrounding Perl style: four-space indentation and `strict`/`warnings` or the file's existing version declaration. Use `proxmox-perltidy` on changed Perl files when available; root `make tidy` reformats the entire repository.
- Preserve existing interfaces, configuration compatibility, and supported-platform behavior. Review affected callers and tests when changing shared code.
- Add regression coverage for behavior changes using the existing harnesses. Mock cluster, storage, and monitor side effects so tests do not operate on live VMs.

## Commit message conventions

- Use a Chinese subject in `<type>: <中文改动摘要>` form, choosing a type such as `feat`, `fix`, or `docs` for the change. After a blank line, add a brief Chinese overview of the resulting behavior and reason for the change.
- Describe every changed file, including tests and documentation: put its repository-relative path on its own line, followed by bullets in the form `- <改动主题> 新增/修改/修复/删除：<具体变化>`; select the appropriate change verb.
- Omit `Signed-off-by:` trailers and do not use `git commit -s` or `--signoff`.
- Keep the commit message focused on changes. Put validation results in the report or PR, without a separate validation section in the commit message.
