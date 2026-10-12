# Private, unprivileged APT worker. Reuse the application's reviewed native
# objects and static APT without linking UIKit or optional bootstrap libraries.
recovery_worker_sources := \
    Cydia/AptRecoveryTrust.cpp Cydia/AptRecoverySnapshot.cpp Cydia/AptRecoveryInitialization.cpp \
    Cydia/AptNativeBackend.cpp Cydia/AptBackend.cpp Cydia/AptBackendOperations.cpp \
    Cydia/AptBackendRecovery.cpp Cydia/AptRecoveryPackageManager.cpp Cydia/AptAuthorizedArchives.cpp \
    Cydia/RepositoryArchiveAuthorization.cpp Cydia/AptCompatibility.cpp Cydia/AptVersionPolicy.cpp \
    Cydia/AptRuntime.cpp Cydia/AptRuntimeDescriptor.cpp Cydia/DpkgRunner.cpp Cydia/PackageDatabasePaths.cpp \
    Cydia/PrivilegedRuntime.cpp Cydia/PrivilegedConfig.cpp Cydia/RuntimeSnapshotInputs.cpp Cydia/APTMemoryCompat.cpp Cydia/APTSrvCompat.cpp \
    Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/AptProviderServer.cpp \
    Cydia/AptProviderServerTransport.cpp Cydia/AptProviderArchiveAuthorization.cpp Cydia/AptWorkerAcquireStatus.cpp \
    Cydia/PackageIdentity.cpp Cydia/PackageArchivePolicy.cpp Cydia/PackageArchiveReader.cpp \
    Cydia/SourcePreflight.cpp Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp \
    Cydia/SourceDocumentCommit.cpp Cydia/KeyringImport.cpp Cydia/RepositorySecurityPolicy.cpp
recovery_worker_objects := $(addprefix $(OBJECT_DIR)/,$(recovery_worker_sources:.cpp=.o))
recovery_worker_objects += $(OBJECT_DIR)/Cydia/LockdownServices.o $(apt_http_object)
recovery_worker_entry := $(OBJECT_DIR)/recovery/main.o

$(recovery_worker_entry): Cydia/AptRecoveryWorker.cpp $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] recovery worker entry"
	@$(cycc) $(plus) -DCYDIA_RECOVERY_WORKER_MAIN=1 -c -o $@ $< $(flag)

$(RECOVERY_WORKER_BINARY): $(recovery_worker_entry) $(recovery_worker_objects) $(APT_LIBRARY) $(EXEC_COMPAT_LIBRARY) $(compiler_rt_ios_library)
	@mkdir -p $(dir $@)
	@echo "[link] $@"
	@$(cycc) -o $@ $(filter %.o,$^) $(APT_LIBRARY) $(EXEC_COMPAT_LIBRARY) $(compiler_rt_ios_library) \
		$(link) -framework CoreFoundation -framework Security
	@$(LDID) -T0 -Sgenent.xml $@

.PHONY: recovery-worker
recovery-worker: $(RECOVERY_WORKER_BINARY)
