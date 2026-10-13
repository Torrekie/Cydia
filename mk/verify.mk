# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Make-backed modernization checks.  These targets are intentionally separate
# from `all` and `package`: existing build and packaging behavior is unchanged.

VERIFY_SCRIPT := scripts/verify-modernization.sh
APPEARANCE_VERIFY_SCRIPT := scripts/verify-appearance-simulator.sh
PROGRESS_SIMULATOR_VERIFY_SCRIPT := scripts/verify-progress-simulator.sh
CONFIRMATION_SIMULATOR_VERIFY_SCRIPT := scripts/verify-confirmation-simulator.sh
PACKAGE_DETAIL_SIMULATOR_VERIFY_SCRIPT := scripts/verify-package-detail-simulator.sh
HOME_SIMULATOR_VERIFY_SCRIPT := scripts/verify-home-simulator.sh
HOME_SIMULATOR_MATRIX_TEST := tests/HomeSimulatorMatrixTests.sh
HOME_SIMULATOR_JOBS ?= 1
HOME_SIMULATOR_DEVELOPER_DIR ?= $(HOME)/Downloads/Xcode.app/Contents/Developer
EXTERNAL_URL_SIMULATOR_VERIFY_SCRIPT := scripts/verify-external-url-simulator.sh
NATIVE_ERROR_SIMULATOR_VERIFY_SCRIPT := scripts/verify-native-error-simulator.sh
DEVICE_TRANSACTION_FIXTURE_SCRIPT := scripts/build-device-transaction-fixture.sh
DEVICE_RECOVERY_FIXTURE_SCRIPT := scripts/build-device-recovery-fixture.sh
DEVICE_CANCELLATION_FIXTURE_SCRIPT := scripts/build-device-cancellation-fixture.sh
DEVICE_CANCELLATION_SERVER_SCRIPT := scripts/verify-device-cancellation-server.sh
DEVICE_MEMORY_PREFLIGHT_TEST := tests/DeviceMemoryPreflightTests.sh
ROLLBACK_PACKAGE_PAIR_TEST := tests/RollbackPackagePairTests.sh
PROGRESS_ACQUISITION_CONTRACT_SCRIPT := scripts/verify-progress-acquisition-contract.sh
DEVICE_FIXTURE_LAYOUT ?= rootless
APT_VERIFY_SCRIPT := scripts/verify-apt-provenance.sh
APT_API_VERIFY_SCRIPT := scripts/verify-apt-api.sh
EXEC_COMPAT_VERIFY_SCRIPT := scripts/verify-exec-compat.sh
NATIVE_UI_VERIFY_SCRIPT := scripts/verify-native-ui-contract.sh
LEGACY_UI_COMPATIBILITY_NATIVE_CONTRACT_SCRIPT := tests/LegacyUICompatibilityNativeCallerContractTests.sh
LEGACY_UI_COMPATIBILITY_NATIVE_PROVIDER_CONTRACT_SCRIPT := tests/LegacyUICompatibilityNativeProviderContractTests.sh
LEGACY_UI_COMPATIBILITY_NATIVE_CONSUMER_CONTRACT_SCRIPT := tests/LegacyUICompatibilityNativeConsumerContractTests.sh
LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_CONTRACT_SCRIPT := tests/LegacyUICompatibilityNativeSnapshotContractTests.sh
LEGACY_UI_COMPATIBILITY_FORMAT_CONTRACT_SCRIPT := tests/LegacyUICompatibilityFormatContractTests.sh
LEGACY_UI_COMPATIBILITY_INVENTORY_CONTRACT_SCRIPT := tests/LegacyUICompatibilityInventoryContractTests.sh
LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_CONTRACT_SCRIPT := tests/LegacyUICompatibilityRuntimeEvidenceContractTests.sh
PACKAGE_CONTROLLER_NATIVE_CONSUMER_CONTRACT_SCRIPT := tests/PackageControllerNativeCompatibilityConsumerContractTests.sh
NATIVE_UI_BINARY_VERIFY_SCRIPT := scripts/verify-native-ui-binary.sh
BUILD_PROVENANCE_CONTRACT_TEST := tests/BuildProvenanceContractTests.sh
PACKAGE_ARTIFACT_VERIFY_SCRIPT := scripts/verify-package-artifacts.sh
NO_REMOTE_APP_UI_VERIFY_SCRIPT := tests/NoRemoteAppUIContractTests.sh
PROGRESS_CONTROLLER_VERIFY_SCRIPT := tests/ProgressControllerContractTests.sh
CONFIRMATION_CONTROLLER_APPEARANCE_VERIFY_SCRIPT := tests/ConfirmationControllerAppearanceContractTests.sh
PACKAGE_DETAIL_CONTROLLER_VERIFY_SCRIPT := tests/PackageDetailControllerContractTests.sh
PACKAGE_DETAIL_CONTACT_VERIFY_SCRIPT := tests/PackageDetailContactContractTests.sh
PACKAGE_DEPICTION_VIEW_VERIFY_SCRIPT := tests/PackageDepictionViewContractTests.sh
URL_PROTOCOL_POLICY_CONTRACT_SCRIPT := tests/URLProtocolPolicyContractTests.sh
URL_ORIGIN_VALIDATION_CONTRACT_SCRIPT := tests/URLOriginValidationContractTests.sh
URL_CACHE_VERIFY_SCRIPT := tests/URLCacheContractTests.sh
APT_SOURCE_CONTRACT_SCRIPT := tests/AptSourceIsolationContractTests.sh
APT_SOURCE_LIST_MTIME_CONTRACT_SCRIPT := tests/AptSourceListMtimeContractTests.sh
HOME_CONTROLLER_VERIFY_SCRIPT := tests/HomeControllerContractTests.sh
HOME_LOCALIZATION_VERIFY_SCRIPT := tests/HomeLocalizationTests.sh
FAQ_CONTROLLER_VERIFY_SCRIPT := tests/FAQControllerContractTests.sh
EXTERNAL_URL_CONTROLLER_VERIFY_SCRIPT := tests/ExternalURLControllerContractTests.sh
ERROR_VIEW_CONTROLLER_VERIFY_SCRIPT := tests/ErrorViewControllerContractTests.sh
WINDOW_APPEARANCE_VERIFY_SCRIPT := tests/WindowAppearanceContractTests.sh
UI_COLOR_APPEARANCE_VERIFY_SCRIPT := tests/UIColorAppearanceContractTests.sh
VERIFY_MAX_SOURCE_LINES ?= 1200
PACKAGE_PATHS_TEST := $(BUILD_DIR)/tests/PackageDatabasePathsTests
APT_RUNTIME_TEST := $(BUILD_DIR)/tests/AptRuntimeTests
REPOSITORY_SECURITY_TEST := $(BUILD_DIR)/tests/RepositorySecurityPolicyTests
SOURCE_DOCUMENT_TEST := $(BUILD_DIR)/tests/SourceDocumentTests
SOURCE_COMMIT_TEST := $(BUILD_DIR)/tests/SourceDocumentCommitTests
EXTENDED_STATE_TEST := $(BUILD_DIR)/tests/ExtendedStateTests
PRIVILEGED_RUNTIME_TEST := $(BUILD_DIR)/tests/PrivilegedRuntimeTests
PRIVILEGED_CLIENT_TEST := $(BUILD_DIR)/tests/PrivilegedClientTests
CAPABILITY_PREVIEW_TEST := $(BUILD_DIR)/tests/CapabilityPreviewTests
PRIVATE_STATE_DIRECTORY_TEST := $(BUILD_DIR)/tests/PrivateStateDirectoryTests
LEGACY_SOURCE_HANDOFF_TEST := $(BUILD_DIR)/tests/LegacySourceHandoffTests
LEGACY_CYDIA_SOURCE_ALIAS_TEST := $(BUILD_DIR)/tests/LegacyCydiaSourceAliasTests
DPKG_RUNNER_TEST := $(BUILD_DIR)/tests/DpkgRunnerTests
DPKG_STATUS_TEST := $(BUILD_DIR)/tests/DpkgStatusParserTests
EXEC_COMPAT_PARSER_TEST := $(BUILD_DIR)/tests/ExecCompatParserTests
REGEX_ARC_TEST := $(BUILD_DIR)/tests/RegExArcTests
MESSAGE_LOCALE_TEST := $(BUILD_DIR)/tests/MessageLocaleTests
MESSAGE_LOCALE_DECLARATIONS_TEST := $(BUILD_DIR)/tests/MessageLocaleDeclarationsTests
APT_MESSAGES_TEST := $(BUILD_DIR)/tests/AptMessagesTests
APT_PROVIDER_TEST := $(BUILD_DIR)/tests/AptProviderProtocolTests
APT_PROVIDER_SESSION_TEST := $(BUILD_DIR)/tests/AptProviderSessionTests
APT_PROVIDER_SERVER_TEST := $(BUILD_DIR)/tests/AptProviderServerTests
APT_PROVIDER_TRANSPORT_TEST := $(BUILD_DIR)/tests/AptProviderServerTransportTests
APT_PROVIDER_AUTHORIZATION_TEST := $(BUILD_DIR)/tests/AptProviderArchiveAuthorizationTests
APT_PROVIDER_LAUNCH_TEST := $(BUILD_DIR)/tests/AptProviderLaunchTests
APT_RECOVERY_SNAPSHOT_TEST := $(BUILD_DIR)/tests/AptRecoverySnapshotTests
APT_RECOVERY_MACHO_TEST := $(BUILD_DIR)/tests/AptRecoveryMachOTests
APT_TRANSACTION_LEASE_TEST := $(BUILD_DIR)/tests/AptProviderTransactionLeaseTests
DPKG_CONFFILE_TEST := $(BUILD_DIR)/tests/DpkgConffileTests
APT_PROVIDER_BROKER_AUTHORIZATION_TEST := $(BUILD_DIR)/tests/AptProviderBrokerAuthorizationTests
APT_PROVIDER_REVIEW_TEST := $(BUILD_DIR)/tests/AptProviderReviewTests
APT_PROVIDER_DPKG_STATE_TEST := $(BUILD_DIR)/tests/AptProviderDpkgStateTests
PROVIDER_PROGRESS_TEST := $(BUILD_DIR)/tests/ProviderProgressPolicyTests
APT_BACKEND_FACADE_TEST := $(BUILD_DIR)/tests/AptBackendFacadeTests
PACKAGE_IDENTITY_TEST := $(BUILD_DIR)/tests/PackageIdentityTests
PACKAGE_ARCHIVE_POLICY_TEST := $(BUILD_DIR)/tests/PackageArchivePolicyTests
MULTIARCH_FIXTURE_TEST := $(BUILD_DIR)/tests/MultiArchFixtureTests
DPKG_VERSION_POLICY_TEST := $(BUILD_DIR)/tests/DpkgVersionPolicyTests
UI_ROUTE_CONTEXT_TEST := $(BUILD_DIR)/tests/UIRouteContextTests
EXTERNAL_URL_POLICY_TEST := $(BUILD_DIR)/tests/ExternalURLPolicyTests
LEGACY_BRIDGE_POLICY_TEST := $(BUILD_DIR)/tests/LegacyBridgePolicyTests
LEGACY_UI_COMPATIBILITY_TEST := $(BUILD_DIR)/tests/LegacyUICompatibilityTests
LEGACY_UI_COMPATIBILITY_FORMAT_TEST := $(BUILD_DIR)/tests/LegacyUICompatibilityFormatTests
LEGACY_UI_COMPATIBILITY_NATIVE_TEST := $(BUILD_DIR)/tests/LegacyUICompatibilityNativeCallerTests
LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_TEST := $(BUILD_DIR)/tests/LegacyUICompatibilityNativeSnapshotTests
LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_TEST := $(BUILD_DIR)/tests/LegacyUICompatibilityRuntimeEvidenceTests
UI_ROUTE_DISPATCH_TEST := $(BUILD_DIR)/tests/UIRouteDispatchTests
UI_RESTORATION_STATE_TEST := $(BUILD_DIR)/tests/RestorationStateTests
CONFIRMATION_VIEW_MODEL_TEST := $(BUILD_DIR)/tests/ConfirmationViewModelTests
CONFIRMATION_CONTROLLER_TEST := $(BUILD_DIR)/tests/ConfirmationControllerContractTests
TRANSACTION_REVIEW_TEST := $(BUILD_DIR)/tests/TransactionReviewTests
FETCH_DIAGNOSTICS_TEST := $(BUILD_DIR)/tests/FetchDiagnosticsTests
PROGRESS_VIEW_MODEL_TEST := $(BUILD_DIR)/tests/ProgressViewModelTests
PACKAGE_DETAIL_VIEW_MODEL_TEST := $(BUILD_DIR)/tests/PackageDetailViewModelTests
PACKAGE_DEPICTION_FACADE_TEST := $(BUILD_DIR)/tests/PackageDepictionJavaScriptFacadeTests
PACKAGE_DEPICTION_POLICY_TEST := $(BUILD_DIR)/tests/PackageDepictionPolicyTests
PACKAGE_LEGACY_METADATA_POLICY_TEST := $(BUILD_DIR)/tests/PackageLegacyMetadataPolicyTests
URL_PROTOCOL_POLICY_TEST := $(BUILD_DIR)/tests/URLProtocolPolicyTests
HOME_VIEW_MODEL_TEST := $(BUILD_DIR)/tests/HomeViewModelTests
ERROR_VIEW_MODEL_TEST := $(BUILD_DIR)/tests/ErrorViewModelTests
YIELD_TO_SELECTOR_TEST := $(BUILD_DIR)/tests/YieldToSelectorTests
.PHONY: verify-repository-hygiene
verify: verify-repository-hygiene
verify: verify-package-archive-policy
.PHONY: verify-package-archive-policy
$(PACKAGE_ARCHIVE_POLICY_TEST): tests/PackageArchivePolicyTests.cpp \
		Cydia/PackageArchivePolicy.cpp Cydia/PackageArchivePolicy.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/PackageArchivePolicyTests.cpp Cydia/PackageArchivePolicy.cpp -o $@

verify-package-archive-policy: $(PACKAGE_ARCHIVE_POLICY_TEST)
	@$<

APT_BINARY_RELATIONSHIPS_TEST := $(BUILD_DIR)/tests/AptProviderBinaryRelationshipsTests
$(APT_BINARY_RELATIONSHIPS_TEST): tests/AptProviderBinaryRelationshipsTests.cpp \
		Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderBinaryRelationships.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-apt-binary-relationships
verify: verify-apt-binary-relationships
verify-apt-binary-relationships: $(APT_BINARY_RELATIONSHIPS_TEST)
	@$<

APT_NATIVE_VERSION_COMPARISON_TEST := $(BUILD_DIR)/tests/AptProviderNativeVersionComparisonTests
$(APT_NATIVE_VERSION_COMPARISON_TEST): tests/AptProviderNativeVersionComparisonTests.cpp \
		Cydia/AptProviderNativeVersionComparison.cpp Cydia/AptProviderNativeVersionComparison.hpp \
		Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderBinaryRelationships.hpp Cydia/DpkgRunner.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-apt-native-version-comparison
verify: verify-apt-native-version-comparison
verify-apt-native-version-comparison: $(APT_NATIVE_VERSION_COMPARISON_TEST)
	@$<

APT_PREDEPENDS_EVIDENCE_TEST := $(BUILD_DIR)/tests/AptProviderPreDependsEvidenceTests
$(APT_PREDEPENDS_EVIDENCE_TEST): tests/AptProviderPreDependsEvidenceTests.cpp \
		Cydia/AptProviderPreDependsEvidence.cpp Cydia/AptProviderPreDependsEvidence.hpp \
		Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderBinaryRelationships.hpp \
		Cydia/PackageArchivePolicy.cpp Cydia/PackageArchivePolicy.hpp Cydia/AptProviderTriggerEffects.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-apt-predepends-evidence
verify: verify-apt-predepends-evidence
verify-apt-predepends-evidence: $(APT_PREDEPENDS_EVIDENCE_TEST)
	@$<

APT_UNPACK_OWNERSHIP_TEST := $(BUILD_DIR)/tests/AptProviderUnpackOwnershipTests
$(APT_UNPACK_OWNERSHIP_TEST): tests/AptProviderUnpackOwnershipTests.cpp \
		Cydia/AptProviderUnpackOwnership.cpp Cydia/AptProviderUnpackOwnership.hpp \
		Cydia/AptProviderInstalledOwnership.hpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/AptProviderBinaryRelationships.hpp Cydia/PackageArchivePolicy.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-apt-unpack-ownership
verify: verify-apt-unpack-ownership
verify-apt-unpack-ownership: $(APT_UNPACK_OWNERSHIP_TEST)
	@$<

APT_DECONFIGURATION_APPROVAL_TEST := $(BUILD_DIR)/tests/AptProviderDeconfigurationApprovalTests
apt_deconfiguration_approval_test_sources := tests/AptProviderDeconfigurationApprovalTests.cpp \
	Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
	Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp \
	Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp
$(APT_DECONFIGURATION_APPROVAL_TEST): $(apt_deconfiguration_approval_test_sources) \
		Cydia/AptProviderDeconfigurationApproval.hpp Cydia/AptProviderDeconfigurationEffects.hpp \
		Cydia/AptProviderBinaryRelationships.hpp Cydia/AptProviderProtocol.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(apt_deconfiguration_approval_test_sources) -o $@
.PHONY: verify-apt-deconfiguration-approval
verify: verify-apt-deconfiguration-approval
verify-apt-deconfiguration-approval: $(APT_DECONFIGURATION_APPROVAL_TEST)
	@$<

APT_EFFECT_REVIEW_BUNDLE_TEST := $(BUILD_DIR)/tests/AptProviderEffectReviewBundleTests
apt_effect_review_bundle_test_sources := tests/AptProviderEffectReviewBundleTests.cpp \
	Cydia/AptProviderEffectReviewBundle.cpp Cydia/AptProviderTransactionRequest.cpp Cydia/ExtendedState.cpp \
	$(filter-out tests/AptProviderDeconfigurationApprovalTests.cpp,$(apt_deconfiguration_approval_test_sources))
$(APT_EFFECT_REVIEW_BUNDLE_TEST): $(apt_effect_review_bundle_test_sources) \
		Cydia/AptProviderEffectReviewBundle.hpp Cydia/AptProviderTransactionRequest.hpp \
		Cydia/AptProviderDeconfigurationApproval.hpp Cydia/AptProviderTriggerEffects.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(apt_effect_review_bundle_test_sources) -o $@
.PHONY: verify-apt-effect-review-bundle
verify: verify-apt-effect-review-bundle
verify-apt-effect-review-bundle: $(APT_EFFECT_REVIEW_BUNDLE_TEST)
	@$<

APT_TRANSACTION_BEGIN_TEST := $(BUILD_DIR)/tests/AptProviderTransactionBeginTests
apt_transaction_begin_test_sources := tests/AptProviderTransactionBeginTests.cpp \
	$(filter-out tests/AptProviderEffectReviewBundleTests.cpp,$(apt_effect_review_bundle_test_sources))
$(APT_TRANSACTION_BEGIN_TEST): $(apt_transaction_begin_test_sources) \
		Cydia/AptProviderTransactionRequest.hpp Cydia/AptProviderEffectReviewBundle.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(apt_transaction_begin_test_sources) -o $@
.PHONY: verify-apt-transaction-begin
verify: verify-apt-transaction-begin
verify-apt-transaction-begin: $(APT_TRANSACTION_BEGIN_TEST)
	@$<

APT_CONDITIONAL_DECONFIGURATION_TEST := $(BUILD_DIR)/tests/AptProviderConditionalDeconfigurationTests
apt_conditional_deconfiguration_test_sources := tests/AptProviderConditionalDeconfigurationTests.cpp \
	Cydia/AptProviderReview.cpp Cydia/AptProviderDpkgState.cpp Cydia/AptProviderConditionalDeconfiguration.cpp \
	Cydia/AptProviderRestorationDebt.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
	Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
	Cydia/RepositorySecurityPolicy.cpp Cydia/ExtendedState.cpp
$(APT_CONDITIONAL_DECONFIGURATION_TEST): $(apt_conditional_deconfiguration_test_sources) \
		Cydia/AptProviderConditionalDeconfiguration.hpp Cydia/AptProviderRestorationDebt.hpp \
		Cydia/AptProviderDeconfigurationApproval.hpp Cydia/AptProviderReview.hpp Cydia/AptProviderDpkgState.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(apt_conditional_deconfiguration_test_sources) -o $@
.PHONY: verify-apt-conditional-deconfiguration
verify: verify-apt-conditional-deconfiguration
verify-apt-conditional-deconfiguration: $(APT_CONDITIONAL_DECONFIGURATION_TEST)
	@$<

APT_RESTORATION_DEBT_TEST := $(BUILD_DIR)/tests/AptProviderRestorationDebtTests
apt_restoration_debt_test_sources := tests/AptProviderRestorationDebtTests.cpp \
	Cydia/AptProviderRestorationDebt.cpp $(filter-out tests/AptProviderDeconfigurationApprovalTests.cpp,$(apt_deconfiguration_approval_test_sources))
$(APT_RESTORATION_DEBT_TEST): $(apt_restoration_debt_test_sources) \
		Cydia/AptProviderRestorationDebt.hpp Cydia/AptProviderDeconfigurationApproval.hpp \
		Cydia/AptProviderDeconfigurationEffects.hpp Cydia/AptProviderBinaryRelationships.hpp \
		Cydia/AptProviderProtocol.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(apt_restoration_debt_test_sources) -o $@
.PHONY: verify-apt-restoration-debt
verify: verify-apt-restoration-debt
verify-apt-restoration-debt: $(APT_RESTORATION_DEBT_TEST)
	@$<

NATIVE_LAUNCH_ENVIRONMENT_TEST := $(BUILD_DIR)/tests/NativeLaunchEnvironmentTests
$(NATIVE_LAUNCH_ENVIRONMENT_TEST): tests/NativeLaunchEnvironmentTests.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/NativeLaunchEnvironment.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-native-launch-environment
verify: verify-native-launch-environment
verify-native-launch-environment: $(NATIVE_LAUNCH_ENVIRONMENT_TEST)
	@$<

APT_NATIVE_EFFECT_POLICY_TEST := $(BUILD_DIR)/tests/AptProviderNativeEffectPolicyTests
$(APT_NATIVE_EFFECT_POLICY_TEST): tests/AptProviderNativeEffectPolicyTests.cpp \
		Cydia/AptProviderNativeEffectPolicy.cpp Cydia/AptProviderNativeEffectPolicy.hpp \
		Cydia/NativeLaunchEnvironment.cpp Cydia/NativeLaunchEnvironment.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
.PHONY: verify-apt-native-effect-policy
verify: verify-apt-native-effect-policy
verify-apt-native-effect-policy: $(APT_NATIVE_EFFECT_POLICY_TEST)
	@$<

verify-repository-hygiene:
	@python3 scripts/verify-repository-hygiene.py

.PHONY: verify-apt-messages
verify: verify-apt-messages
$(APT_MESSAGES_TEST): tests/AptMessagesTests.cpp Cydia/AptMessages.cpp Cydia/AptMessages.h \
        Cydia/ProtectedLibraryPath.hpp apt-extra/apti18n.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		-DCYDIA_APT_MESSAGE_DOMAIN='"$(APT_MESSAGE_DOMAIN)"' \
		tests/AptMessagesTests.cpp Cydia/AptMessages.cpp $(if $(filter Linux,$(HOST_OS)),-ldl -pthread,) -o $@
verify-apt-messages: $(APT_MESSAGES_TEST)
	@$<

.PHONY: verify-apt-provider
verify: verify-apt-provider
$(APT_RECOVERY_MACHO_TEST): tests/AptRecoveryMachOTests.cpp Cydia/AptRecoveryMachO.cpp Cydia/AptRecoveryMachO.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptRecoveryMachOTests.cpp Cydia/AptRecoveryMachO.cpp -o $@
apt_recovery_snapshot_test_sources := tests/AptRecoverySnapshotTests.cpp Cydia/AptRecoverySnapshot.cpp \
	Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/AptRuntimeDescriptor.cpp \
	Cydia/RepositorySecurityPolicy.cpp Cydia/PackageIdentity.cpp Cydia/AptProviderSelectionValues.cpp \
	Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
$(APT_RECOVERY_SNAPSHOT_TEST): $(apt_recovery_snapshot_test_sources) Cydia/AptRecoverySnapshot.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(apt_recovery_snapshot_test_sources) -o $@
$(APT_PROVIDER_LAUNCH_TEST): tests/AptProviderLaunchTests.cpp Cydia/AptProviderLaunch.cpp Cydia/AptProviderLaunch.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++17 -Wall -Wextra -Werror -I. \
		tests/AptProviderLaunchTests.cpp Cydia/AptProviderLaunch.cpp -pthread -o $@
$(APT_PROVIDER_SESSION_TEST) $(APT_PROVIDER_TRANSPORT_TEST) $(APT_BACKEND_FACADE_TEST): \
	Cydia/AptProviderLaunch.cpp Cydia/AptProviderLaunch.hpp
$(APT_PROVIDER_TEST): tests/AptProviderProtocolTests.cpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/AptRuntime.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptProviderProtocolTests.cpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp \
		Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp -o $@
$(APT_PROVIDER_SESSION_TEST): tests/AptProviderSessionTests.cpp Cydia/AptProviderSession.cpp \
		Cydia/AptProviderSession.hpp Cydia/AptProviderClient.hpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		-DCYDIA_PROVIDER_SESSION_TESTING=1 tests/AptProviderSessionTests.cpp \
		Cydia/AptProviderSession.cpp Cydia/AptProviderLaunch.cpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp \
		Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp \
		$(if $(filter Darwin,$(HOST_OS)),-framework Security -framework CoreFoundation,-pthread) -o $@
$(APT_PROVIDER_SERVER_TEST): tests/AptProviderServerTests.cpp Cydia/AptProviderServer.cpp \
		Cydia/AptProviderServer.hpp Cydia/AptBackendImplementation.hpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptProviderServerTests.cpp Cydia/AptProviderServer.cpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp -o $@
$(APT_PROVIDER_TRANSPORT_TEST): tests/AptProviderServerTransportTests.cpp Cydia/AptProviderServerTransport.cpp \
		Cydia/AptProviderServerTransport.hpp Cydia/AptProviderServer.cpp Cydia/AptProviderServer.hpp \
		Cydia/AptProviderSession.cpp Cydia/AptProviderSession.hpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		-DCYDIA_PROVIDER_SESSION_TESTING=1 tests/AptProviderServerTransportTests.cpp \
		Cydia/AptProviderServerTransport.cpp Cydia/AptProviderServer.cpp Cydia/AptProviderSession.cpp Cydia/AptProviderLaunch.cpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp \
		$(if $(filter Darwin,$(HOST_OS)),-framework Security -framework CoreFoundation,-pthread) -o $@
$(APT_PROVIDER_AUTHORIZATION_TEST): tests/AptProviderArchiveAuthorizationTests.cpp \
		Cydia/AptProviderArchiveAuthorization.cpp Cydia/AptProviderArchiveAuthorization.hpp \
		Cydia/RepositoryArchiveAuthorization.cpp Cydia/RepositoryArchiveAuthorization.hpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp \
		Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptProviderArchiveAuthorizationTests.cpp Cydia/AptProviderArchiveAuthorization.cpp \
		Cydia/RepositoryArchiveAuthorization.cpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp \
		Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp -pthread -o $@
apt_provider_broker_authorization_sources := tests/AptProviderBrokerAuthorizationTests.cpp \
	Cydia/AptProviderEffectReviewBundle.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
	Cydia/AptProviderTransactionRequest.cpp \
	Cydia/AptProviderTransactionResult.cpp \
	Cydia/AptProviderBroker.cpp Cydia/AptProviderBrokerValues.cpp Cydia/AptProviderReview.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
	Cydia/AptProviderDpkgState.cpp Cydia/AptProviderConditionalDeconfiguration.cpp Cydia/AptProviderRestorationDebt.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderSelectionValues.cpp Cydia/AptRuntimeDescriptor.cpp \
	Cydia/ExtendedState.cpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp \
	Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp Cydia/RepositorySecurityPolicy.cpp \
	Cydia/PackageIdentity.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/AptRecoverySnapshot.cpp
$(APT_PROVIDER_BROKER_AUTHORIZATION_TEST): $(apt_provider_broker_authorization_sources) \
		Cydia/AptProviderBroker.hpp Cydia/AptProviderProtocol.hpp Cydia/AptProviderReview.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(sort $(apt_provider_broker_authorization_sources)) -o $@
$(APT_BACKEND_FACADE_TEST): tests/AptBackendFacadeTests.cpp Cydia/AptBackendFacade.cpp Cydia/RuntimeProviderAdmission.hpp \
		Cydia/AptRemoteBackend.cpp Cydia/AptBackendImplementation.hpp Cydia/AptBackend.hpp \
		Cydia/AptProviderSession.cpp Cydia/AptProviderSession.hpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderProtocol.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		-DCYDIA_PROVIDER_SESSION_TESTING=1 tests/AptBackendFacadeTests.cpp \
		Cydia/AptBackendFacade.cpp Cydia/AptRemoteBackend.cpp Cydia/AptProviderSession.cpp Cydia/AptProviderLaunch.cpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp \
		$(if $(filter Darwin,$(HOST_OS)),-framework Security -framework CoreFoundation,-pthread) -o $@
$(APT_PROVIDER_REVIEW_TEST): tests/AptProviderReviewTests.cpp Cydia/AptProviderReview.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/AptProviderReview.hpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderProtocol.hpp \
		Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptProviderReviewTests.cpp Cydia/AptProviderReview.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp -o $@
$(APT_TRANSACTION_LEASE_TEST): tests/AptProviderTransactionLeaseTests.cpp \
		Cydia/AptProviderTransactionLease.cpp Cydia/AptProviderTransactionLease.hpp \
		Cydia/AptProviderComponentSuccession.cpp Cydia/AptProviderComponentSuccession.hpp \
		Cydia/AptProviderReview.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp Cydia/AptProviderReview.hpp Cydia/AptProviderProtocol.cpp \
		Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp Cydia/RepositorySecurityPolicy.cpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp Cydia/ExtendedState.cpp \
		Cydia/ApplicationSession.hpp Cydia/PackageArchiveReader.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -o $@
$(PROVIDER_PROGRESS_TEST): tests/ProviderProgressPolicyTests.cpp Cydia/ProviderProgressPolicy.hpp Cydia/SourceFetchActivity.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $< -o $@
$(APT_PROVIDER_DPKG_STATE_TEST): tests/AptProviderDpkgStateTests.cpp Cydia/AptProviderDpkgState.cpp Cydia/AptProviderConditionalDeconfiguration.cpp Cydia/AptProviderRestorationDebt.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/AptProviderDpkgState.hpp Cydia/AptProviderProtocol.cpp Cydia/AptProviderProtocol.hpp \
		Cydia/ExtendedState.cpp Cydia/ExtendedState.hpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/AptProviderDpkgStateTests.cpp Cydia/AptProviderDpkgState.cpp Cydia/AptProviderConditionalDeconfiguration.cpp Cydia/AptProviderRestorationDebt.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/AptProviderProtocol.cpp Cydia/ExtendedState.cpp Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp -o $@
verify-apt-provider: $(APT_PROVIDER_TEST) $(APT_RECOVERY_MACHO_TEST) $(APT_RECOVERY_SNAPSHOT_TEST) $(APT_PROVIDER_LAUNCH_TEST) $(APT_PROVIDER_SESSION_TEST) $(APT_PROVIDER_SERVER_TEST) $(APT_PROVIDER_TRANSPORT_TEST) $(APT_PROVIDER_AUTHORIZATION_TEST) $(APT_PROVIDER_BROKER_AUTHORIZATION_TEST) $(APT_BACKEND_FACADE_TEST) $(APT_PROVIDER_REVIEW_TEST) $(APT_TRANSACTION_LEASE_TEST) $(APT_PROVIDER_DPKG_STATE_TEST) $(PROVIDER_PROGRESS_TEST)
	@$<
	@$(APT_RECOVERY_MACHO_TEST)
	@$(APT_RECOVERY_SNAPSHOT_TEST)
	@$(APT_PROVIDER_LAUNCH_TEST)
	@$(APT_PROVIDER_SESSION_TEST)
	@$(APT_PROVIDER_SERVER_TEST)
	@$(APT_PROVIDER_TRANSPORT_TEST)
	@$(APT_PROVIDER_AUTHORIZATION_TEST)
	@$(APT_PROVIDER_BROKER_AUTHORIZATION_TEST)
	@$(APT_BACKEND_FACADE_TEST)
	@$(APT_PROVIDER_REVIEW_TEST)
	@$(APT_TRANSACTION_LEASE_TEST)
	@$(APT_PROVIDER_DPKG_STATE_TEST)
	@$(PROVIDER_PROGRESS_TEST)

ifeq ($(HOST_OS),Linux)
host_cxx ?= $(or $(HOST_CXX),c++)
host_cc ?= $(or $(HOST_CC),cc)
host_cxx_flags :=
host_cc_flags :=
else
host_cxx ?= $(shell xcrun --sdk macosx -f clang++)
host_cc ?= $(shell xcrun --sdk macosx -f clang)
host_cxx_flags := -isysroot $(mac)
host_cc_flags := -isysroot $(mac)
endif

verify_objc_sources := $(filter %.m %.mm,$(source))
verify_objc_objects := $(patsubst %.m,$(OBJECT_DIR)/%.o,$(filter %.m,$(verify_objc_sources)))
verify_objc_objects += $(patsubst %.mm,$(OBJECT_DIR)/%.o,$(filter %.mm,$(verify_objc_sources)))

# Ownership checks cover the supported Objective-C implementation and header
# set, including helper binaries.  Tests are already excluded by sources.mk.
verify_ownership_files := $(filter %.m %.mm %.h %.hpp,$(code))
verify_ownership_files += postinst.mm cfversion.mm

# The line-size gate is for app-owned source only.  apt64 is vendored upstream
# code, and SDURLCache is a vendored third-party implementation; neither is a
# realistic part of the Cydia module split.  They remain in the ARC compile
# gate above.
verify_size_sources := $(filter-out apt64/% SDURLCache/%,$(filter %.m %.mm %.c %.cc %.cpp,$(code)))
verify_size_sources += postinst.mm cfversion.mm

# Candidate set for the APT-consumer inventory.  The inventory script checks
# that every raw APT token in app-owned C++/Objective-C++ is represented by the
# reviewed `apt_api_sources` manifest above.
apt_api_candidates := $(filter-out $(APT_SOURCE_DIR)/% SDURLCache/%,$(filter %.mm %.cpp %.cc,$(code)))

.PHONY: verify verify-static verify-config verify-ownership verify-size verify-compile verify-native-ui-binary verify-build-provenance verify-native-ui-provenance verify-build-provenance-contract verify-package-artifacts
.PHONY: verify-package-paths verify-package-identity verify-apt-runtime verify-apt-source-isolation verify-legacy-source-handoff verify-dpkg-runner verify-dpkg-status verify-bootstrap-helpers
.PHONY: verify-regex-arc verify-message-locale
verify: verify-message-locale
.PHONY: verify-yield-to-selector
.PHONY: verify-multiarch-fixture verify-dpkg-version-policy
.PHONY: verify-native-ui verify-native-ui-contract verify-no-remote-app-ui verify-ui-route-context verify-external-url-policy verify-external-url-controller verify-ui-route-dispatch verify-ui-restoration-state verify-legacy-bridge-policy verify-legacy-ui-compatibility verify-legacy-ui-compatibility-format verify-legacy-ui-compatibility-native verify-legacy-ui-compatibility-native-snapshot verify-legacy-ui-compatibility-native-provider verify-legacy-ui-compatibility-native-consumer verify-legacy-ui-compatibility-inventory verify-legacy-ui-compatibility-runtime-evidence verify-package-controller-native-consumer
.PHONY: verify-confirmation-view-model verify-confirmation-controller verify-confirmation-controller-appearance verify-confirmation-controller-simulator verify-transaction-review verify-fetch-diagnostics
.PHONY: verify-progress-view-model verify-progress-controller
.PHONY: verify-package-detail-view-model verify-package-depiction-facade verify-package-depiction-policy verify-package-legacy-metadata-policy verify-url-protocol-policy
.PHONY: verify-package-detail-controller verify-package-detail-contact verify-package-detail-controller-simulator verify-package-depiction-view
.PHONY: verify-home-view-model verify-home-controller verify-home-localization verify-home-controller-simulator verify-faq-controller verify-upgrading-guide
.PHONY: verify-error-view-model verify-error-view-controller
.PHONY: verify-window-appearance verify-url-cache verify-url-origin-validation-contract
.PHONY: verify-exec-compat verify-exec-compat-provenance verify-exec-compat-archive
.PHONY: verify-exec-compat-parser verify-exec-compat-binary
.PHONY: verify-appearance-simulator
.PHONY: verify-confirmation-simulator
.PHONY: verify-progress-simulator
.PHONY: verify-package-detail-simulator
.PHONY: verify-home-simulator-prepare verify-home-simulator verify-home-simulator-matrix verify-home-simulator-matrix-contract
.PHONY: verify-external-url-simulator
.PHONY: verify-native-error-simulator
.PHONY: verify-device-transaction-fixture
.PHONY: verify-device-recovery-fixture
.PHONY: verify-device-cancellation-fixture
.PHONY: verify-device-memory-preflight
.PHONY: verify-rollback-package-pair
.PHONY: verify-progress-acquisition-contract
.PHONY: verify-apt verify-apt-provenance verify-apt-sources verify-apt-config verify-apt-api verify-apt-api-inventory verify-apt-compile verify-apt-sourcelist-mtime

verify: verify-apt verify-apt-api verify-apt-compile verify-package-paths verify-package-identity verify-multiarch-fixture verify-dpkg-version-policy verify-apt-runtime verify-apt-source-isolation verify-apt-sourcelist-mtime verify-dpkg-runner verify-dpkg-status verify-bootstrap-helpers verify-regex-arc verify-yield-to-selector verify-exec-compat verify-progress-acquisition-contract verify-device-memory-preflight verify-rollback-package-pair verify-native-ui verify-native-ui-binary verify-build-provenance verify-build-provenance-contract verify-legacy-ui-compatibility-format verify-legacy-ui-compatibility-native verify-legacy-ui-compatibility-native-snapshot verify-legacy-ui-compatibility-native-provider verify-legacy-ui-compatibility-native-consumer verify-legacy-ui-compatibility-runtime-evidence verify-package-controller-native-consumer verify-static verify-compile

verify-device-transaction-fixture: $(DEVICE_TRANSACTION_FIXTURE_SCRIPT) \
		tests/fixtures/ui/device-transaction/control \
		tests/fixtures/ui/device-transaction/marker.txt
	@PACKAGE_LAYOUT="$(DEVICE_FIXTURE_LAYOUT)" $(DEVICE_TRANSACTION_FIXTURE_SCRIPT) \
		"$(BUILD_DIR)/device-transaction-fixture"

verify-device-recovery-fixture: $(DEVICE_RECOVERY_FIXTURE_SCRIPT) \
		tests/fixtures/ui/device-recovery/baseline.control \
		tests/fixtures/ui/device-recovery/candidate.control \
		tests/fixtures/ui/device-recovery/baseline-marker.txt \
		tests/fixtures/ui/device-recovery/candidate-marker.txt \
		tests/fixtures/ui/device-recovery/postinst
	@$(DEVICE_RECOVERY_FIXTURE_SCRIPT) \
		"$(BUILD_DIR)/device-recovery-fixture"

verify-device-cancellation-fixture: $(DEVICE_CANCELLATION_FIXTURE_SCRIPT) \
		$(DEVICE_CANCELLATION_SERVER_SCRIPT) \
		scripts/serve-device-cancellation-fixture.py \
		tests/fixtures/ui/device-cancellation/control
	@$(DEVICE_CANCELLATION_FIXTURE_SCRIPT) \
		"$(BUILD_DIR)/device-cancellation-fixture"
	@$(DEVICE_CANCELLATION_SERVER_SCRIPT) \
		"$(BUILD_DIR)/device-cancellation-fixture"

verify-device-memory-preflight: $(DEVICE_MEMORY_PREFLIGHT_TEST) \
		scripts/verify-device-memory-preflight.sh \
		tests/fixtures/ui/device-memory-preflight/healthy-rootless.txt \
		tests/fixtures/ui/device-memory-preflight/healthy-rootful.txt \
		tests/fixtures/ui/device-memory-preflight/boundary-pass.txt \
		tests/fixtures/ui/device-memory-preflight/boundary-fail.txt \
		tests/fixtures/ui/device-memory-preflight/low-memory.txt \
		tests/fixtures/ui/device-memory-preflight/active-dpkg.txt \
		tests/fixtures/ui/device-memory-preflight/active-dpkg-helper.txt \
		tests/fixtures/ui/device-memory-preflight/impossible-memory.txt \
		tests/fixtures/ui/device-memory-preflight/missing-memory-percent-token.txt \
		tests/fixtures/ui/device-memory-preflight/duplicate-memory-percent-token.txt \
		tests/fixtures/ui/device-memory-preflight/fractional-swap-overflow.txt \
		tests/fixtures/ui/device-memory-preflight/duplicate-memory-values.txt \
		tests/fixtures/ui/device-memory-preflight/duplicate-swap-values.txt \
		tests/fixtures/ui/device-memory-preflight/duplicate-architecture-values.txt \
		tests/fixtures/ui/device-memory-preflight/duplicate-layout-values.txt \
		tests/fixtures/ui/device-memory-preflight/nonroot-uid.txt \
		tests/fixtures/ui/device-memory-preflight/unknown-section-marker.txt \
		tests/fixtures/ui/device-memory-preflight/extra-swap-output.txt \
		tests/fixtures/ui/device-memory-preflight/empty-processes.txt \
		tests/fixtures/ui/device-memory-preflight/malformed-processes.txt \
		tests/fixtures/ui/device-memory-preflight/malformed.txt \
		tests/fixtures/ui/device-memory-preflight/out-of-order.txt \
		tests/fixtures/ui/device-memory-preflight/fake-bin/ssh
	@$(DEVICE_MEMORY_PREFLIGHT_TEST)

verify-rollback-package-pair: $(ROLLBACK_PACKAGE_PAIR_TEST) \
		scripts/verify-rollback-package-pair.sh
	@$(ROLLBACK_PACKAGE_PAIR_TEST)

verify-progress-acquisition-contract: $(PROGRESS_ACQUISITION_CONTRACT_SCRIPT) \
		Cydia/Database.mm Cydia/DatabaseStatus.mm Cydia/ProgressController.mm
	@$(PROGRESS_ACQUISITION_CONTRACT_SCRIPT)

$(PACKAGE_PATHS_TEST): tests/PackageDatabasePathsTests.cpp Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/PackageDatabasePathsTests.cpp Cydia/PackageDatabasePaths.cpp -o $@

verify-package-paths: $(PACKAGE_PATHS_TEST)
	@$<

$(PACKAGE_IDENTITY_TEST): tests/PackageIdentityTests.cpp Cydia/PackageIdentity.cpp Cydia/AptCompatibility.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/PackageIdentityTests.cpp Cydia/PackageIdentity.cpp -o $@

verify-package-identity: $(PACKAGE_IDENTITY_TEST)
	@$<

$(MULTIARCH_FIXTURE_TEST): tests/MultiArchFixtureTests.cpp \
		tests/fixtures/multiarch/Packages tests/fixtures/multiarch/progress-status \
		Cydia/PackageIdentity.cpp Cydia/AptCompatibility.hpp \
		Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/MultiArchFixtureTests.cpp Cydia/PackageIdentity.cpp \
		Cydia/DpkgStatusParser.cpp -o $@

verify-multiarch-fixture: $(MULTIARCH_FIXTURE_TEST)
	@$<

$(DPKG_VERSION_POLICY_TEST): tests/DpkgVersionPolicyTests.cpp \
		Cydia/AptVersionPolicy.cpp Cydia/AptVersionPolicyInternal.hpp \
		$(APT_SOURCE_DIR)/apt-pkg/deb/debversion.cc \
		$(APT_SOURCE_DIR)/apt-pkg/version.cc Cydia/APTMemoryCompat.cpp \
		$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET)
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra \
		-Iapt-extra -I$(APT_SOURCE_DIR) -I$(APT_CONTRIB_INCLUDE_DIR) \
		-I$(APT_DEB_INCLUDE_DIR) -I. -include apt.h \
		tests/DpkgVersionPolicyTests.cpp Cydia/AptVersionPolicy.cpp \
		$(APT_SOURCE_DIR)/apt-pkg/deb/debversion.cc \
		$(APT_SOURCE_DIR)/apt-pkg/version.cc Cydia/APTMemoryCompat.cpp -o $@

verify-dpkg-version-policy: $(DPKG_VERSION_POLICY_TEST)
	@command -v dpkg >/dev/null || { echo "dpkg is required" >&2; exit 2; }
	@$<

$(APT_RUNTIME_TEST): tests/AptRuntimeTests.cpp Cydia/AptRuntime.cpp Cydia/AptRuntime.hpp \
        Cydia/AptRuntimeDescriptor.cpp Cydia/AptRuntimeDescriptor.hpp \
        apt-extra/gnutls/gnutls.h \
		Cydia/RepositorySecurityPolicy.cpp Cydia/RepositorySecurityPolicy.hpp \
		Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp \
		Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/DpkgRunner.h \
		Cydia/PrivilegedRuntime.cpp Cydia/PrivilegedRuntime.hpp \
		tests/apt-stubs/apt-pkg/aptconfiguration.h \
		tests/apt-stubs/apt-pkg/configuration.h tests/apt-stubs/apt-pkg/init.h \
		tests/apt-stubs/apt-pkg/pkgsystem.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Itests/apt-stubs -I. \
		tests/AptRuntimeTests.cpp Cydia/AptRuntime.cpp Cydia/AptRuntimeDescriptor.cpp Cydia/RepositorySecurityPolicy.cpp \
		Cydia/PackageDatabasePaths.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/PrivilegedRuntime.cpp \
		$(if $(filter Darwin,$(HOST_OS)),-framework Security -framework CoreFoundation) -o $@

verify-apt-runtime: $(APT_RUNTIME_TEST)
	@$<

$(REPOSITORY_SECURITY_TEST): tests/RepositorySecurityPolicyTests.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/RepositorySecurityPolicy.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/RepositorySecurityPolicyTests.cpp Cydia/RepositorySecurityPolicy.cpp -o $@

$(SOURCE_DOCUMENT_TEST): tests/SourceDocumentTests.cpp Cydia/SourceDocument.cpp \
		Cydia/SourceDocument.hpp Cydia/SourceDocumentStore.cpp Cydia/SourceDocumentStore.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/SourceDocumentTests.cpp Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp -o $@

.PHONY: verify-repository-security verify-source-documents verify-settings-localization
verify: verify-repository-security verify-source-documents verify-settings-localization
verify-repository-security: $(REPOSITORY_SECURITY_TEST)
	@$<
verify-source-documents: $(SOURCE_DOCUMENT_TEST)
	@$<
SOURCE_DRAFT_TEST := $(BUILD_DIR)/tests/SourceDraftTests
$(SOURCE_DRAFT_TEST): tests/SourceDraftTests.cpp Cydia/SourceDraft.cpp Cydia/SourceDraft.hpp \
        Cydia/SourceDocument.cpp Cydia/SourceDocument.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/SourceDraftTests.cpp Cydia/SourceDraft.cpp Cydia/SourceDocument.cpp -o $@
.PHONY: verify-source-drafts
verify: verify-source-drafts
verify-source-drafts: $(SOURCE_DRAFT_TEST)
	@$<
SOURCE_DISCOVERY_TEST := $(BUILD_DIR)/tests/SourceDiscoveryTests
$(SOURCE_DISCOVERY_TEST): tests/SourceDiscoveryTests.cpp Cydia/SourceDiscovery.cpp \
        Cydia/SourceDiscovery.hpp Cydia/SourcePreflight.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(if $(filter Linux,$(HOST_OS)),$(shell pkg-config --cflags libxml-2.0),-I$(mac)/usr/include/libxml2) \
		tests/SourceDiscoveryTests.cpp Cydia/SourceDiscovery.cpp -lxml2 -o $@
.PHONY: verify-source-discovery
verify: verify-source-discovery
verify-source-discovery: $(SOURCE_DISCOVERY_TEST)
	@$<
$(SOURCE_COMMIT_TEST): tests/SourceDocumentCommitTests.cpp Cydia/SourceDocumentCommit.cpp \
		Cydia/SourceDocumentCommit.hpp Cydia/SourceDocument.cpp Cydia/SourceDocument.hpp \
		Cydia/SourceDocumentStore.cpp Cydia/SourceDocumentStore.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/SourceDocumentCommitTests.cpp Cydia/SourceDocumentCommit.cpp \
		Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp -o $@
.PHONY: verify-source-commits
verify: verify-source-commits
verify-source-commits: $(SOURCE_COMMIT_TEST)
	@$<
verify-settings-localization:
	@python3 tests/SettingsLocalizationTests.py
	@python3 tests/SourcesLocalizationTests.py
	@python3 tests/ActionsLocalizationTests.py
	@python3 tests/RecoveryLocalizationTests.py
	@python3 tests/LocalizationAdditionTests.py

$(EXTENDED_STATE_TEST): tests/ExtendedStateTests.cpp Cydia/ExtendedState.cpp Cydia/ExtendedState.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/ExtendedStateTests.cpp Cydia/ExtendedState.cpp -o $@

$(PRIVILEGED_RUNTIME_TEST): tests/PrivilegedRuntimeTests.cpp Cydia/PrivilegedRuntime.cpp Cydia/PrivilegedRuntime.hpp Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/PrivilegedRuntimeTests.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp -o $@

$(PRIVILEGED_CLIENT_TEST): tests/PrivilegedClientTests.cpp Cydia/PrivilegedClient.mm \
		Cydia/PrivilegedClient.h Cydia/PrivilegedRuntime.cpp Cydia/PrivilegedRuntime.hpp \
		Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/AptProviderBrokerValues.cpp \
		Cydia/AptProviderSelectionValues.cpp Cydia/AptProviderDpkgState.cpp Cydia/AptProviderConditionalDeconfiguration.cpp Cydia/AptProviderRestorationDebt.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp Cydia/ExtendedState.cpp \
		Cydia/AptRecoverySnapshot.cpp Cydia/AptRecoverySnapshot.hpp \
		Cydia/PackageIdentity.cpp Cydia/AptRuntimeDescriptor.cpp Cydia/RepositorySecurityPolicy.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp \
		Cydia/DpkgConffile.cpp Cydia/DpkgConffile.hpp Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp \
		Cydia/AptProviderConffilePolicyValues.cpp Cydia/AptProviderConffilePolicy.hpp \
		Cydia/AptProviderTransactionChannel.cpp Cydia/AptProviderTransactionChannel.hpp \
		Cydia/AptProviderTransactionRequest.cpp Cydia/AptProviderTransactionRequest.hpp \
		Cydia/AptProviderEffectReviewBundle.cpp Cydia/AptProviderEffectReviewBundle.hpp \
		Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
		tests/apt-stubs/apt-pkg/fileutl.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -Itests/apt-stubs -I. \
		-x c++ $(filter %.cpp %.mm,$^) -pthread -o $@

$(CAPABILITY_PREVIEW_TEST): tests/CapabilityPreviewTests.cpp Cydia/CapabilityPreview.cpp Cydia/CapabilityPreview.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/CapabilityPreviewTests.cpp Cydia/CapabilityPreview.cpp -o $@

$(PRIVATE_STATE_DIRECTORY_TEST): tests/PrivateStateDirectoryTests.cpp \
		Cydia/PrivateStateDirectory.hpp Cydia/PrivateMetadataMigration.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/PrivateStateDirectoryTests.cpp -o $@

.PHONY: verify-extended-state verify-privileged-runtime verify-privileged-client verify-capabilities verify-shared-config-lifecycle verify-private-state
verify: verify-extended-state verify-privileged-runtime verify-privileged-client verify-capabilities verify-shared-config-lifecycle verify-private-state
verify-extended-state: $(EXTENDED_STATE_TEST)
	@$<
verify-privileged-runtime: $(PRIVILEGED_RUNTIME_TEST)
	@$<
	@$(ADMIN_PERMISSION_TEST)

ADMIN_PERMISSION_TEST := $(BUILD_DIR)/tests/DpkgAdminPermissionsTests
$(ADMIN_PERMISSION_TEST): tests/DpkgAdminPermissionsTests.cpp Cydia/DpkgAdminAccess.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $< -o $@
verify-privileged-runtime: $(ADMIN_PERMISSION_TEST)

APPLICATION_IDENTITY_TEST := $(BUILD_DIR)/tests/ApplicationIdentityTests
$(APPLICATION_IDENTITY_TEST): tests/ApplicationIdentityTests.cpp Cydia/ApplicationIdentity.hpp Cydia/ApplicationSession.hpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/ApplicationIdentityTests.cpp Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp -o $@
.PHONY: verify-application-identity
verify: verify-application-identity
verify-application-identity: $(APPLICATION_IDENTITY_TEST)
	@$<
	@python3 tests/ApplicationSigningIdentityTests.py $(APPLICATION_IDENTITY_TEST)

TRANSACTION_OUTCOME_POLICY_TEST := $(BUILD_DIR)/tests/TransactionOutcomePolicyTests
$(TRANSACTION_OUTCOME_POLICY_TEST): tests/TransactionOutcomePolicyTests.cpp Cydia/TransactionOutcomePolicy.hpp \
		Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/PackageDatabasePaths.cpp Cydia/TransactionResult.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/TransactionOutcomePolicyTests.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/PackageDatabasePaths.cpp -o $@
.PHONY: verify-transaction-outcome-policy
verify: verify-transaction-outcome-policy
verify-transaction-outcome-policy: $(TRANSACTION_OUTCOME_POLICY_TEST)
	@$<
verify-privileged-client: $(PRIVILEGED_CLIENT_TEST)
APT_TRANSACTION_CHANNEL_TEST := $(BUILD_DIR)/tests/AptProviderTransactionChannelTests
$(APT_TRANSACTION_CHANNEL_TEST): tests/AptProviderTransactionChannelTests.cpp Cydia/AptProviderTransactionChannel.cpp Cydia/AptProviderTransactionChannel.hpp \
		Cydia/AptProviderConffilePolicyValues.cpp Cydia/AptProviderConffilePolicy.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -pthread -o $@
verify-privileged-client: $(APT_TRANSACTION_CHANNEL_TEST)
	@$(PRIVILEGED_CLIENT_TEST)
	@$(APT_TRANSACTION_CHANNEL_TEST)
verify-capabilities: $(CAPABILITY_PREVIEW_TEST)
	@$<
	@bash tests/FirmwareDiscoveryTests.sh
	@python3 tests/FirmwareDiscoveryCoverageTests.py
SHARED_CONFIG_HANDOFF_TEST := $(BUILD_DIR)/tests/SharedConfigHandoffTests
$(SHARED_CONFIG_HANDOFF_TEST): tests/SharedConfigHandoffTests.cpp Cydia/SharedConfigHandoff.hpp \
		Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/DpkgRunner.h Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(filter %.cpp,$^) -o $@
verify-shared-config-lifecycle: $(SHARED_CONFIG_HANDOFF_TEST)
	@$(SHARED_CONFIG_HANDOFF_TEST)
	@python3 tests/SharedConfigLifecycleTests.py
verify-private-state: $(PRIVATE_STATE_DIRECTORY_TEST)
	@$<

RUNTIME_SNAPSHOT_TEST := $(BUILD_DIR)/tests/RuntimeSnapshotInputsTests
$(RUNTIME_SNAPSHOT_TEST): tests/RuntimeSnapshotInputsTests.cpp Cydia/RuntimeSnapshotInputs.cpp \
		Cydia/RuntimeSnapshotInputs.hpp Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp \
		Cydia/AptProviderTriggerEvidenceCapture.cpp Cydia/AptProviderTriggerEvidence.hpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++17 -Wall -Wextra -Werror -I. \
		$(filter %.cpp,$^) -pthread -o $@
.PHONY: verify-runtime-snapshot
verify: verify-runtime-snapshot
verify-runtime-snapshot: $(RUNTIME_SNAPSHOT_TEST)
	@$<

REPOSITORY_TRUST_PROOF_TEST := $(BUILD_DIR)/tests/RepositoryTrustProofTests
$(REPOSITORY_TRUST_PROOF_TEST): tests/RepositoryTrustProofTests.cpp Cydia/RepositoryTrustProof.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $< -o $@
.PHONY: verify-repository-trust-proof
verify: verify-repository-trust-proof
verify-repository-trust-proof: $(REPOSITORY_TRUST_PROOF_TEST)
	@$<

RUNTIME_ACCESS_TEST := $(BUILD_DIR)/tests/RuntimeAccessTests
$(RUNTIME_ACCESS_TEST): tests/RuntimeAccessTests.cpp Cydia/RuntimeAccessController.mm Cydia/RuntimeAccessController.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		-x c++ -DCYDIA_RUNTIME_ACCESS_TEST tests/RuntimeAccessTests.cpp Cydia/RuntimeAccessController.mm -o $@
.PHONY: verify-runtime-access
verify: verify-runtime-access
verify-runtime-access: $(RUNTIME_ACCESS_TEST)
	@$<

KEYRING_IMPORT_TEST := $(BUILD_DIR)/tests/KeyringImportTests
RECOVERY_PLAN_TEST := $(BUILD_DIR)/tests/RecoveryPlanTests
RECOVERY_PRIVILEGED_TEST := $(BUILD_DIR)/tests/RecoveryPrivilegedTests

$(KEYRING_IMPORT_TEST): tests/KeyringImportTests.cpp Cydia/KeyringImport.cpp Cydia/KeyringImport.hpp \
		Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp Cydia/SourceDocumentCommit.cpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(filter %.cpp,$^) -o $@

$(RECOVERY_PLAN_TEST): tests/RecoveryPlanTests.cpp Cydia/RecoveryPlan.cpp Cydia/RecoveryPlan.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		tests/RecoveryPlanTests.cpp Cydia/RecoveryPlan.cpp -o $@

$(RECOVERY_PRIVILEGED_TEST): tests/RecoveryPrivilegedTests.cpp \
		Cydia/RecoveryPrivileged.cpp Cydia/RecoveryPrivileged.hpp Cydia/RecoveryPlan.cpp Cydia/RecoveryPlan.hpp \
		Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp Cydia/SourceDocumentCommit.cpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PackageDatabasePaths.cpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(filter %.cpp,$^) -o $@

.PHONY: verify-keyring-import verify-recovery-plan verify-recovery-backups verify-actions-localization
verify: verify-keyring-import verify-recovery-plan
verify-keyring-import: $(KEYRING_IMPORT_TEST)
	@$<
verify-recovery-plan: $(RECOVERY_PLAN_TEST)
	@$<
ifneq ($(HOST_OS),Linux)
verify: verify-recovery-backups
verify-recovery-backups: $(RECOVERY_PRIVILEGED_TEST)
	@$<
endif
verify-actions-localization:
	@python3 tests/ActionsLocalizationTests.py

$(LEGACY_SOURCE_HANDOFF_TEST): tests/LegacySourceHandoffTests.cpp \
		Cydia/LegacySourceHandoff.cpp Cydia/LegacySourceHandoff.hpp \
		Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/LegacySourceHandoffTests.cpp Cydia/LegacySourceHandoff.cpp \
		Cydia/PackageDatabasePaths.cpp -o $@

verify-legacy-source-handoff: $(LEGACY_SOURCE_HANDOFF_TEST)
	@$<

$(LEGACY_CYDIA_SOURCE_ALIAS_TEST): tests/LegacyCydiaSourceAliasTests.cpp \
		Cydia/LegacyCydiaSourceAlias.cpp Cydia/LegacyCydiaSourceAlias.hpp \
		Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. \
		$(filter %.cpp,$^) -o $@

.PHONY: verify-legacy-cydia-source-alias
verify: verify-legacy-cydia-source-alias
verify-legacy-cydia-source-alias: $(LEGACY_CYDIA_SOURCE_ALIAS_TEST)
	@$<

verify-apt-source-isolation: $(APT_SOURCE_CONTRACT_SCRIPT) $(LEGACY_SOURCE_HANDOFF_TEST)
	@$(LEGACY_SOURCE_HANDOFF_TEST)
	@$(APT_SOURCE_CONTRACT_SCRIPT)

verify-apt-sourcelist-mtime: $(APT_SOURCE_LIST_MTIME_CONTRACT_SCRIPT) \
		apt64/apt-pkg/sourcelist.cc apt64/test/libapt/sourcelist_test.cc
	@$(APT_SOURCE_LIST_MTIME_CONTRACT_SCRIPT)

$(DPKG_RUNNER_TEST): tests/DpkgRunnerTests.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/DpkgRunner.h Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/DpkgRunnerTests.cpp Cydia/DpkgRunner.cpp Cydia/NativeLaunchEnvironment.cpp Cydia/PackageDatabasePaths.cpp -o $@

verify-dpkg-runner: $(DPKG_RUNNER_TEST)
	@$<

$(DPKG_STATUS_TEST): tests/DpkgStatusParserTests.cpp Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/DpkgStatusParserTests.cpp Cydia/DpkgStatusParser.cpp -o $@
$(DPKG_CONFFILE_TEST): tests/DpkgConffileTests.cpp Cydia/DpkgConffile.cpp Cydia/DpkgConffile.hpp \
		Cydia/AptProviderConffilePolicyValues.cpp Cydia/AptProviderConffilePolicy.hpp \
		Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Werror -I. $(filter %.cpp,$^) -pthread -o $@
.PHONY: verify-dpkg-conffile
verify: verify-dpkg-conffile
verify-dpkg-conffile: $(DPKG_CONFFILE_TEST)
	@$<

verify-dpkg-status: $(DPKG_STATUS_TEST)
	@$<

$(BUILD_DIR)/tests/FirmwareMarkerPermissionsTests: tests/FirmwareMarkerPermissionsTests.cpp Cydia/FirmwareMarkerPermissions.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. $< -o $@

verify-bootstrap-helpers: $(BUILD_DIR)/tests/FirmwareMarkerPermissionsTests
	@$(BUILD_DIR)/tests/FirmwareMarkerPermissionsTests
	@tests/BootstrapHelpersTests.sh

verify-home-localization: $(HOME_LOCALIZATION_VERIFY_SCRIPT)
	@$(HOME_LOCALIZATION_VERIFY_SCRIPT)

ifeq ($(HOST_OS),Darwin)
$(MESSAGE_LOCALE_DECLARATIONS_TEST): host_cxx_flags += -DCYDIA_USE_ICU_LOCALE_DECLARATIONS=1
$(MESSAGE_LOCALE_TEST) $(MESSAGE_LOCALE_DECLARATIONS_TEST): tests/MessageLocaleTests.mm Cydia/MessageLocale.h Cydia/MessageLocale.mm \
		Cydia/MessageLocaleConversion.h Cydia/MessageLocaleConversion.mm Cydia/ICULocale.h Cydia/ICURuntime.hpp Cydia/ICURuntime.cpp Cydia/ProtectedLibraryPath.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		-idirafter $(ICU_INCLUDE_DIR) tests/MessageLocaleTests.mm Cydia/MessageLocale.mm \
		Cydia/MessageLocaleConversion.mm Cydia/ICURuntime.cpp -framework Foundation -licucore -o $@

verify-message-locale: $(MESSAGE_LOCALE_TEST) $(MESSAGE_LOCALE_DECLARATIONS_TEST)
	@$(MESSAGE_LOCALE_TEST)
	@$(MESSAGE_LOCALE_DECLARATIONS_TEST)

$(REGEX_ARC_TEST): tests/RegExArcTests.mm CyteKit/RegEx.hpp CyteKit/stringWith.h CyteKit/stringWith.mm Cydia/ICURuntime.hpp Cydia/ICURuntime.cpp Cydia/ProtectedLibraryPath.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		-idirafter $(ICU_INCLUDE_DIR) tests/RegExArcTests.mm CyteKit/stringWith.mm Cydia/ICURuntime.cpp -framework Foundation -licucore -o $@

verify-regex-arc: $(REGEX_ARC_TEST)
	@$<

$(YIELD_TO_SELECTOR_TEST): tests/YieldToSelectorTests.mm \
		Menes/yieldToSelector.h Menes/yieldToSelector.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/YieldToSelectorTests.mm Menes/yieldToSelector.mm \
		-framework Foundation -o $@

verify-yield-to-selector: $(YIELD_TO_SELECTOR_TEST)
	@$<
else
verify-message-locale:
	@echo "[verify] Message locale runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-regex-arc:
	@echo "[verify] RegEx ARC runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-yield-to-selector:
	@echo "[verify] yieldToSelector runtime test requires a Darwin host; iOS compile coverage remains enabled"
endif

verify-legacy-ui-compatibility-inventory: $(LEGACY_UI_COMPATIBILITY_INVENTORY_CONTRACT_SCRIPT) \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgeProperties.def \
		tests/fixtures/ui/legacy-api.tsv tests/fixtures/ui/legacy-properties.tsv
	@$(LEGACY_UI_COMPATIBILITY_INVENTORY_CONTRACT_SCRIPT)

verify-url-origin-validation-contract: $(URL_ORIGIN_VALIDATION_CONTRACT_SCRIPT) \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		Cydia/PackageDepictionPolicy.mm Cydia/UIRouteContext.mm \
		Cydia/UIRouteDispatch.mm tests/fixtures/ui/route-dispatch.tsv
	@$(URL_ORIGIN_VALIDATION_CONTRACT_SCRIPT)

verify-native-ui-contract: verify-legacy-ui-compatibility-inventory \
		verify-url-origin-validation-contract \
		verify-ui-color-appearance \
		$(NATIVE_UI_VERIFY_SCRIPT) mk/ui-webkit-legacy.txt \
		mk/ui-route-legacy-callers.txt tests/fixtures/ui/routes.tsv \
		tests/fixtures/ui/route-dispatch.tsv tests/fixtures/ui/legacy-api.tsv \
		tests/fixtures/ui/legacy-properties.tsv \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgePolicy.h \
		Cydia/LegacyBridgeProperties.def Cydia/LegacyBridgePolicy.mm \
		Cydia/LegacyUICompatibilitySignatures.def \
		Cydia/LegacyUICompatibility.h Cydia/LegacyUICompatibility.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		Cydia/ExternalURLController.h Cydia/ExternalURLController.mm \
		Cydia/ErrorViewModel.h Cydia/ErrorViewModel.mm \
		Cydia/ErrorViewController.h Cydia/ErrorViewController.mm \
		Cydia/Application.h Cydia/Application+Lifecycle.mm \
		Cydia/Application+Navigation.mm MobileCydia.mm \
		Cydia/HomeController.mm Cydia/PackageControllers.mm \
		Cydia/Package.mm Cydia/Source.mm Cydia/Relations.mm \
		Cydia/MIMEAddress.mm Cydia/ProgressData.mm Cydia/ProgressEvent.mm \
		Cydia/ConfirmationController.mm Cydia/ProgressController.mm \
		Cydia/HomeController.h Cydia/HomeController.mm \
		Cydia/HomeControllerProbe.h Cydia/HomeControllerProbe.mm \
		Cydia/HomeProbeURLProtocol.h Cydia/HomeProbeURLProtocol.mm \
		Cydia/HomeTableAppearance.h Cydia/HomeTableAppearance.mm \
		Cydia/HomeViewModel.h Cydia/HomeViewModel.mm
	@$(NATIVE_UI_VERIFY_SCRIPT) all

verify-ui-color-appearance: $(UI_COLOR_APPEARANCE_VERIFY_SCRIPT) Cydia/UIColor+Cydia.m
	@$(UI_COLOR_APPEARANCE_VERIFY_SCRIPT)

verify-no-remote-app-ui: $(NO_REMOTE_APP_UI_VERIFY_SCRIPT) \
		Cydia/AppState.h MobileCydia.mm Cydia/Application+Navigation.mm \
		Cydia/HomeController.mm Cydia/ConfirmationController.mm \
		Cydia/ProgressController.mm Cydia/PackageControllers.mm \
		Cydia/PackageDetailController.mm Cydia/PackageDepictionView.h \
		Cydia/PackageDepictionView.mm Cydia/ExternalURLController.mm \
		Cydia/ErrorViewController.mm
	@$(NO_REMOTE_APP_UI_VERIFY_SCRIPT)

verify-window-appearance: $(WINDOW_APPEARANCE_VERIFY_SCRIPT) \
        MobileCydia.app/Info.plist Cydia/Appearance.h Cydia/Appearance.mm MobileCydia.mm \
        Cydia/Application+Lifecycle.mm Cydia/TabBarController.mm \
        Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@$(WINDOW_APPEARANCE_VERIFY_SCRIPT)

verify-url-cache: $(URL_CACHE_VERIFY_SCRIPT) \
		CyteKit/URLCache.h CyteKit/URLCache.mm CyteKit/Application.mm
	@$(URL_CACHE_VERIFY_SCRIPT)

ifeq ($(HOST_OS),Darwin)
$(UI_ROUTE_CONTEXT_TEST): tests/UIRouteContextTests.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/UIRouteContextTests.mm Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-ui-route-context: $(UI_ROUTE_CONTEXT_TEST) tests/fixtures/ui/routes.tsv
	@$< tests/fixtures/ui/routes.tsv

$(EXTERNAL_URL_POLICY_TEST): tests/ExternalURLPolicyTests.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/ExternalURLPolicyTests.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-external-url-policy: $(EXTERNAL_URL_POLICY_TEST)
	@$<

verify-external-url-controller: $(EXTERNAL_URL_CONTROLLER_VERIFY_SCRIPT) \
		Cydia/ExternalURLController.h Cydia/ExternalURLController.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		tests/simulator/ExternalURLControllerProbe.h \
		tests/simulator/ExternalURLControllerProbe.mm Cydia/AppearanceProbe.mm \
		Cydia/Application+Navigation.mm Cydia/HomeController.mm \
		Cydia/PackageControllers.mm mk/toolchain.mk
	@$(EXTERNAL_URL_CONTROLLER_VERIFY_SCRIPT)
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/external-url-simulator-ios12" \
		doIA=yes doExternalURLProbe=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/external-url-simulator-ios12/objects/Cydia/ExternalURLPolicy.o" \
		"$(BUILD_DIR)/external-url-simulator-ios12/objects/Cydia/ExternalURLController.o" \
		"$(BUILD_DIR)/external-url-simulator-ios12/objects/tests/simulator/ExternalURLControllerProbe.o" \
		"$(BUILD_DIR)/external-url-simulator-ios12/objects/Cydia/AppearanceProbe.o"

$(LEGACY_BRIDGE_POLICY_TEST): tests/LegacyBridgePolicyTests.mm \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgePolicy.h \
		Cydia/LegacyBridgeProperties.def Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h tests/fixtures/ui/trusted-local.html
	@mkdir -p $(dir $@)
	@cp tests/fixtures/ui/trusted-local.html $(dir $@)trusted-local.html
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/LegacyBridgePolicyTests.mm Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-legacy-bridge-policy: $(LEGACY_BRIDGE_POLICY_TEST) \
		tests/fixtures/ui/legacy-api.tsv tests/fixtures/ui/legacy-properties.tsv
	@$< tests/fixtures/ui/legacy-api.tsv tests/fixtures/ui/legacy-properties.tsv

$(LEGACY_UI_COMPATIBILITY_TEST): tests/LegacyUICompatibilityTests.mm \
		Cydia/LegacyUICompatibilitySignatures.def \
		Cydia/LegacyUICompatibility.h Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgeProperties.def \
		Cydia/LegacyBridgePolicy.h Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h tests/fixtures/ui/trusted-local.html
	@mkdir -p $(dir $@)
	@cp tests/fixtures/ui/trusted-local.html $(dir $@)trusted-local.html
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/LegacyUICompatibilityTests.mm \
		Cydia/LegacyUICompatibility.mm Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-legacy-ui-compatibility: $(LEGACY_UI_COMPATIBILITY_TEST)
	@$<

$(LEGACY_UI_COMPATIBILITY_FORMAT_TEST): tests/LegacyUICompatibilityFormatTests.mm \
		Cydia/LegacyUICompatibility.h Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgeProperties.def \
		Cydia/LegacyBridgePolicy.h Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/LegacyUICompatibilityFormatTests.mm \
		Cydia/LegacyUICompatibility.mm Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-legacy-ui-compatibility-format: $(LEGACY_UI_COMPATIBILITY_FORMAT_TEST) \
		$(LEGACY_UI_COMPATIBILITY_FORMAT_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_FORMAT_CONTRACT_SCRIPT)
	@$<

$(LEGACY_UI_COMPATIBILITY_NATIVE_TEST): tests/LegacyUICompatibilityNativeCallerTests.mm \
		Cydia/LegacyUICompatibilityNativeCaller.h Cydia/LegacyUICompatibilityNativeCaller.mm \
		Cydia/LegacyUICompatibilityNativeSnapshot.h Cydia/LegacyUICompatibilityNativeSnapshot.mm \
		Cydia/LegacyUICompatibility.h Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgeProperties.def \
		Cydia/LegacyUICompatibilitySignatures.def \
		Cydia/LegacyBridgePolicy.h Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/UIRouteDispatch.h Cydia/UIRouteDispatch.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks -Wall -Wextra -I. \
		tests/LegacyUICompatibilityNativeCallerTests.mm \
		Cydia/LegacyUICompatibilityNativeCaller.mm Cydia/LegacyUICompatibilityNativeSnapshot.mm \
		Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgePolicy.mm Cydia/UIRouteContext.mm Cydia/UIRouteDispatch.mm \
		Cydia/ExternalURLPolicy.mm -framework Foundation -o $@

verify-legacy-ui-compatibility-native: $(LEGACY_UI_COMPATIBILITY_NATIVE_TEST) \
		$(LEGACY_UI_COMPATIBILITY_NATIVE_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_NATIVE_CONTRACT_SCRIPT)
	@$<

$(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_TEST): tests/LegacyUICompatibilityNativeSnapshotTests.mm \
		Cydia/LegacyUICompatibilityNativeSnapshot.h Cydia/LegacyUICompatibilityNativeSnapshot.mm \
		Cydia/LegacyUICompatibilityNativeCaller.h Cydia/LegacyUICompatibilityNativeCaller.mm \
		Cydia/LegacyUICompatibility.h Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgeOperations.def Cydia/LegacyBridgeProperties.def \
		Cydia/LegacyUICompatibilitySignatures.def \
		Cydia/LegacyBridgePolicy.h Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/UIRouteDispatch.h Cydia/UIRouteDispatch.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks -Wall -Wextra -I. \
		tests/LegacyUICompatibilityNativeSnapshotTests.mm \
		Cydia/LegacyUICompatibilityNativeCaller.mm Cydia/LegacyUICompatibilityNativeSnapshot.mm \
		Cydia/LegacyUICompatibility.mm Cydia/LegacyBridgePolicy.mm \
		Cydia/UIRouteContext.mm Cydia/UIRouteDispatch.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-legacy-ui-compatibility-native-snapshot: $(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_TEST) \
		$(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_CONTRACT_SCRIPT)
	@$<

verify-legacy-ui-compatibility-native-provider: $(LEGACY_UI_COMPATIBILITY_NATIVE_PROVIDER_CONTRACT_SCRIPT) \
		Cydia/LegacyUICompatibilityNativeProvider.h Cydia/LegacyUICompatibilityNativeProvider.mm \
		Cydia/NativeMutationConfirmation.h Cydia/NativeMutationConfirmation.mm \
		Cydia/LegacyUICompatibilityNativeProvider+Application.mm \
		Cydia/LegacyUICompatibilityNativeRenderingProvider.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		Cydia/Application.h MobileCydia.mm Cydia/Application+Lifecycle.mm
	@$(LEGACY_UI_COMPATIBILITY_NATIVE_PROVIDER_CONTRACT_SCRIPT)

verify-legacy-ui-compatibility-native-consumer: $(LEGACY_UI_COMPATIBILITY_NATIVE_CONSUMER_CONTRACT_SCRIPT) \
		Cydia/Application.h Cydia/Application+Data.mm MobileCydia.mm \
		Cydia/NativeMutationDiagnostic.h Cydia/NativeMutationDiagnostic.mm \
		tests/NativePackageMutationDiagnosticTests.sh tests/NativePackageMutationDiagnosticTests.mm \
		Cydia/LegacyUICompatibilityNativeProvider+Application.mm
	@$(LEGACY_UI_COMPATIBILITY_NATIVE_CONSUMER_CONTRACT_SCRIPT)

$(LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_TEST): tests/LegacyUICompatibilityRuntimeEvidenceTests.mm \
		Cydia/LegacyUICompatibilityRuntimeEvidence.h Cydia/LegacyUICompatibilityRuntimeEvidence.mm \
		Cydia/LegacyUICompatibilityNativeCaller.h Cydia/LegacyUICompatibility.h \
		Cydia/LegacyUICompatibility.mm Cydia/LegacyBridgeOperations.def \
		Cydia/LegacyBridgeProperties.def Cydia/LegacyBridgePolicy.h \
		Cydia/LegacyBridgePolicy.mm Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/LegacyUICompatibilityRuntimeEvidenceTests.mm \
		Cydia/LegacyUICompatibilityRuntimeEvidence.mm Cydia/LegacyUICompatibility.mm \
		Cydia/LegacyBridgePolicy.mm Cydia/UIRouteContext.mm Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-legacy-ui-compatibility-runtime-evidence: $(LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_TEST) \
		$(LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_RUNTIME_EVIDENCE_CONTRACT_SCRIPT)
	@$<

.PHONY: verify-native-mutation-evidence
verify: verify-native-mutation-evidence

.PHONY: verify-native-accessibility-trace
verify: verify-native-accessibility-trace

$(BUILD_DIR)/tests/NativeAccessibilityJournalTests: tests/NativeAccessibilityJournalTests.mm \
		Cydia/NativeAccessibilityJournal.h Cydia/NativeAccessibilityJournal.mm \
		Cydia/NativeAccessibilityColor.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/NativeAccessibilityJournalTests.mm Cydia/NativeAccessibilityJournal.mm \
		-framework Foundation -o $@

verify-native-accessibility-trace: $(BUILD_DIR)/tests/NativeAccessibilityJournalTests \
		tests/NativeAccessibilityTraceContractTests.sh Cydia/NativeAccessibilityTrace.mm
	@sh tests/NativeAccessibilityTraceContractTests.sh
	@trace_test_dir=$$(mktemp -d "$(abspath $(BUILD_DIR))/tests/native-ax.XXXXXX"); \
		"$<" "$$trace_test_dir"

$(BUILD_DIR)/tests/NativeMutationEvidenceTests: tests/NativeMutationEvidenceTests.mm \
		Cydia/NativeMutationEvidence.h Cydia/NativeMutationEvidence.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/NativeMutationEvidenceTests.mm Cydia/NativeMutationEvidence.mm \
		-framework Foundation -o $@

verify-native-mutation-evidence: $(BUILD_DIR)/tests/NativeMutationEvidenceTests \
		tests/NativeMutationEvidenceContractTests.sh \
		scripts/verify-native-mutation-evidence.sh \
		Cydia/NativeMutationConfirmation.mm Cydia/LegacyUICompatibilityNativeProvider.mm
	@sh tests/NativeMutationEvidenceContractTests.sh
	@$< scripts/verify-native-mutation-evidence.sh

verify-package-controller-native-consumer: $(PACKAGE_CONTROLLER_NATIVE_CONSUMER_CONTRACT_SCRIPT) \
		Cydia/PackageControllers.h Cydia/PackageControllers.mm
	@$(PACKAGE_CONTROLLER_NATIVE_CONSUMER_CONTRACT_SCRIPT)

$(UI_ROUTE_DISPATCH_TEST): tests/UIRouteDispatchTests.mm \
		Cydia/UIRouteDispatch.h Cydia/UIRouteDispatch.mm \
		Cydia/UIRouteContext.h Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm \
		CyteKit/WebNavigationContext.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks \
		-Wall -Wextra -I. tests/UIRouteDispatchTests.mm \
		Cydia/UIRouteDispatch.mm Cydia/UIRouteContext.mm \
		Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-ui-route-dispatch: $(UI_ROUTE_DISPATCH_TEST) tests/fixtures/ui/route-dispatch.tsv
	@$< tests/fixtures/ui/route-dispatch.tsv

$(UI_RESTORATION_STATE_TEST): tests/RestorationStateTests.mm \
		Cydia/UIRestorationState.h Cydia/UIRestorationState.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/RestorationStateTests.mm Cydia/UIRestorationState.mm \
		-framework Foundation -o $@

verify-ui-restoration-state: $(UI_RESTORATION_STATE_TEST)
	@$<

$(PACKAGE_DETAIL_VIEW_MODEL_TEST): tests/PackageDetailViewModelTests.mm \
		Cydia/PackageDetailViewModel.h Cydia/PackageDetailViewModel.mm \
		Cydia/PackageArchitecturePresentation.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/PackageDetailViewModelTests.mm Cydia/PackageDetailViewModel.mm \
		-framework Foundation -o $@

verify-package-detail-view-model: $(PACKAGE_DETAIL_VIEW_MODEL_TEST)
	@$<

$(BUILD_DIR)/tests/RepositoryPackagePresentationTests: tests/RepositoryPackagePresentationTests.mm \
		Cydia/RepositoryPackagePresentation.h Cydia/RepositoryPackagePresentation.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/RepositoryPackagePresentationTests.mm Cydia/RepositoryPackagePresentation.mm \
		-framework Foundation -o $@

verify-repository-package-presentation: $(BUILD_DIR)/tests/RepositoryPackagePresentationTests
	@$<

verify: verify-repository-package-presentation

$(PACKAGE_DEPICTION_FACADE_TEST): tests/PackageDepictionJavaScriptFacadeTests.mm \
		Cydia/PackageDepictionJavaScriptFacade.h Cydia/PackageDepictionJavaScriptFacade.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks -Wall -Wextra -I. \
		tests/PackageDepictionJavaScriptFacadeTests.mm \
		Cydia/PackageDepictionJavaScriptFacade.mm \
		-framework Foundation -framework WebKit -o $@

verify-package-depiction-facade: $(PACKAGE_DEPICTION_FACADE_TEST)
	@$<

$(PACKAGE_DEPICTION_POLICY_TEST): tests/PackageDepictionPolicyTests.mm \
		Cydia/PackageDepictionPolicy.h Cydia/PackageDepictionPolicy.mm \
		Cydia/ExternalURLPolicy.h Cydia/ExternalURLPolicy.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/PackageDepictionPolicyTests.mm Cydia/PackageDepictionPolicy.mm \
		Cydia/ExternalURLPolicy.mm \
		-framework Foundation -o $@

verify-package-depiction-policy: $(PACKAGE_DEPICTION_POLICY_TEST)
	@$<

$(PACKAGE_LEGACY_METADATA_POLICY_TEST): tests/PackageLegacyMetadataPolicyTests.mm \
		Cydia/PackageLegacyMetadataPolicy.h Cydia/PackageLegacyMetadataPolicy.mm \
		tests/fixtures/ui/package-api/choicy.response
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks -Wall -Wextra -I. \
		tests/PackageLegacyMetadataPolicyTests.mm \
		Cydia/PackageLegacyMetadataPolicy.mm \
		-framework Foundation -o $@

verify-package-legacy-metadata-policy: $(PACKAGE_LEGACY_METADATA_POLICY_TEST)
	@$< tests/fixtures/ui/package-api/choicy.response

$(URL_PROTOCOL_POLICY_TEST): tests/URLProtocolPolicyTests.mm \
		Cydia/URLProtocolPolicy.h Cydia/URLProtocolPolicy.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/URLProtocolPolicyTests.mm Cydia/URLProtocolPolicy.mm \
		-framework Foundation -o $@

verify-url-protocol-policy: $(URL_PROTOCOL_POLICY_TEST) \
		$(URL_PROTOCOL_POLICY_CONTRACT_SCRIPT) Cydia/URLProtocol.mm \
		Cydia/URLResourceResolver.h Cydia/URLResourceResolver.mm \
		CyteKit/URLProtocol.mm
	@$<
	@$(URL_PROTOCOL_POLICY_CONTRACT_SCRIPT)

verify-package-depiction-view: $(PACKAGE_DEPICTION_VIEW_VERIFY_SCRIPT) \
	 Cydia/PackageDepictionView.h Cydia/PackageDepictionView.mm \
	 Cydia/PackageDepictionJavaScriptFacade.h Cydia/PackageDepictionJavaScriptFacade.mm \
	 Cydia/PackageDepictionPolicy.h Cydia/PackageDepictionPolicy.mm \
		Cydia/URLResourceResolver.h Cydia/URLResourceResolver.mm
	@$(PACKAGE_DEPICTION_VIEW_VERIFY_SCRIPT)
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/package-depiction-simulator-ios12" \
		doIA=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/package-depiction-simulator-ios12/objects/Cydia/PackageDepictionView.o" \
		"$(BUILD_DIR)/package-depiction-simulator-ios12/objects/Cydia/PackageDepictionJavaScriptFacade.o" \
		"$(BUILD_DIR)/package-depiction-simulator-ios12/objects/Cydia/URLResourceResolver.o" \
		"$(BUILD_DIR)/package-depiction-simulator-ios12/objects/Cydia/URLProtocol.o"

verify-package-detail-controller: $(PACKAGE_DETAIL_CONTROLLER_VERIFY_SCRIPT) \
		Cydia/PackageDetailController.h Cydia/PackageDetailController.mm \
		Cydia/PackageDetailDepictionCell.h Cydia/PackageDetailDepictionCell.mm \
		Cydia/PackageDetailViewModel.h Cydia/PackageDetailViewModel.mm \
		Cydia/PackageSupportController.h Cydia/PackageSupportController.mm \
		Cydia/PackageDetailControllerProbe.h Cydia/PackageDetailControllerProbe.mm \
		Cydia/AppearanceProbe.mm \
		Cydia/Application+Navigation.mm Cydia/PackageControllers.mm \
		MobileCydia.app/settings.png MobileCydia.app/email.png \
		MobileCydia.app/console.png MobileCydia.app/warning.png \
		MobileCydia.app/web.png MobileCydia.app/version.png \
		MobileCydia.app/filesystem.png \
		MobileCydia.app/Modes/DOWNGRADE.png MobileCydia.app/Modes/INSTALL.png \
		MobileCydia.app/Modes/PURGE.png MobileCydia.app/Modes/REINSTALL.png \
		MobileCydia.app/Modes/REMOVE.png MobileCydia.app/Modes/UPGRADE.png
	@$(PACKAGE_DETAIL_CONTROLLER_VERIFY_SCRIPT)

verify-package-detail-contact: $(PACKAGE_DETAIL_CONTACT_VERIFY_SCRIPT) \
		Cydia/PackageDetailController.mm
	@$(PACKAGE_DETAIL_CONTACT_VERIFY_SCRIPT)

verify-package-detail-controller-simulator:
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/package-detail-simulator-ios12" \
		doIA=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/package-detail-simulator-ios12/objects/Cydia/PackageDetailController.o" \
		"$(BUILD_DIR)/package-detail-simulator-ios12/objects/Cydia/PackageDetailDepictionCell.o" \
		"$(BUILD_DIR)/package-detail-simulator-ios12/objects/Cydia/PackageControllers.o" \
		"$(BUILD_DIR)/package-detail-simulator-ios12/objects/tests/PackageDetailControllerSimulatorCompile.o"

$(CONFIRMATION_VIEW_MODEL_TEST): tests/ConfirmationViewModelTests.mm \
		Cydia/ConfirmationViewModel.h Cydia/ConfirmationViewModel.mm \
		Cydia/AptCompatibility.hpp Cydia/PackageArchitecturePresentation.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks \
		-Wall -Wextra -I. tests/ConfirmationViewModelTests.mm \
		Cydia/ConfirmationViewModel.mm -framework Foundation -o $@

verify-confirmation-view-model: $(CONFIRMATION_VIEW_MODEL_TEST)
	@$<

$(TRANSACTION_REVIEW_TEST): tests/TransactionReviewTests.mm \
		Cydia/AptProviderEffectReviewBundle.cpp Cydia/AptProviderDeconfigurationApproval.cpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/TransactionReview.mm Cydia/TransactionReview.h Cydia/AptRuntimeDescriptor.hpp \
		Cydia/AptProviderTransactionRequest.cpp \
		Cydia/ExtendedState.cpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderProtocol.hpp \
		Cydia/AptProviderValues.cpp Cydia/PackageIdentity.cpp \
		Cydia/RepositorySecurityPolicy.cpp Cydia/PackageArchitecturePresentation.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks \
		-Wall -Wextra -I. $(filter %.mm %.cpp,$^) -framework Foundation -o $@

verify-transaction-review: $(TRANSACTION_REVIEW_TEST)
	@$<

$(FETCH_DIAGNOSTICS_TEST): tests/FetchDiagnosticsTests.mm \
		Cydia/FetchDiagnostics.mm Cydia/FetchDiagnostics.h Cydia/AptCompatibility.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc \
		-Wall -Wextra -I. $(filter %.mm,$^) -framework Foundation -o $@

verify-fetch-diagnostics: $(FETCH_DIAGNOSTICS_TEST)
	@$<

$(CONFIRMATION_CONTROLLER_TEST): tests/ConfirmationControllerContractTests.mm \
		Cydia/ConfirmationViewModel.h Cydia/ConfirmationViewModel.mm \
		Cydia/AptCompatibility.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks \
		-Wall -Wextra -I. tests/ConfirmationControllerContractTests.mm \
		Cydia/ConfirmationViewModel.mm -framework Foundation -o $@

verify-confirmation-controller: $(CONFIRMATION_CONTROLLER_TEST)
	@$<

verify-confirmation-controller-appearance: $(CONFIRMATION_CONTROLLER_APPEARANCE_VERIFY_SCRIPT) \
		Cydia/ConfirmationController.h Cydia/ConfirmationController.mm \
		Cydia/ConfirmationControllerProbe.mm
	@$(CONFIRMATION_CONTROLLER_APPEARANCE_VERIFY_SCRIPT)

verify-confirmation-controller-simulator:
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/confirmation-simulator-ios12" \
		doIA=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/confirmation-simulator-ios12/objects/Cydia/ConfirmationController.o" \
		"$(BUILD_DIR)/confirmation-simulator-ios12/objects/tests/ConfirmationControllerSimulatorCompile.o"

$(HOME_VIEW_MODEL_TEST): tests/HomeViewModelTests.mm \
		Cydia/HomeViewModel.h Cydia/HomeViewModel.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/HomeViewModelTests.mm Cydia/HomeViewModel.mm \
		-framework Foundation -o $@

verify-home-view-model: $(HOME_VIEW_MODEL_TEST)
	@$<

verify-home-controller: $(HOME_CONTROLLER_VERIFY_SCRIPT) $(HOME_LOCALIZATION_VERIFY_SCRIPT) \
	Cydia/HomeController.h Cydia/HomeController.mm \
	Cydia/HomeTableAppearance.h Cydia/HomeTableAppearance.mm \
	Cydia/HomeSplitDisclosure.h Cydia/HomeSplitDisclosure.mm \
	Cydia/HomeViewModel.h Cydia/HomeViewModel.mm \
		Cydia/Application+Navigation.mm
	@$(HOME_CONTROLLER_VERIFY_SCRIPT)

verify-faq-controller: $(FAQ_CONTROLLER_VERIFY_SCRIPT) \
	Cydia/FAQController.h Cydia/FAQController.mm Cydia/HomeController.mm \
	Cydia/Application+Navigation.mm Cydia/UIRouteContext.h Cydia/UIRouteContext.mm
	@$(FAQ_CONTROLLER_VERIFY_SCRIPT)

verify-home-controller-simulator:
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/home-simulator-ios12" \
		doIA=yes doHomeProbe=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeController.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeTableAppearance.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/UpgradingGuideController.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/MoreSourcesController.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/CopyingFilesGuideController.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeGuideController.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeControllerProbe.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeProbeURLProtocol.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/HomeViewModel.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/Cydia/AppearanceProbe.o" \
		"$(BUILD_DIR)/home-simulator-ios12/objects/tests/HomeControllerSimulatorCompile.o"

$(ERROR_VIEW_MODEL_TEST): tests/ErrorViewModelTests.mm \
		Cydia/ErrorViewModel.h Cydia/ErrorViewModel.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -fblocks \
		-Wall -Wextra -I. tests/ErrorViewModelTests.mm \
		Cydia/ErrorViewModel.mm -framework Foundation -o $@

verify-error-view-model: $(ERROR_VIEW_MODEL_TEST)
	@$<

verify-error-view-controller: $(ERROR_VIEW_CONTROLLER_VERIFY_SCRIPT) \
		Cydia/ErrorViewController.h Cydia/ErrorViewController.mm \
		Cydia/ErrorViewModel.h Cydia/ErrorViewModel.mm \
		tests/simulator/ErrorViewRuntimeProbe.h \
		tests/simulator/ErrorViewRuntimeProbe.mm
	@$(ERROR_VIEW_CONTROLLER_VERIFY_SCRIPT)
	@$(MAKE) --no-print-directory \
		BUILD_DIR="$(BUILD_DIR)/error-view-simulator-ios12" \
		doIA=yes kind=iphonesimulator arch=x86_64 \
		"$(BUILD_DIR)/error-view-simulator-ios12/objects/Cydia/ErrorViewModel.o" \
		"$(BUILD_DIR)/error-view-simulator-ios12/objects/Cydia/ErrorViewController.o" \
		"$(BUILD_DIR)/error-view-simulator-ios12/objects/tests/simulator/ErrorViewRuntimeProbe.o"
else
verify-ui-route-context:
	@echo "[verify] UI route runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-repository-package-presentation:
	@echo "[verify] Account presentation runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-external-url-policy:
	@echo "[verify] External URL policy runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-external-url-controller:
	@$(EXTERNAL_URL_CONTROLLER_VERIFY_SCRIPT)

verify-legacy-bridge-policy:
	@echo "[verify] Legacy bridge policy runtime test requires a Darwin host; portable inventory coverage remains enabled"

verify-legacy-ui-compatibility:
	@echo "[verify] Legacy UI compatibility runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-legacy-ui-compatibility-format: $(LEGACY_UI_COMPATIBILITY_FORMAT_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_FORMAT_CONTRACT_SCRIPT)

verify-legacy-ui-compatibility-native:
	@echo "[verify] Native legacy UI compatibility runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-ui-route-dispatch:
	@echo "[verify] UI route dispatch runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-ui-restoration-state:
	@echo "[verify] UI restoration state runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-package-detail-view-model:
	@echo "[verify] Package detail view-model runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-package-depiction-policy:
	@echo "[verify] Package depiction policy runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-package-legacy-metadata-policy:
	@echo "[verify] Package legacy metadata policy runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-url-protocol-policy: $(URL_PROTOCOL_POLICY_CONTRACT_SCRIPT) \
		Cydia/URLProtocol.mm Cydia/URLResourceResolver.h \
		Cydia/URLResourceResolver.mm CyteKit/URLProtocol.mm
	@echo "[verify] URL protocol policy host test requires a Darwin host; source compile coverage remains enabled"
	@$(URL_PROTOCOL_POLICY_CONTRACT_SCRIPT)

verify-package-depiction-view:
	@$(PACKAGE_DEPICTION_VIEW_VERIFY_SCRIPT)

verify-package-detail-controller:
	@$(PACKAGE_DETAIL_CONTROLLER_VERIFY_SCRIPT)

verify-package-detail-contact:
	@$(PACKAGE_DETAIL_CONTACT_VERIFY_SCRIPT)

verify-package-detail-controller-simulator:
	@echo "[verify] Package detail simulator seam compile requires a Darwin host"

verify-confirmation-view-model:
	@echo "[verify] Confirmation view-model runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-transaction-review:
	@echo "[verify] Immutable transaction review runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-fetch-diagnostics:
	@echo "[verify] Diagnostic localization runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-confirmation-controller:
	@echo "[verify] Confirmation controller contract test requires a Darwin host; iOS compile coverage remains enabled"

verify-confirmation-controller-simulator:
	@echo "[verify] Confirmation simulator seam compile requires a Darwin host"

verify-home-view-model:
	@echo "[verify] Home view-model runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-home-controller: $(HOME_LOCALIZATION_VERIFY_SCRIPT)
	@$(HOME_CONTROLLER_VERIFY_SCRIPT)

verify-faq-controller: $(FAQ_CONTROLLER_VERIFY_SCRIPT)
	@$(FAQ_CONTROLLER_VERIFY_SCRIPT)

verify-home-controller-simulator:
	@echo "[verify] Home simulator seam compile requires a Darwin host"

verify-error-view-model:
	@echo "[verify] Error view-model runtime test requires a Darwin host; iOS compile coverage remains enabled"

verify-error-view-controller:
	@$(ERROR_VIEW_CONTROLLER_VERIFY_SCRIPT)
endif

ifneq ($(HOST_OS),Darwin)
verify-legacy-ui-compatibility-native-snapshot: $(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_CONTRACT_SCRIPT)
	@$(LEGACY_UI_COMPATIBILITY_NATIVE_SNAPSHOT_CONTRACT_SCRIPT)
endif

ifeq ($(HOST_OS),Darwin)
$(PROGRESS_VIEW_MODEL_TEST): tests/ProgressViewModelTests.mm \
		Cydia/ProgressViewModel.h Cydia/ProgressViewModel.mm \
		Cydia/ProgressData.h Cydia/ProgressData.mm Cydia/ProgressEvent.h \
		Cydia/PackageArchitecturePresentation.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra \
		-Wno-unused-parameter -I. \
		tests/ProgressViewModelTests.mm Cydia/ProgressViewModel.mm \
		Cydia/ProgressData.mm -framework Foundation -o $@

verify-progress-view-model: $(PROGRESS_VIEW_MODEL_TEST)
	@$<
else
verify-progress-view-model:
	@echo "[verify] Progress view-model runtime test requires a Darwin host; iOS compile coverage remains enabled"
endif

verify-progress-controller: $(PROGRESS_CONTROLLER_VERIFY_SCRIPT) \
		Cydia/ProgressController.h Cydia/ProgressController.mm \
		Cydia/ProgressEventCell.h Cydia/ProgressEventCell.mm \
		Cydia/ProgressViewModel.h Cydia/ProgressViewModel.mm
	@$(PROGRESS_CONTROLLER_VERIFY_SCRIPT)

verify-upgrading-guide: tests/UpgradingGuideControllerContractTests.sh tests/UpgradingGuideContentTests.py \
		MobileCydia.app/UpgradingGuide.json tests/fixtures/ui/upgrading-guide-baseline.json
	@sh tests/UpgradingGuideControllerContractTests.sh

.PHONY: verify-application-extensions verify-more-sources verify-copying-files verify-home-guides
verify-home-guides:
	@sh tests/HomeGuideControllerContractTests.sh
verify-copying-files: tests/CopyingFilesGuideControllerContractTests.sh tests/CopyingFilesGuideContentTests.py \
		MobileCydia.app/CopyingFilesGuide.json tests/fixtures/ui/copying-files-baseline.json
	@sh tests/CopyingFilesGuideControllerContractTests.sh
ifneq ($(HOST_OS),Linux)
$(BUILD_DIR)/tests/MoreSourcesModelTests: tests/MoreSourcesModelTests.mm Cydia/MoreSourcesModel.mm Cydia/MoreSourcesModel.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/MoreSourcesModelTests.mm Cydia/MoreSourcesModel.mm -framework Foundation -o $@
verify-more-sources: $(BUILD_DIR)/tests/MoreSourcesModelTests
	@$< tests/fixtures/ui/more-sources/frozen-inputs.json
$(BUILD_DIR)/tests/ApplicationExtensionsModelTests: tests/ApplicationExtensionsModelTests.mm \
		Cydia/ApplicationExtensionsModel.mm Cydia/ApplicationExtensionsModel.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra \
		-I. -I$(mac)/usr/include/libxml2 tests/ApplicationExtensionsModelTests.mm \
		Cydia/ApplicationExtensionsModel.mm -framework Foundation -lxml2 -o $@
verify-application-extensions: $(BUILD_DIR)/tests/ApplicationExtensionsModelTests
	@$<
else
verify-more-sources:
	@echo "[verify] More Sources Foundation model test requires a Darwin host"
verify-application-extensions:
	@echo "[verify] Application Extensions Foundation model test requires a Darwin host"
endif

verify-native-ui: verify-native-ui-contract verify-no-remote-app-ui verify-ui-route-context verify-external-url-policy verify-external-url-controller verify-ui-route-dispatch \
	verify-window-appearance \
	verify-url-cache \
	verify-ui-restoration-state \
	verify-legacy-bridge-policy verify-legacy-ui-compatibility verify-legacy-ui-compatibility-format \
	verify-url-protocol-policy \
	verify-confirmation-view-model verify-confirmation-controller verify-confirmation-controller-appearance verify-transaction-review verify-fetch-diagnostics \
	verify-confirmation-controller-simulator verify-progress-view-model \
	verify-progress-controller verify-package-detail-view-model verify-package-depiction-facade \
	verify-package-depiction-policy verify-package-legacy-metadata-policy verify-package-depiction-view \
	verify-package-detail-controller verify-package-detail-contact \
	verify-package-detail-controller-simulator \
	verify-home-view-model verify-home-controller verify-faq-controller verify-upgrading-guide verify-application-extensions verify-more-sources verify-copying-files verify-home-guides verify-home-controller-simulator \
	verify-error-view-model verify-error-view-controller

$(EXEC_COMPAT_PARSER_TEST): tests/ExecCompatParserTests.c \
		$(EXEC_COMPAT_SOURCE_DIR)/get_new_argv.c \
		$(EXEC_COMPAT_SOURCE_DIR)/libiosexec.h $(EXEC_COMPAT_SOURCE_DIR)/utils.h \
		$(EXEC_COMPAT_PRIVATE_HEADER) $(EXEC_COMPAT_PATHS_HEADER) \
		tests/exec-compat-stubs/sys/paths.h
	@mkdir -p $(dir $@)
	@$(host_cc) $(host_cc_flags) -std=gnu11 -Wall -Wextra \
		-Itests/exec-compat-stubs -I$(EXEC_COMPAT_GENERATED_DIR) \
		-I$(EXEC_COMPAT_SOURCE_DIR) \
		-DLIBIOSEXEC_INTERNAL=1 \
		-DLIBIOSEXEC_PREFIXED_ROOT=$(EXEC_COMPAT_PREFIXED_ROOT) \
		tests/ExecCompatParserTests.c $(EXEC_COMPAT_SOURCE_DIR)/get_new_argv.c -o $@

verify-exec-compat: verify-exec-compat-provenance verify-exec-compat-archive \
	verify-exec-compat-parser verify-exec-compat-binary

verify-exec-compat-provenance: $(EXEC_COMPAT_VERIFY_SCRIPT) \
		$(EXEC_COMPAT_PROVENANCE_STAMP) $(EXEC_COMPAT_CONFIG_STAMP)
	@$(EXEC_COMPAT_VERIFY_SCRIPT) provenance \
		"$(EXEC_COMPAT_SOURCE_DIR)" "$(EXEC_COMPAT_SOURCE_COMMIT)" \
		"$(EXEC_COMPAT_SOURCE_URL)" "$(EXEC_COMPAT_SOURCE_NAMES)" \
		"$(EXEC_COMPAT_LICENSE)" "$(EXEC_COMPAT_COPYRIGHT)" \
		"$(EXEC_COMPAT_PROVENANCE_STAMP)" "$(EXEC_COMPAT_CONFIG_STAMP)" \
		"$(PACKAGE_LAYOUT)" \
		"$(PACKAGE_PREFIX)" "$(EXEC_COMPAT_SHEBANG_REDIRECT)" \
		"$(EXEC_COMPAT_DEFAULT_PATH)" "$(EXEC_COMPAT_STD_PATH)"

verify-exec-compat-archive: $(EXEC_COMPAT_VERIFY_SCRIPT) $(EXEC_COMPAT_LIBRARY)
	@$(EXEC_COMPAT_VERIFY_SCRIPT) archive "$(CYAR)" "$(EXEC_COMPAT_LIBRARY)"

verify-exec-compat-parser: $(EXEC_COMPAT_PARSER_TEST) Library/firmware.sh
	@$(EXEC_COMPAT_PARSER_TEST) Library/firmware.sh "$(if $(filter 1,$(EXEC_COMPAT_PREFIXED_ROOT)),$(PACKAGE_PREFIX),)/bin/bash"

verify-exec-compat-binary: $(EXEC_COMPAT_VERIFY_SCRIPT) $(CYDO_BINARY) $(APP_BINARY)
	@test -n "$(CYNM)" || { echo "CYNM is required" >&2; exit 2; }
	@test -n "$(CYOTOOL)" || { echo "CYOTOOL is required" >&2; exit 2; }
	@$(EXEC_COMPAT_VERIFY_SCRIPT) binary "$(CYNM)" "$(CYOTOOL)" "$(CYDO_BINARY)"
	@$(EXEC_COMPAT_VERIFY_SCRIPT) binary "$(CYNM)" "$(CYOTOOL)" "$(APP_BINARY)" app

verify-apt: verify-apt-provenance verify-apt-sources verify-apt-config

verify-apt-config:
	@package_version=$$(printf '#include <config.h>\n' | \
		$(apt64) -dM -E -x c++ - 2>/dev/null | \
		awk '$$2 == "PACKAGE_VERSION" { print $$3; exit }'); \
	version=$$(printf '#include <config.h>\n' | \
		$(apt64) -dM -E -x c++ - 2>/dev/null | \
		awk '$$2 == "VERSION" { print $$3; exit }'); \
	if test "$$package_version" != '"$(APT_SOURCE_VERSION)"'; then \
		echo "[verify-apt][FAIL] PACKAGE_VERSION is $$package_version" >&2; exit 1; \
	fi; \
	if test "$$version" != '"$(APT_SOURCE_VERSION)"'; then \
		echo "[verify-apt][FAIL] VERSION is $$version" >&2; exit 1; \
	fi; \
	echo "[verify-apt][ ok ] compiler reports APT version $(APT_SOURCE_VERSION)"

verify-apt-api-inventory: $(APT_API_VERIFY_SCRIPT) $(apt_api_sources)
	@$(APT_API_VERIFY_SCRIPT) inventory "$(apt_api_sources)" $(apt_api_candidates)

verify-apt-api: verify-apt-api-inventory $(APT_API_VERIFY_SCRIPT) $(apt_api_sources)
	@$(APT_API_VERIFY_SCRIPT) "$(APT_AUDIT_SOURCE_DIR)" "$(gxx)" "$(sdk)" \
		"$(kind)" "$(arch)" "$(DEPLOYMENT_TARGET)" \
		"$(APT_AUDIT_CXX_STANDARD)" "$(GENERATED_DIR)" "$(ICU_INCLUDE_DIR)" \
		$(apt_api_sources)

verify-apt-compile: $(APT_LIBRARY) $(apt_http_object) $(apt_compat_object)
	@echo "[verify-apt] embedded APT archive, HTTP method, and compatibility API compile graph is up to date"

verify-apt-provenance: $(APT_VERIFY_SCRIPT) mk/apt.mk .gitmodules \
	$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET)
	@$(APT_VERIFY_SCRIPT) provenance \
		"$(APT_SOURCE_DIR)" "$(APT_SOURCE_COMMIT)" "$(APT_SOURCE_BASE_COMMIT)" "$(APT_SOURCE_URL)" \
		"$(APT_SOURCE_VERSION)" "$(APT_SOURCE_CXX_LEVEL)" \
		"$(APT_SOURCE_TRUST)" \
		"$(APT_ABI_MAJOR)" "$(APT_ABI_MINOR)" "$(APT_ABI_RELEASE)" \
		"$(APT_LICENSE_FILES)" \
		"$(APT_CONTRIB_INCLUDE_TARGET)" "$(APT_DEB_INCLUDE_TARGET)" \
		"$(XXHASH_SOURCE_DIR)" "$(XXHASH_SOURCE_COMMIT)" "$(XXHASH_SOURCE_URL)" \
		"$(XXHASH_SOURCE_VERSION)"

verify-apt-sources: $(APT_VERIFY_SCRIPT) mk/apt.mk
	@$(APT_VERIFY_SCRIPT) sources "$(APT_SOURCE_DIR)" \
		"$(apt_core_sources)" "$(apt_deb_sources)" \
		"$(apt_contrib_sources)" "$(apt_method_sources)" \
		"$(apt_excluded_contrib_sources)" "$(notdir $(apt_http_source))" \
		"$(apt_excluded_method_sources)"

verify-static: verify-native-ui-contract verify-no-remote-app-ui verify-window-appearance verify-url-cache $(VERIFY_SCRIPT)
	@status=0; \
	$(MAKE) --no-print-directory verify-config || status=1; \
	$(MAKE) --no-print-directory verify-ownership || status=1; \
	$(MAKE) --no-print-directory verify-size || status=1; \
	exit $$status

# This target is useful while the source split is in progress: it checks the
# effective Make configuration and command graph without requiring a complete
# application link or a finished line-size gate.
verify-config: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) config "$(DEPLOYMENT_TARGET)" "$(arch)" "$(objc_arc)" "$(MAKE)" \
		"$(OBJECT_DIR)" "$(POSTINST_BINARY)" "$(CFVERSION_BINARY)" \
		"makefile mk/apt.mk mk/toolchain.mk mk/exec-compat.mk mk/rules.mk mk/verify.mk"

verify-ownership: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) ownership $(verify_ownership_files)

verify-size: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) size "$(VERIFY_MAX_SOURCE_LINES)" $(verify_size_sources)

# Compile every supported Objective-C object and both direct helper binaries,
# but do not perform the application/package link.  This is the fast, Make-only
# migration proof used between source-splitting commits.
verify-compile: $(verify_objc_objects) $(POSTINST_BINARY) $(CFVERSION_BINARY)
	@echo "[verify] Objective-C/Objective-C++ compile graph is up to date"

# Binary inspection is intentionally explicit: it consumes an already-built
# app binary and never starts a build as a side effect of static verification.
verify-native-ui-binary: $(NATIVE_UI_BINARY_VERIFY_SCRIPT)
	@test -f "$(APP_BINARY)" || { \
		echo "[verify-native-ui-binary][FAIL] build $(APP_BINARY) first" >&2; exit 2; \
	}
	@$(NATIVE_UI_BINARY_VERIFY_SCRIPT) "$(APP_BINARY)"

# Provenance inspection is deliberately build-free.  The link recipe records
# this sidecar after strip/uikit; verification refuses an unrecorded or stale
# binary instead of relinking it as a side effect of `make verify`.
verify-build-provenance: $(BUILD_PROVENANCE_SCRIPT)
	@$(BUILD_PROVENANCE_SCRIPT) verify "$(CURDIR)" "$(APP_BINARY)" \
		"$(VERSION_HEADER)" "$(APP_BINARY_PROVENANCE)"

# Keep a descriptive alias beside the native-UI binary gate.
verify-native-ui-provenance: verify-build-provenance

verify-build-provenance-contract: $(BUILD_PROVENANCE_CONTRACT_TEST) \
		$(BUILD_PROVENANCE_SCRIPT)
	@$(BUILD_PROVENANCE_CONTRACT_TEST)

# Package archive inspection is opt-in and never builds or selects an archive
# implicitly.  Supply both variables explicitly, for example:
#   make verify-package-artifacts PACKAGE_VERIFY_LAYOUT=rootless \
#       PACKAGE_VERIFY_DIR=/tmp/cydia-packages
PACKAGE_VERIFY_LAYOUT ?=
PACKAGE_VERIFY_DIR ?=
verify-package-artifacts: $(PACKAGE_ARTIFACT_VERIFY_SCRIPT)
	@test -n "$(PACKAGE_VERIFY_LAYOUT)" || { \
		echo "[verify-package][FAIL] PACKAGE_VERIFY_LAYOUT is required" >&2; exit 2; \
	}
	@test -n "$(PACKAGE_VERIFY_DIR)" || { \
		echo "[verify-package][FAIL] PACKAGE_VERIFY_DIR is required" >&2; exit 2; \
	}
	@$(PACKAGE_ARTIFACT_VERIFY_SCRIPT) "$(PACKAGE_VERIFY_LAYOUT)" \
		"$(PACKAGE_VERIFY_DIR)"

# Runtime UI verification is intentionally opt-in because it installs a probe
# app and changes simulator appearance. The script restores appearance and
# removes its uniquely identified app when it exits.
verify-appearance-simulator: $(APPEARANCE_VERIFY_SCRIPT)
	@test -n "$(SIMULATOR_UDID)" || { \
		echo "SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(APPEARANCE_VERIFY_SCRIPT) "$(SIMULATOR_UDID)" \
		"$(IOS12_SIMULATOR_UDID)" "$(MAKE)" "$(BUILD_DIR)/appearance-simulator"

verify-progress-simulator: $(PROGRESS_SIMULATOR_VERIFY_SCRIPT)
	@test -n "$(SIMULATOR_UDID)" || { \
		echo "SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(PROGRESS_SIMULATOR_VERIFY_SCRIPT) "$(SIMULATOR_UDID)" \
		"$(MAKE)" "$(BUILD_DIR)/progress-simulator"

verify-confirmation-simulator: $(CONFIRMATION_SIMULATOR_VERIFY_SCRIPT)
	@test -n "$(SIMULATOR_UDID)" || { \
		echo "SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(CONFIRMATION_SIMULATOR_VERIFY_SCRIPT) "$(SIMULATOR_UDID)" \
		"$(MAKE)" "$(BUILD_DIR)/confirmation-simulator"

# This probe installs the native package shell on exactly one already-booted
# runtime, drives real HID taps/swipes, and retains screenshots plus an
# in-process accessibility tree. Invoke ios12 and ios15 separately so the two
# simulators are never resident together. Production package routes remain
# latched to CYPackageController.
verify-package-detail-simulator: $(PACKAGE_DETAIL_SIMULATOR_VERIFY_SCRIPT) \
		tests/simulator/package_depiction_server.py
	@case_name="$(PACKAGE_DETAIL_SIMULATOR_CASE)"; \
	case "$$case_name" in \
		ios12) simulator="$(IOS12_SIMULATOR_UDID)";; \
		ios15) simulator="$(IOS15_SIMULATOR_UDID)";; \
		*) echo "PACKAGE_DETAIL_SIMULATOR_CASE must be ios12 or ios15" >&2; exit 2;; \
	esac; \
	test -n "$$simulator" || { \
		echo "simulator UDID is required for $$case_name" >&2; exit 2; \
	}; \
	$(PACKAGE_DETAIL_SIMULATOR_VERIFY_SCRIPT) "$$case_name" "$$simulator" \
		"$(MAKE)" "$(BUILD_DIR)/package-detail-simulator/$$case_name"

# Prepare the exact shared Home probe with one job and zero booted simulators.
# Runtime cases cannot build and must reuse the source/toolchain-bound receipt.
# The finalizer never starts a simulator.
verify-home-simulator-prepare: $(HOME_SIMULATOR_VERIFY_SCRIPT)
	@$(HOME_SIMULATOR_VERIFY_SCRIPT) --prepare --make "$(MAKE)" \
		--build-dir "$(BUILD_DIR)/home-simulator" \
		--developer-dir "$(HOME_SIMULATOR_DEVELOPER_DIR)" \
		--jobs "$(HOME_SIMULATOR_JOBS)"

verify-home-simulator: $(HOME_SIMULATOR_VERIFY_SCRIPT)
	@test -n "$(HOME_SIMULATOR_CASE)" || { \
		echo "HOME_SIMULATOR_CASE is required" >&2; exit 2; \
	}
	@case "$(HOME_SIMULATOR_CASE)" in \
		ios12-phone) simulator="$(IOS12_SIMULATOR_UDID)";; \
		ios15-phone) simulator="$(IOS15_SIMULATOR_UDID)";; \
		ios12-ipad) simulator="$(IPAD_SIMULATOR_UDID)";; \
		*) echo "unknown HOME_SIMULATOR_CASE: $(HOME_SIMULATOR_CASE)" >&2; exit 2;; \
	esac; \
	if test -z "$$simulator"; then \
		echo "the selected Home simulator UDID is required" >&2; exit 2; \
	fi; \
	$(HOME_SIMULATOR_VERIFY_SCRIPT) --case "$(HOME_SIMULATOR_CASE)" \
		--simulator "$$simulator" \
		--build-dir "$(BUILD_DIR)/home-simulator" \
		--developer-dir "$(HOME_SIMULATOR_DEVELOPER_DIR)" \
		--jobs "$(HOME_SIMULATOR_JOBS)"

verify-home-simulator-matrix: $(HOME_SIMULATOR_VERIFY_SCRIPT)
	@$(HOME_SIMULATOR_VERIFY_SCRIPT) --finalize \
		--build-dir "$(BUILD_DIR)/home-simulator" \
		--developer-dir "$(HOME_SIMULATOR_DEVELOPER_DIR)"

verify-home-simulator-matrix-contract: $(HOME_SIMULATOR_MATRIX_TEST) \
		$(HOME_SIMULATOR_VERIFY_SCRIPT)
	@$(HOME_SIMULATOR_MATRIX_TEST)

# This installs the native cydia://url coordinator sequentially on the two
# supported simulator generations. It proves the canonical route, OS-owned
# Safari presentation, native fallback state, Dynamic Type, and scoped cleanup.
verify-external-url-simulator: $(EXTERNAL_URL_SIMULATOR_VERIFY_SCRIPT)
	@test -n "$(IOS12_SIMULATOR_UDID)" || { \
		echo "IOS12_SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@test -n "$(IOS15_SIMULATOR_UDID)" || { \
		echo "IOS15_SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(EXTERNAL_URL_SIMULATOR_VERIFY_SCRIPT) "$(IOS12_SIMULATOR_UDID)" \
		"$(IOS15_SIMULATOR_UDID)" "$(MAKE)" \
		"$(BUILD_DIR)/external-url-simulator"

# This installs the native top-level failure surface sequentially on the two
# supported simulator generations and proves sanitized details plus exact Retry.
verify-native-error-simulator: $(NATIVE_ERROR_SIMULATOR_VERIFY_SCRIPT)
	@test -n "$(IOS12_SIMULATOR_UDID)" || { \
		echo "IOS12_SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@test -n "$(IOS15_SIMULATOR_UDID)" || { \
		echo "IOS15_SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(NATIVE_ERROR_SIMULATOR_VERIFY_SCRIPT) "$(IOS12_SIMULATOR_UDID)" \
		"$(IOS15_SIMULATOR_UDID)" "$(MAKE)" \
		"$(BUILD_DIR)/native-error-simulator"

# Every host boundary consuming this policy rebuilds when it changes.
$(APT_RUNTIME_TEST) $(PRIVILEGED_RUNTIME_TEST) $(PRIVILEGED_CLIENT_TEST) $(APPLICATION_IDENTITY_TEST) \
$(SOURCE_DOCUMENT_TEST) $(SOURCE_COMMIT_TEST) $(RUNTIME_SNAPSHOT_TEST) $(KEYRING_IMPORT_TEST) $(RECOVERY_PRIVILEGED_TEST): Cydia/SharedStateFile.hpp Cydia/ReadOnlySourceAlias.hpp Cydia/SourceReaderGroups.hpp Cydia/DpkgAdminAccess.hpp

# Direct-link fixtures also depend on the immutable environment API and bounds.
$(APT_PROVIDER_BROKER_AUTHORIZATION_TEST) $(APT_RUNTIME_TEST) $(PRIVILEGED_CLIENT_TEST) \
$(TRANSACTION_OUTCOME_POLICY_TEST) $(SHARED_CONFIG_HANDOFF_TEST) $(DPKG_RUNNER_TEST): Cydia/NativeLaunchEnvironment.hpp
