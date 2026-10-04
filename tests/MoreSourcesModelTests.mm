/* Focused Foundation contract, not installed mutation evidence. GPL-3.0-or-later. */
#import "Cydia/MoreSourcesModel.h"
#include <cstdio>
#include <cstdlib>
static void Check(BOOL pass, const char *what) {
    if (!pass) { fprintf(stderr, "[more-sources] FAIL: %s\n", what); exit(1); }
}
int main(int argc, char **argv) { @autoreleasepool {
    Check(argc == 2, "frozen manifest argument required");
    NSDictionary *frozen = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
        [NSString stringWithUTF8String:argv[1]]] options:0 error:NULL];
    NSArray *catalog = CydiaDefaultSourceCatalog();
    Check(catalog.count == 3 && [frozen[@"rows"] count] == catalog.count, "exact three original rows");
    for (NSUInteger i = 0; i < catalog.count; ++i)
        for (NSString *key in @[@"identifier", @"name", @"rooturi", @"distribution", @"components"])
            Check([catalog[i][key] isEqual:frozen[@"rows"][i][key]], "all exact tuples, labels and order");
    Check(CydiaMissingDefaultSources(@[]).count == 3, "empty configured sources retains catalog");
    Check(CydiaMissingDefaultSources(catalog).count == 0, "all configured hides section");
    Check(CydiaMissingDefaultSources(@[catalog[0]]).count == 2, "partial state");
    NSArray *alias = CydiaMissingDefaultSources(@[@{@"rooturi":@"http://apt.modmyi.com/", @"distribution":@"stable"}]);
    Check(alias.count == 2 && [alias[1][@"identifier"] isEqual:@"zodttd"], "legacy ModMyi alias");
    Check(CydiaMissingDefaultSources(@[@{@"rooturi":catalog[0][@"rooturi"], @"distribution":@"./"}]).count == 3,
        "trivial source must not match distribution source");
    Check(CydiaMissingDefaultSources(@[@{}, (id)@"invalid"]).count == 3, "malformed records do not hide defaults");
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 1000; ++i) [many addObject:@{@"rooturi":@"https://unowned.example/", @"distribution":@"stable"}];
    [many addObjectsFromArray:catalog];
    Check(CydiaMissingDefaultSources(many).count == 0, "no production source-list fixture cap");
    Check(CydiaDefaultSourceForIdentifier(@"other") == nil && CydiaDefaultSourceForIdentifier(nil) == nil,
        "unknown identifiers cannot become mutation parameters");
    puts("[more-sources] PASS: frozen tuples/order, empty/partial/all, aliases/distribution, malformed inputs and uncapped source list");
} return 0; }
