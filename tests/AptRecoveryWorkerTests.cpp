/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryWorker.hpp"
#include "Cydia/AptProviderDpkgState.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <sys/wait.h>
#include <unistd.h>
namespace {
namespace P = CydiaAPT::Provider;
namespace R = CydiaAPT::Recovery;
void Require(bool value, const char *message) {
    if (value) return;
    std::fprintf(stderr, "[apt-recovery-worker] %s\n", message); std::exit(1);
}
P::ReviewedTransaction Review() {
    P::ReviewedTransaction review;
    review.binding.review = "review:1:1:1";
    P::ArchiveManifest archive; archive.identifier = "archive-one"; archive.path = "/private/cache/sample.deb";
    review.execution.archives.push_back(archive);
    P::ReviewedAction action; action.identifier = 1; action.action = P::ExecutionAction::Unpack;
    action.package.package = "sample"; action.package.version = "1"; action.package.architecture = "all";
    action.archive = archive.identifier; review.execution.actions.push_back(action);
    action.identifier = 2; action.action = P::ExecutionAction::Configure; action.archive.clear();
    review.execution.actions.push_back(action);
    action.identifier = 3; action.action = P::ExecutionAction::Remove;
    action.package.package = "foreign"; action.package.architecture = "iphoneos-arm64e";
    review.execution.actions.push_back(action); return review;
}
void Append(P::ReviewedTransaction &review, std::uint64_t id, P::ExecutionAction kind,
    const std::string &name, const std::string &architecture = "amd64") {
    P::ReviewedAction action; action.identifier = id; action.action = kind;
    action.package = {name, "1", architecture};
    if (kind == P::ExecutionAction::Unpack) {
        P::ArchiveManifest archive; archive.identifier = "archive-" + std::to_string(id);
        archive.path = "/private/cache/" + name + ".deb"; archive.package = action.package;
        action.archive = archive.identifier; review.execution.archives.push_back(archive);
    }
    review.execution.actions.push_back(action);
}
struct BatchFixture {
    CydiaAPT::RuntimeDescriptor runtime;
    P::ServerRequestContext context;
    std::vector<P::ParentExecutionRequest> batches;
    unsigned commits = 0, failBatch = 0;
    bool cancel = false, cancelAfterBatch = false;
    BatchFixture() {
        runtime.mutationEnvironmentValid = true;
        runtime.dpkgOptions = {"--root=/selected/root", "--admindir=/selected/admin"};
        context.operation = P::Operation::RunPackageManager;
        context.control.cancelled = [&]() { return cancel; };
        context.parentRequest = [&](P::Operation operation, const std::string &bytes, P::Message *reply) {
            reply->succeeded = true;
            if (operation == P::Operation::ExecuteDpkg) {
                P::ParentExecutionRequest request; Require(P::Decode(bytes, &request), "decode grouped batch");
                batches.push_back(request);
                P::ParentExecutionReply execution; execution.started = true;
                execution.exitCode = batches.size() == failBatch ? 1 : 0;
                Require(P::Encode(execution, &reply->payload), "encode grouped result");
                cancel = cancelAfterBatch;
            } else {
                Require(operation == P::Operation::CommitExtendedState, "unexpected grouped parent operation");
                ++commits;
            }
            return true;
        };
    }
    P::PackageManagerReply Run(const P::ReviewedTransaction &review, const std::set<std::string> &preDependsArchives = {}) {
        batches.clear(); commits = 0;
        return R::ExecuteReviewedActions(runtime, review, {}, context, preDependsArchives);
    }
};
bool Has(const std::vector<std::string> &arguments, const char *option) {
    return std::find(arguments.begin(), arguments.end(), option) != arguments.end();
}
void GroupedOperations() {
    BatchFixture fixture;
    P::ReviewedTransaction review; review.binding.review = "review:groups";
    // A and B can have mutually satisfied configuration dependencies; dpkg
    // needs the adjacent configure targets together, not one process each.
    Append(review, 11, P::ExecutionAction::Unpack, "cycle-a");
    Append(review, 18, P::ExecutionAction::Unpack, "cycle-b", "i386");
    Append(review, 21, P::ExecutionAction::Configure, "cycle-a");
    Append(review, 26, P::ExecutionAction::Configure, "cycle-b", "i386");
    Append(review, 40, P::ExecutionAction::Remove, "dependent");
    Append(review, 42, P::ExecutionAction::Remove, "dependency", "all");
    Append(review, 45, P::ExecutionAction::Purge, "residual");
    Append(review, 46, P::ExecutionAction::Purge, "residual-other", "all");
    Append(review, 50, P::ExecutionAction::Unpack, "after-predepends");
    Append(review, 51, P::ExecutionAction::Configure, "after-predepends");
    const auto result(fixture.Run(review));
    Require(result.result == CydiaAPT::PackageManagerResult::Completed && fixture.batches.size() == 6 && fixture.commits == 1,
        "adjacent same-kind actions must form complete ordered batches");
    const std::vector<std::vector<std::uint64_t>> expected = {{11,18}, {21,26}, {40,42}, {45,46}, {50}, {51}};
    const std::vector<std::vector<std::string>> operands = {
        {"/private/cache/cycle-a.deb", "/private/cache/cycle-b.deb"}, {"cycle-a:amd64", "cycle-b:i386"},
        {"dependent:amd64", "dependency:all"}, {"residual:amd64", "residual-other:all"},
        {"/private/cache/after-predepends.deb"}, {"after-predepends:amd64"}};
    for (std::size_t i = 0; i < fixture.batches.size(); ++i) {
        const auto &batch(fixture.batches[i]);
        Require(batch.batch == i + 1 && batch.actions == expected[i], "batching moved or renumbered recorded action IDs");
        const bool removal(batch.action == P::ExecutionAction::Remove || batch.action == P::ExecutionAction::Purge);
        Require(Has(batch.arguments, "--force-depends") == removal && Has(batch.arguments, "--abort-after=1") == removal &&
            Has(batch.arguments, "--no-triggers") && !Has(batch.arguments, "--pending"), "APT removal flags escaped their permitted action");
        const auto separator(std::find(batch.arguments.begin(), batch.arguments.end(), "--"));
        Require(separator != batch.arguments.end() && std::vector<std::string>(separator + 1, batch.arguments.end()) == operands[i],
            "batch operand order or exact architecture changed");
    }
    fixture.failBatch = 2;
    const auto failed(fixture.Run(review));
    Require(failed.started && failed.result == CydiaAPT::PackageManagerResult::Failed &&
        fixture.batches.size() == 2 && !fixture.commits, "group failure must stop without retrying members or committing state");
    fixture.failBatch = 0; fixture.cancelAfterBatch = true;
    const auto cancelled(fixture.Run(review));
    Require(cancelled.started && fixture.batches.size() == 1 && !fixture.commits, "cancellation must stop at the completed batch boundary");
}
void BoundedOperations() {
    for (unsigned variant = 0; variant != 2; ++variant) {
        BatchFixture fixture; P::ReviewedTransaction review; review.binding.review = "review:bounded";
        const unsigned count(variant == 0 ? 1100 : 600);
        for (unsigned i = 0; i < count; ++i)
            Append(review, i + 1, P::ExecutionAction::Configure,
                "package-" + std::to_string(i) + (variant == 1 ? std::string(80, 'x') : ""));
        const auto result(fixture.Run(review));
        Require(result.result == CydiaAPT::PackageManagerResult::Completed && fixture.batches.size() > 1 &&
            fixture.batches.size() < count, "large homogeneous operations must split into bounded useful batches");
        std::vector<std::uint64_t> identifiers;
        for (const auto &batch : fixture.batches) {
            std::size_t bytes = 256;
            for (const auto &argument : batch.arguments) bytes += argument.size() + 1 + sizeof(char *);
            Require(bytes <= 32 * 1024 && batch.actions.size() <= 1024, "dpkg batch exceeded count or byte limit");
            identifiers.insert(identifiers.end(), batch.actions.begin(), batch.actions.end());
        }
        Require(identifiers.size() == count, "bounded split lost an action");
        for (unsigned i = 0; i < count; ++i) Require(identifiers[i] == i + 1, "bounded split reordered an action");
    }
    for (unsigned variant = 0; variant != 3; ++variant) {
        BatchFixture fixture; P::ReviewedTransaction review; review.binding.review = "review:invalid-group";
        Append(review, 1, P::ExecutionAction::Remove, "before-invalid");
        if (variant == 0) {
            for (unsigned i = 0; i != 1100; ++i) Append(review, i + 2, P::ExecutionAction::Triggers, "recipient-" + std::to_string(i));
        } else if (variant == 1) {
            Append(review, 2, P::ExecutionAction::Triggers, "recipient-one");
            Append(review, 3, P::ExecutionAction::Configure, "middle");
            Append(review, 4, P::ExecutionAction::Triggers, "recipient-two");
        } else {
            Append(review, 2, P::ExecutionAction::Unpack, "too-long");
            review.execution.archives.back().path += std::string(32 * 1024, 'x');
        }
        const auto result(fixture.Run(review));
        Require(!result.started && fixture.batches.empty() && !fixture.commits,
            "unsplittable trigger/argument shape must reject before earlier valid effects");
    }
}
void PreDependsBatchBoundaries() {
    BatchFixture fixture; P::ReviewedTransaction review; review.binding.review = "review:predepends-boundaries";
    for (const auto id : {2u, 4u, 7u, 8u, 9u, 12u}) Append(review, id, P::ExecutionAction::Unpack, "package-" + std::to_string(id));
    Append(review, 15, P::ExecutionAction::Configure, "package-2");
    Append(review, 16, P::ExecutionAction::Configure, "package-4");
    const std::set<std::string> hints{"archive-2", "archive-7", "archive-8"};
    const auto result = fixture.Run(review, hints);
    const std::vector<std::vector<std::uint64_t>> expected{{2,4}, {7}, {8,9,12}, {15,16}};
    Require(result.result == CydiaAPT::PackageManagerResult::Completed && fixture.commits == 1 && fixture.batches.size() == expected.size(),
        "Pre-Depends starts an unpack child while following ordinary unpacks remain grouped");
    for (std::size_t i = 0; i < expected.size(); ++i) {
        const auto &batch = fixture.batches[i];
        Require(batch.actions == expected[i] && batch.batch == i + 1 && Has(batch.arguments, "--no-triggers") &&
            batch.arguments[0] == fixture.runtime.dpkgOptions[0] && batch.arguments[1] == fixture.runtime.dpkgOptions[1],
            "Pre-Depends splitting preserves action IDs, order, options and batch sequence");
        const auto separator = std::find(batch.arguments.begin(), batch.arguments.end(), "--");
        Require(separator != batch.arguments.end() && static_cast<std::size_t>(batch.arguments.end() - separator - 1) == expected[i].size(),
            "split batch has exactly one operand per original action");
        if (i < 3) for (std::size_t j = 0; j < expected[i].size(); ++j)
            Require(*(separator + 1 + j) == "/private/cache/package-" + std::to_string(expected[i][j]) + ".deb",
                "split retains exact reviewed archive operands");
    }
    const auto ordinary = fixture.Run(review);
    Require(ordinary.result == CydiaAPT::PackageManagerResult::Completed && fixture.batches.size() == 2 &&
        fixture.batches.front().actions == std::vector<std::uint64_t>({2,4,7,8,9,12}), "empty local hints preserve ordinary batching");
    fixture.failBatch = 2;
    const auto failed = fixture.Run(review, hints);
    Require(failed.started && failed.result == CydiaAPT::PackageManagerResult::Failed && fixture.batches.size() == 2 && !fixture.commits,
        "failed split child is never retried or followed by a state commit");
    fixture.failBatch = 0; fixture.cancelAfterBatch = true;
    const auto cancelled = fixture.Run(review, hints);
    Require(cancelled.started && fixture.batches.size() == 1 && !fixture.commits, "cancellation observes the new child boundary");
    for (unsigned variant = 0; variant < 4; ++variant) {
        BatchFixture invalid; auto bad = review; auto invalidHints = hints;
        if (variant == 0) invalidHints.insert("unknown-archive");
        if (variant == 1) bad.execution.archives.push_back(bad.execution.archives.front());
        if (variant == 2) {
            invalidHints.clear();
            for (std::size_t i = 0; i <= P::MaximumCollectionItems; ++i) invalidHints.insert("archive-" + std::to_string(i));
        }
        if (variant == 3) bad.execution.actions.back().action = P::ExecutionAction::Deconfigure;
        const auto denied = invalid.Run(bad, invalidHints);
        Require(!denied.started && invalid.batches.empty() && !invalid.commits,
            "unknown/oversized hints, duplicate reviewed archives or invalid later actions refuse before all parent calls");
    }
    BatchFixture bounded; P::ReviewedTransaction large; large.binding.review = "review:bounded-barriers";
    for (unsigned i = 0; i < 1100; ++i) Append(large, i + 1, P::ExecutionAction::Unpack, "package-" + std::to_string(i));
    const auto complete = bounded.Run(large, {"archive-1025"});
    Require(complete.result == CydiaAPT::PackageManagerResult::Completed, "size and Pre-Depends barriers compose");
    std::vector<std::uint64_t> actions;
    for (const auto &batch : bounded.batches) {
        std::size_t bytes = 256;
        for (const auto &argument : batch.arguments) bytes += argument.size() + 1 + sizeof(char *);
        Require(bytes <= 32 * 1024 && batch.actions.size() <= 1024, "barrier does not bypass argv/count limits");
        const auto found = std::find(batch.actions.begin(), batch.actions.end(), 1025);
        Require(found == batch.actions.end() || found == batch.actions.begin(), "bounded batch never places a hinted archive later");
        actions.insert(actions.end(), batch.actions.begin(), batch.actions.end());
    }
    Require(actions.size() == 1100, "bounded barriers lost actions");
    for (std::size_t i = 0; i < actions.size(); ++i) Require(actions[i] == i + 1, "bounded barriers reordered actions");
}
void CompletePendingTriggers() {
    BatchFixture fixture; P::ReviewedTransaction review; review.binding.review = "review:triggers";
    Append(review, 7, P::ExecutionAction::Triggers, "recipient-one");
    Append(review, 9, P::ExecutionAction::Triggers, "recipient-two", "all");
    P::DpkgState state; std::string error;
    const bool parsed(P::ParseDpkgState(
        "recipient-one\t1\tamd64\tinstall ok triggers-pending\t\tfirst-trigger\t\n"
        "recipient-two\t1\tall\tinstall ok triggers-pending\t\tsecond-trigger\t\n"
        "waiter\t1\tamd64\tinstall ok triggers-awaited\t\t\trecipient-one recipient-two\n",
        "amd64\n", "", "state-1", &state, &error));
    Require(parsed, error.c_str());
    const auto result(fixture.Run(review));
    Require(result.result == CydiaAPT::PackageManagerResult::Completed && fixture.batches.size() == 1 &&
        fixture.batches[0].actions == std::vector<std::uint64_t>({7, 9}), "pending trigger recipients must remain a complete single batch");
    P::ParentExecutionEvidence evidence;
    const bool accepted(P::ApplyDpkgStateEvidence(state, review, fixture.batches[0], &evidence, &error));
    Require(accepted, error.c_str());
    auto partial(fixture.batches[0]); partial.actions.pop_back(); partial.arguments.pop_back();
    Require(!P::ApplyDpkgStateEvidence(state, review, partial, &evidence, &error) && error == "provider_trigger_targets_incomplete",
        "the old single-recipient calls must fail the actual parent pending graph check");
}
}
int main() {
    GroupedOperations(); BoundedOperations(); CompletePendingTriggers(); PreDependsBatchBoundaries();
    CydiaAPT::RuntimeDescriptor runtime; runtime.mutationEnvironmentValid = true;
    runtime.dpkgOptions = {"--root=/selected/root", "--admindir=/selected/admin"};
    const auto review(Review());
    std::vector<P::ParentExecutionRequest> batches;
    unsigned commits = 0; bool cancel = false; unsigned failBatch = 0;
    P::ServerRequestContext context; context.operation = P::Operation::RunPackageManager;
    context.control.cancelled = [&]() { return cancel; };
    context.control.remainingMilliseconds = []() { return 1000u; };
    context.parentRequest = [&](P::Operation operation, const std::string &bytes, P::Message *reply) {
        reply->succeeded = true;
        if (operation == P::Operation::ExecuteDpkg) {
            P::ParentExecutionRequest request;
            Require(P::Decode(bytes, &request), "decode parent batch"); batches.push_back(request);
            P::ParentExecutionReply result; result.started = true; result.exitCode = batches.size() == failBatch ? 1 : 0;
            Require(P::Encode(result, &reply->payload), "encode parent terminal result");
        } else {
            Require(operation == P::Operation::CommitExtendedState, "only execution and state commit permitted");
            P::ExtendedStateRequest request;
            Require(P::Decode(bytes, &request) && P::SameBinding(request.binding, review.binding), "state commit bound to review");
            ++commits;
        }
        return true;
    };
    auto result(R::ExecuteReviewedActions(runtime, review, {}, context));
    Require(result.result == CydiaAPT::PackageManagerResult::Completed && result.started && batches.size() == 3 && commits == 1,
        "all reviewed effects settle before extended-state commit");
    Require(batches[0].batch == 1 && batches[1].batch == 2 && batches[2].batch == 3 &&
        batches[0].actions == std::vector<std::uint64_t>{1} && batches[1].actions == std::vector<std::uint64_t>{2}, "ordered exact action batches");
    Require(batches[0].arguments.front() == runtime.dpkgOptions[0] && batches[0].arguments[1] == runtime.dpkgOptions[1] &&
        batches[0].arguments.back() == "/private/cache/sample.deb", "protected options and exact archive path retained");
    Require(batches[1].arguments.back() == "sample:all" && batches[2].arguments.back() == "foreign:iphoneos-arm64e",
        "architecture-independent and foreign exact identities retained");
    batches.clear(); commits = 0; failBatch = 2;
    result = R::ExecuteReviewedActions(runtime, review, {}, context);
    Require(result.result == CydiaAPT::PackageManagerResult::Failed && result.started && batches.size() == 2 && commits == 0,
        "failed second batch preserves started and never retries or commits");
    batches.clear(); failBatch = 0; cancel = true;
    result = R::ExecuteReviewedActions(runtime, review, {}, context);
    Require(!result.started && batches.empty() && commits == 0, "cancelled review has no effects");
    cancel = false;
    auto unsupported(review); unsupported.execution.actions.back().action = P::ExecutionAction::Deconfigure;
    result = R::ExecuteReviewedActions(runtime, unsupported, {}, context);
    Require(!result.started && batches.empty(), "unsupported later effect rejected before first batch");
    unsupported = review; unsupported.execution.actions.front().archive = "unknown";
    result = R::ExecuteReviewedActions(runtime, unsupported, {}, context);
    Require(!result.started && batches.empty(), "unbound archive rejected before first batch");
    context.operation = P::Operation::RunFetcher;
    result = R::ExecuteReviewedActions(runtime, review, {}, context);
    Require(!result.started && batches.empty(), "fetch callback cannot request dpkg");
    const auto child(fork()); Require(child >= 0, "fork missing-capsule fixture");
    if (child == 0) {
        close(3);
        char executable[] = "cydia-recovery", command[] = "--cydia-provider-info";
        char *arguments[] = {executable, command, nullptr};
        _exit(R::RunWorker(2, arguments));
    }
    int status = 0; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
        WEXITSTATUS(status) == (geteuid() == 0 ? 64 : 78), "worker refuses elevated or missing-capsule startup");
    std::puts("Recovery worker review/execution boundary tests passed.");
}
