/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// Include the production parser/mutator/renderer, not a reimplementation.
// APT path discovery is stubbed to a disposable host fixture. This is not
// device, privileged-copy, native-confirmation or persistence evidence.
#include "Sources.mm"

_H<NSMutableDictionary> Sources_;
static std::string FixtureParts;
static std::string FixtureManaged;
namespace CydiaAPT {
const std::string &SourcePartsDirectory() { return FixtureParts; }
const std::string &ManagedSourceListPath() { return FixtureManaged; }
std::string SourceArchitectureOption() { return "[arch=iphoneos-arm]"; }
}

static unsigned Checks;
static void Require(bool passed, const char *message) {
    ++Checks;
    if (!passed) {
        fprintf(stderr, "[managed-source-sections][FAIL] %s\n", message);
        exit(1);
    }
}

static void Write(NSString *body) {
    Require([body writeToFile:[NSString stringWithUTF8String:FixtureManaged.c_str()]
        atomically:YES encoding:NSUTF8StringEncoding error:nil], "write fixture");
    CydiaSetManagedSourceListPath(nil);
    CydiaSetManagedSourceListPath([NSString stringWithUTF8String:FixtureManaged.c_str()]);
    Sources_ = [NSMutableDictionary dictionary];
}

static std::string Render() {
    std::string input;
    ManagedSourceDocument document;
    Require(ReadManagedTarget(&input) && SplitManagedSourceDocument(input, &document), "read owned block");
    PrimeManagedSourceState(document);
    return document.before + BuildManagedBlock(document, document.before + document.after, NULL) + document.after;
}

int main() {
    @autoreleasepool {
        char pattern[] = "/tmp/cydia-owned-section.XXXXXX";
        char *directory(mkdtemp(pattern));
        Require(directory != NULL, "create disposable fixture");
        FixtureParts = directory;
        FixtureManaged = FixtureParts + "/managed.list";
        NSString *key(@"deb:https://fixture.invalid/:stable");
        NSString *body(@"# unowned prefix\ndeb https://foreign.invalid/ stable main\n"
            "# BEGIN CYDIA MANAGED SOURCES\n"
            "deb [arch=iphoneos-arm signed-by=/keys/fixture.gpg] https://fixture.invalid/ stable main contrib\n"
            "# END CYDIA MANAGED SOURCES\n# unowned suffix\n");
        Write(body);
        Require([Sources_ count] == 0, "regression starts with no cached source metadata");
        Require(CydiaUpdateSourceSection(key, @"extra", true), "add recovers owned record");
        NSDictionary *record([Sources_ objectForKey:key]);
        Require([record[@"Sections"] isEqual:@[@"main", @"contrib", @"extra"]], "preserve all existing components");
        Require([record[@"URI"] isEqual:@"https://fixture.invalid/"] && [record[@"Distribution"] isEqual:@"stable"], "recover canonical identity");
        Require(CydiaUpdateSourceSection(key, @"extra", true), "idempotent add is accepted");
        Require([[[Sources_ objectForKey:key] objectForKey:@"Sections"] count] == 3, "idempotent add never duplicates");
        NSString *expected([body stringByReplacingOccurrencesOfString:@"stable main contrib\n" withString:@"stable main contrib extra\n"]);
        Require(Render() == [expected UTF8String], "actual renderer preserves options and unowned bytes");

        // Recreate the file after a persisted add and lose metadata again.
        Write(expected);
        Require(CydiaUpdateSourceSection(key, @"extra", false), "remove recovers owned record after relaunch");
        Require(Render() == [body UTF8String], "remove restores original components and options");
        Require(CydiaUpdateSourceSection(key, @"extra", false), "idempotent remove is accepted");
        Require(Render() == [body UTF8String], "idempotent remove does not change rendered state");
        [Sources_ setObject:@{@"Sections": @[@"main", @"contrib"], @"Label": @"cached label"} forKey:key];
        Require(CydiaUpdateSourceSection(key, @"extra", true), "immutable cached dictionary and array are copied");
        Require([[[Sources_ objectForKey:key] objectForKey:@"Label"] isEqual:@"cached label"], "unrelated source metadata retained");

        const std::string before(Render());
        Require(!CydiaUpdateSourceSection(@"deb:https://foreign.invalid/:stable", @"extra", true), "foreign source is not adopted");
        Require(!CydiaUpdateSourceSection(key, @"bad\ncomponent", true), "newline component rejected");
        Require(!CydiaUpdateSourceSection(key, @"#comment", true), "comment injection rejected");
        Require(!CydiaUpdateSourceSection(key, @"", false), "empty component rejected");
        Require(Render() == before, "rejections do not change state");
        CydiaRemoveSource(key);
        Require(!CydiaUpdateSourceSection(key, @"extra", true), "pending deletion cannot be resurrected");

        Write(@"# BEGIN CYDIA MANAGED SOURCES\ndeb https://fixture.invalid/ ./\n# END CYDIA MANAGED SOURCES\n");
        Require(!CydiaUpdateSourceSection(@"deb:https://fixture.invalid/:./", @"extra", true), "flat suites cannot gain components");
        Write(@"# BEGIN CYDIA MANAGED SOURCES\ndeb https://fixture.invalid/ stable main\ndeb https://fixture.invalid/ stable contrib\n# END CYDIA MANAGED SOURCES\n");
        Require(!CydiaUpdateSourceSection(key, @"extra", true) && [Sources_ count] == 0, "ambiguous owned key is rejected without cache mutation");
        Write(@"# BEGIN CYDIA MANAGED SOURCES\ndeb https://fixture.invalid/ stable main\n");
        Require(!CydiaUpdateSourceSection(key, @"extra", true), "malformed marker rejected");

        NSString *sourceBody(@"# BEGIN CYDIA MANAGED SOURCES\ndeb-src [signed-by=/keys/source.gpg] https://fixture.invalid/ stable main\n# END CYDIA MANAGED SOURCES\n");
        Write(sourceBody);
        Require(CydiaUpdateSourceSection(@"deb-src:https://fixture.invalid/:stable", @"extra", true), "deb-src owned mutation");
        Require(Render() == [[sourceBody stringByReplacingOccurrencesOfString:@"stable main\n" withString:@"stable main extra\n"] UTF8String], "deb-src signing option retained");

        NSString *rootlessBody(@"# BEGIN CYDIA MANAGED SOURCES\ndeb [arch=iphoneos-arm64] https://fixture.invalid/ stable main\n# END CYDIA MANAGED SOURCES\n");
        Write(rootlessBody);
        Require(CydiaUpdateSourceSection(key, @"extra", true), "rootless owned source mutation");
        Require(Render() == [[rootlessBody stringByReplacingOccurrencesOfString:@"stable main\n" withString:@"stable main extra\n"] UTF8String], "explicit rootless architecture retained");

        Require(unlink(FixtureManaged.c_str()) == 0, "remove exact fixture file");
        Require(!CydiaUpdateSourceSection(key, @"extra", true), "missing file does not create ownership");
        Require(rmdir(FixtureParts.c_str()) == 0, "remove disposable directory");
        printf("[managed-source-sections][PASS] %u checks; real parser/mutator/renderer, host-only\n", Checks);
    }
    return 0;
}
