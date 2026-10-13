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
        driver_sources = list(driver_sources)
        if "Cydia/RuntimeSnapshotInputs.cpp" in driver_sources and "Cydia/AptProviderTriggerEvidenceCapture.cpp" not in driver_sources:
            driver_sources.append("Cydia/AptProviderTriggerEvidenceCapture.cpp")
        if "Cydia/AptRecoveryDependencyInspector.cpp" in driver_sources:
            for source in ["Cydia/AptProviderComponentCapture.cpp", "Cydia/AptProviderComponentSuccession.cpp",
                           "Cydia/AptProviderReview.cpp", "Cydia/AptProviderProtocol.cpp",
                           "Cydia/AptProviderValues.cpp", "Cydia/PackageIdentity.cpp"]:
                if source not in driver_sources:
                    driver_sources.append(source)
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
    compile_driver(["tests/AptProviderBinaryRelationshipsTests.cpp", "Cydia/AptProviderBinaryRelationships.cpp"],
                   "cydia-provider-binary-relationships", sanitize=True,
                   extra_compile_flags=["-DCYDIA_BINARY_RELATIONSHIPS_NATIVE_APT"])
    compile_driver(["tests/AptProviderNativeVersionComparisonTests.cpp", "Cydia/AptProviderNativeVersionComparison.cpp",
        "Cydia/AptProviderBinaryRelationships.cpp"], "cydia-provider-native-version-comparison", sanitize=True)
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
    compile_driver(["tests/AptProviderTriggerEvidenceTests.cpp", "Cydia/AptProviderTriggerEvidence.cpp",
                    "Cydia/ExtendedState.cpp"], "cydia-provider-trigger-evidence", sanitize=True)
    compile_driver(["tests/AptProviderTriggerEvidenceCaptureTests.cpp", "Cydia/AptProviderTriggerEvidence.cpp",
                    "Cydia/AptProviderTriggerEvidenceProtected.cpp", "Cydia/RuntimeSnapshotInputs.cpp",
                    "Cydia/ExtendedState.cpp", "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp",
                    "Cydia/SourceDocument.cpp", "Cydia/SourceDocumentStore.cpp", "Cydia/RepositorySecurityPolicy.cpp"],
                   "cydia-provider-trigger-capture")
    transaction_files_sources = ["tests/AptProviderTransactionFilesTests.cpp",
        "Cydia/AptProviderTransactionFiles.cpp", "Cydia/AptProviderComponentCapture.cpp",
        "Cydia/AptProviderComponentSuccession.cpp", "Cydia/AptProviderReview.cpp",
        "Cydia/AptProviderArchiveEvidence.cpp", "Cydia/AptProviderArchiveDecoders.cpp",
        "Cydia/AptProviderProtocol.cpp", "Cydia/AptProviderValues.cpp", "Cydia/AptRuntimeDescriptor.cpp",
        "Cydia/PackageIdentity.cpp", "Cydia/PackageArchivePolicy.cpp", "Cydia/PackageArchiveReader.cpp",
        "Cydia/RepositorySecurityPolicy.cpp", "Cydia/SourceDocument.cpp", "Cydia/SourceDocumentStore.cpp",
        "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp", "Cydia/ExtendedState.cpp"]
    transaction_effect_sources = ["Cydia/AptProviderTriggerEffects.cpp", "Cydia/AptProviderTriggerMetadata.cpp", "Cydia/AptProviderTriggerApproval.cpp",
        "Cydia/AptProviderTriggerEvidence.cpp", "Cydia/AptProviderTriggerEvidenceProtected.cpp"]
    compile_driver(transaction_files_sources, "cydia-provider-transaction-files", extra_link_flags=["-lz"])
    compile_driver(transaction_files_sources + transaction_effect_sources + ["Cydia/AptProviderTransactionOwner.cpp", "Cydia/AptProviderTransactionLease.cpp",
        "Cydia/AptProviderTransactionChannel.cpp",
        "Cydia/AptProviderDpkgState.cpp", "Cydia/DpkgRunner.cpp", "Cydia/RuntimeState.cpp",
        "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/SourceDocumentCommit.cpp"], "cydia-provider-transaction-owner",
        extra_link_flags=["-lz"], extra_compile_flags=["-DCYDIA_TRANSACTION_OWNER_TESTING=1"])
    transaction_owner_sources = transaction_files_sources[1:] + transaction_effect_sources + ["Cydia/AptProviderTransactionOwner.cpp",
        "Cydia/AptProviderTransactionLease.cpp", "Cydia/AptProviderDpkgState.cpp", "Cydia/DpkgRunner.cpp",
        "Cydia/RuntimeState.cpp", "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/SourceDocumentCommit.cpp"]
    compile_driver(["tests/AptProviderTransactionServiceTests.cpp"] + transaction_owner_sources + [
        "Cydia/AptProviderTransactionService.cpp", "Cydia/AptProviderTransactionChannel.cpp",
        "Cydia/AptProviderTransactionRequest.cpp", "Cydia/AptProviderTransactionRequestDigest.cpp",
        "Cydia/AptProviderTransactionResult.cpp",
        "Cydia/AptProviderBrokerValues.cpp", "Cydia/AptProviderSelectionValues.cpp", "Cydia/AptRecoverySnapshot.cpp"],
        "cydia-provider-transaction-service", extra_link_flags=["-lz"],
        extra_compile_flags=["-DCYDIA_TRANSACTION_OWNER_TESTING=1", "-DCYDIA_TRANSACTION_SERVICE_TESTING=1"])
    compile_driver(["tests/AptProviderNativeDpkgAuthorityTests.cpp", "Cydia/AptProviderNativeDpkgAuthority.cpp",
        "Cydia/AptRecoveryDependencyInspector.cpp", "Cydia/AptRecoveryMachO.cpp", "Cydia/RepositorySecurityPolicy.cpp",
        "Cydia/ExtendedState.cpp", "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp",
        "Cydia/RuntimeSnapshotInputs.cpp", "Cydia/SourceDocument.cpp", "Cydia/SourceDocumentStore.cpp"],
        "cydia-provider-native-dpkg-authority", extra_compile_flags=["-DCYDIA_NATIVE_DPKG_AUTHORITY_TESTING=1"])
    compile_driver(["tests/AptProviderBrokerAuthorizationTests.cpp", "Cydia/AptProviderBroker.cpp",
        "Cydia/AptProviderBrokerValues.cpp", "Cydia/AptProviderReview.cpp", "Cydia/AptProviderDpkgState.cpp",
        "Cydia/AptProviderSelectionValues.cpp", "Cydia/AptRuntimeDescriptor.cpp", "Cydia/ExtendedState.cpp",
        "Cydia/AptProviderProtocol.cpp", "Cydia/AptProviderValues.cpp", "Cydia/PrivilegedRuntime.cpp",
        "Cydia/PackageDatabasePaths.cpp", "Cydia/RepositorySecurityPolicy.cpp", "Cydia/PackageIdentity.cpp",
        "Cydia/DpkgRunner.cpp", "Cydia/AptRecoverySnapshot.cpp", "Cydia/AptProviderTransactionRequest.cpp",
        "Cydia/AptProviderTransactionResult.cpp",
        "Cydia/AptProviderTransactionRequestDigest.cpp"], "cydia-provider-broker-transaction",
        extra_compile_flags=["-DCYDIA_TRANSACTION_BROKER_TESTING=1"])
    trigger_effect_sources = ["Cydia/AptProviderTriggerEffects.cpp", "Cydia/AptProviderTriggerMetadata.cpp",
        "Cydia/AptProviderTriggerEvidence.cpp", "Cydia/AptProviderTriggerEvidenceProtected.cpp",
        "Cydia/AptProviderTriggerEvidenceCapture.cpp", "Cydia/AptProviderDpkgState.cpp", "Cydia/AptProviderProtocol.cpp",
        "Cydia/AptProviderValues.cpp", "Cydia/PackageIdentity.cpp", "Cydia/PackageArchivePolicy.cpp",
        "Cydia/PrivilegedRuntime.cpp", "Cydia/PackageDatabasePaths.cpp", "Cydia/RuntimeSnapshotInputs.cpp",
        "Cydia/RuntimeState.cpp", "Cydia/DpkgRunner.cpp", "Cydia/ExtendedState.cpp", "Cydia/SourceDocument.cpp",
        "Cydia/SourceDocumentStore.cpp", "Cydia/SourceDocumentCommit.cpp", "Cydia/RepositorySecurityPolicy.cpp"]
    compile_driver(["tests/AptProviderTriggerEffectsTests.cpp"] + trigger_effect_sources, "cydia-provider-trigger-effects", sanitize=True)
    compile_driver(["tests/AptProviderTriggerMetadataTests.cpp"] + trigger_effect_sources, "cydia-provider-trigger-metadata")
    compile_driver(["tests/AptProviderInstalledScriptsTests.cpp", "Cydia/AptProviderInstalledScripts.cpp"] +
        trigger_effect_sources, "cydia-provider-installed-scripts")
    compile_driver(["tests/AptProviderDeconfigurationEffectsTests.cpp", "Cydia/AptProviderDeconfigurationEffects.cpp",
        "Cydia/AptProviderBinaryRelationships.cpp"] + trigger_effect_sources, "cydia-provider-deconfiguration-allowances", sanitize=True)
    compile_driver(["tests/AptProviderTriggerCaptureTests.cpp"] + trigger_effect_sources + [
        "Cydia/AptProviderTriggerCapture.cpp", "Cydia/AptProviderTriggerApproval.cpp",
        "Cydia/AptProviderComponentCapture.cpp", "Cydia/AptProviderComponentSuccession.cpp", "Cydia/AptProviderReview.cpp"],
        "cydia-provider-trigger-review-capture")
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
