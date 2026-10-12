#!/usr/bin/env python3
"""Link the package-action fixture with the existing native APT objects.

Cydia uses private APT APIs hidden from the native shared library. Reuse the
same built objects and dependency libraries rather than changing visibility
or building a second version of APT for this test.
"""
import os
import pathlib
import re
import shlex
import subprocess


def main():
    project = pathlib.Path(__file__).resolve().parent.parent
    build = pathlib.Path(os.environ["APT_INTEGRATION_TESTS_BUILD_DIR"]).resolve()
    commands = subprocess.check_output(
        ["ninja", "-C", str(build), "-t", "commands", "apt-pkg"], text=True
    ).splitlines()
    link = next(shlex.split(line) for line in reversed(commands) if " -shared " in line)
    start = link.index("-shared") + 1
    end = link.index("&&", start) if "&&" in link[start:] else len(link)
    link = link[start:end]
    inputs = [token for index, token in enumerate(link) if (index == 0 or link[index - 1] != "-o") and
              (token.endswith(".o") or
              token.startswith(("-l", "-L")) or re.search(r"\.(?:a|so)(?:\.\d+)*$", token))]
    assert any(token.endswith(".o") for token in inputs), "Native APT object files were not found"
    sources = ["tests/AptBackendPolicyTests.cpp", "Cydia/AptBackend.cpp",
               "Cydia/AptBackendOperations.cpp", "Cydia/AptAuthorizedArchives.cpp", "Cydia/RepositoryArchiveAuthorization.cpp",
               "Cydia/AptCompatibility.cpp", "Cydia/AptProviderValues.cpp",
               "Cydia/AptVersionPolicy.cpp", "Cydia/PackageIdentity.cpp",
               "Cydia/PackageArchivePolicy.cpp", "Cydia/PackageArchiveReader.cpp",
               "Cydia/RepositorySecurityPolicy.cpp"]
    def compile_driver(driver_sources, name, sanitize=False, extra_link_flags=(), extra_compile_flags=()):
        command = shlex.split(os.environ.get("CXX", "c++")) + ["-std=c++17", "-g"]
        if sanitize:
            command += ["-fsanitize=address", "-fno-omit-frame-pointer"]
        command += list(extra_compile_flags)
        command += ["-Wall", "-Wextra", "-I" + str(project),
                    "-I" + str(build / "include"), "-I" + str(project / "apt64")]
        command += [str(project / source) for source in driver_sources] + inputs + list(extra_link_flags) + [
            "-pthread", "-o", str(build / name)]
        subprocess.run(command, cwd=build, check=True)

    compile_driver(sources, "cydia-package-actions", sanitize=True)
    compile_driver(["tests/AptBackendRecoveryTests.cpp"] + sources[1:] + [
                    "Cydia/AptNativeBackend.cpp", "Cydia/AptBackendRecovery.cpp",
                    "Cydia/AptRecoveryPackageManager.cpp", "Cydia/SourcePreflight.cpp",
                    "Cydia/KeyringImport.cpp", "Cydia/SourceDocumentCommit.cpp",
                    "Cydia/AptProviderProtocol.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/PackageDatabasePaths.cpp"], "cydia-recovery-backend", sanitize=True)
    compile_driver(["tests/SourcePreflightTests.cpp", "Cydia/SourcePreflight.cpp",
                    "Cydia/KeyringImport.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/SourceDocumentCommit.cpp",
                    "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp", "Cydia/RepositorySecurityPolicy.cpp"],
                   "cydia-source-preflight")
    compile_driver(["tests/PackageArchivePolicyTests.cpp", "Cydia/PackageArchivePolicy.cpp",
                    "Cydia/PackageArchiveReader.cpp"], "cydia-package-archive-reader", sanitize=True,
                   extra_compile_flags=["-DCYDIA_TEST_PACKAGE_ARCHIVE_READER"])
    # Provider admission and archive proof use the same native APT objects;
    # no second APT build, external provider service, or network is involved.
    compile_driver(["tests/AptProviderSelectionTests.cpp",
                    "Cydia/AptProviderSelection.cpp", "Cydia/AptProviderSelectionValues.cpp",
                    "Cydia/AptProviderClient.cpp", "Cydia/AptProviderLaunch.cpp", "Cydia/AptProviderProtocol.cpp",
                    "Cydia/AptProviderValues.cpp", "Cydia/AptRuntimeDescriptor.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp", "Cydia/PackageIdentity.cpp",
                    "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/DpkgRunner.cpp", "Cydia/PackageDatabasePaths.cpp"],
                   "cydia-provider-selection")
    compile_driver(["tests/AptProviderArchiveEvidenceTests.cpp",
                    "Cydia/AptProviderArchiveEvidence.cpp", "Cydia/AptProviderArchiveDecoders.cpp",
                    "Cydia/AptProviderProtocol.cpp", "Cydia/AptProviderValues.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp", "Cydia/PackageIdentity.cpp",
                    "Cydia/PackageArchivePolicy.cpp",
                    "Cydia/PackageArchiveReader.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/PackageDatabasePaths.cpp"],
                   "cydia-provider-archive-evidence", sanitize=True, extra_link_flags=["-lz"])
    compile_driver(["tests/NativeMMapBackingTests.cpp"], "cydia-mmap-backing",
                   extra_link_flags=["-Wl,--wrap=free,--wrap=munmap"])
    compile_driver(["tests/AptWorkerAcquireStatusTests.cpp", "Cydia/AptWorkerAcquireStatus.cpp",
                    "Cydia/AptProviderProtocol.cpp", "Cydia/AptProviderValues.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp", "Cydia/PackageIdentity.cpp"],
                   "cydia-worker-progress")
    compile_driver(["tests/AptRecoveryPackageManagerTests.cpp", "Cydia/AptRecoveryPackageManager.cpp",
                    "Cydia/AptProviderReview.cpp", "Cydia/AptProviderArchiveEvidence.cpp",
                    "Cydia/AptProviderArchiveDecoders.cpp", "Cydia/AptProviderProtocol.cpp",
                    "Cydia/AptProviderValues.cpp", "Cydia/RepositorySecurityPolicy.cpp",
                    "Cydia/PackageIdentity.cpp", "Cydia/PackageArchivePolicy.cpp",
                    "Cydia/PackageArchiveReader.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/PackageDatabasePaths.cpp"], "cydia-recovery-plan", sanitize=True,
                   extra_link_flags=["-lz"])
    compile_driver(["tests/AptRecoveryAuthorityTests.cpp", "Cydia/AptRecoveryAuthority.cpp",
                    "Cydia/AptRecoveryDependencyInspector.cpp", "Cydia/AptRecoveryMachO.cpp",
                    "Cydia/AptRecoveryInstalledAuthority.cpp", "Cydia/AptRecoverySnapshot.cpp",
                    "Cydia/AptRecoveryInitialization.cpp", "Cydia/AptRuntime.cpp", "Cydia/AptRuntimeDescriptor.cpp",
                    "Cydia/AptProviderProtocol.cpp", "Cydia/AptProviderValues.cpp", "Cydia/PackageIdentity.cpp",
                    "Cydia/PrivilegedConfig.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/SourceDocument.cpp",
                    "Cydia/SourceDocumentStore.cpp", "Cydia/SourceDocumentCommit.cpp",
                    "Cydia/DpkgRunner.cpp", "Cydia/PackageDatabasePaths.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp"], "cydia-recovery-authority",
                   extra_compile_flags=["-DCYDIA_RECOVERY_AUTHORITY_TESTING"])
    compile_driver(["tests/AptRecoveryDependencyInspectorTests.cpp", "Cydia/AptRecoveryDependencyInspector.cpp",
                    "Cydia/AptRecoveryMachO.cpp", "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp"],
                   "cydia-recovery-dependencies", extra_compile_flags=["-DCYDIA_RECOVERY_DEPENDENCY_TESTING"])
    compile_driver(["tests/AptRecoveryTrustTests.cpp", "Cydia/AptRecoveryTrust.cpp",
                    "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/SourceDocument.cpp", "Cydia/SourceDocumentStore.cpp", "Cydia/PackageDatabasePaths.cpp",
                    "Cydia/RepositorySecurityPolicy.cpp"],
                   "cydia-recovery-trust")
    worker_sources = sources[1:] + [
        "Cydia/AptNativeBackend.cpp", "Cydia/AptBackendRecovery.cpp", "Cydia/AptRecoveryPackageManager.cpp",
        "Cydia/SourcePreflight.cpp", "Cydia/KeyringImport.cpp", "Cydia/SourceDocument.cpp",
        "Cydia/SourceDocumentStore.cpp", "Cydia/SourceDocumentCommit.cpp", "Cydia/AptRuntime.cpp",
        "Cydia/AptRuntimeDescriptor.cpp", "Cydia/AptRecoveryInitialization.cpp", "Cydia/AptRecoverySnapshot.cpp",
        "Cydia/PrivilegedConfig.cpp", "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp",
        "Cydia/DpkgRunner.cpp", "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/AptProviderProtocol.cpp",
        "Cydia/AptProviderServer.cpp", "Cydia/AptProviderServerTransport.cpp", "Cydia/AptWorkerAcquireStatus.cpp",
        "Cydia/AptProviderArchiveAuthorization.cpp", "Cydia/AptRecoveryTrust.cpp", "Cydia/AptRecoveryWorker.cpp",
        "Cydia/AptProviderDpkgState.cpp", "Cydia/ExtendedState.cpp", "Cydia/AptMessages.cpp"]
    compile_driver(["tests/AptRecoveryWorkerTests.cpp"] + worker_sources, "cydia-recovery-worker",
                   sanitize=True, extra_link_flags=["-lz", "-ldl"])
    # The same APT objects back snapshot hashing. fakeroot exercises the real
    # protected-file boundary while keeping every mutation in a disposable root.
    compile_driver(["tests/NativeRuntimeStateTests.cpp", "Cydia/RuntimeState.cpp",
                    "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/ExtendedState.cpp",
                    "Cydia/SourceDocument.cpp", "Cydia/SourceDocumentStore.cpp",
                    "Cydia/SourceDocumentCommit.cpp", "Cydia/PrivilegedRuntime.cpp",
                    "Cydia/DpkgRunner.cpp", "Cydia/PackageDatabasePaths.cpp"],
                   "cydia-runtime-state")


if __name__ == "__main__":
    main()
