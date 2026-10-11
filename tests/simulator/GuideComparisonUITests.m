#import <XCTest/XCTest.h>

// Real XCTest touches and system accessibility observations, not delegate probes.
// Screenshots/AX attachments live in the xcresult. No VoiceOver-focus claim.
@interface GuideComparisonUITests : XCTestCase
@end
@implementation GuideComparisonUITests
- (void)setUp { self.continueAfterFailure = NO; }
- (XCUIApplication *)launchHomeGuideRoutes:(NSString *)member profile:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.HomeGuidesComparison"];
    app.launchEnvironment = @{@"HOME_GUIDE_PAGE":member, @"HOME_GUIDE_PROFILE":profile};
    [app launch];
    XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:10]);
    NSString *tableID = [NSString stringWithFormat:@"cydia.home.%@.rows",member];
    if (![@[@"featured", @"themes", @"account"] containsObject:member])
        XCTAssertTrue([app.tables[tableID] waitForExistenceWithTimeout:10]);
    return app;
}
- (XCUIElement *)homeGuideAction:(NSString *)identifier app:(XCUIApplication *)app {
    XCUIElement *row = [app descendantsMatchingType:XCUIElementTypeAny][identifier];
    for (NSUInteger step=0; step<90; ++step) {
        if (row.exists && row.isHittable && row.frame.origin.y>=64 && CGRectGetMaxY(row.frame)<=667) break;
        BOOL above = row.exists && row.frame.size.height>0 && row.frame.origin.y<64;
        XCUIElement *table = app.tables.firstMatch;
        XCUICoordinate *start = [table coordinateWithNormalizedOffset:CGVectorMake(.5, above ? .35 : .8)];
        XCUICoordinate *end = [table coordinateWithNormalizedOffset:CGVectorMake(.5, above ? .8 : .35)];
        [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:400 thenHoldForDuration:.3];
    }
    XCTAssertTrue(row.exists && row.isHittable);
    XCTAssertGreaterThanOrEqual(row.frame.size.height,44);
    XCTAssertGreaterThanOrEqual(row.frame.origin.y,64);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(row.frame),667);
    return row;
}
- (void)homeGuideBrowserDone:(XCUIApplication *)app table:(NSString *)tableID {
    XCTAssertTrue([app.buttons[@"Done"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"Done"] tap];
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] evaluatedWithObject:app.buttons[@"Done"] handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertTrue([app.tables[tableID] waitForExistenceWithTimeout:5]);
}
- (void)testHomeGuidesNativeRouteNeighbors {
    XCUIApplication *app = [self launchHomeGuideRoutes:@"openssh" profile:@"route-neighbors"];
    XCUIElement *row = [self homeGuideAction:@"cydia.home.guide.openssh-022" app:app];
    CGFloat y = row.frame.origin.y; [row tap];
    XCTAssertTrue([app.tables[@"cydia.home.root-password.rows"] waitForExistenceWithTimeout:5]);
    [self capture:@"after-home-route-openssh-password" app:app];
    [[self homeGuideAction:@"cydia.home.guide.root-password-004" app:app] tap];
    XCTAssertTrue([app.tables[@"cydia.home.openssh.rows"] waitForExistenceWithTimeout:5]);
    [self capture:@"after-home-route-password-openssh" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.tables[@"cydia.home.root-password.rows"] waitForExistenceWithTimeout:5]);
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.tables[@"cydia.home.openssh.rows"] waitForExistenceWithTimeout:5]);
    row = app.cells[@"cydia.home.guide.openssh-022"];
    XCTAssertTrue(row.isHittable); XCTAssertEqualWithAccuracy(row.frame.origin.y,y,1);
    [self capture:@"after-home-route-neighbors-return" app:app];
    [app terminate];
}
- (void)testHomeGuidesNativeRouteCopyingNeighbor {
    XCUIApplication *app = [self launchHomeGuideRoutes:@"copying-files" profile:@"route-copying-neighbor"];
    XCUIElement *row = [self homeGuideAction:@"cydia.home.copying-files.change-default-password" app:app];
    CGFloat y = row.frame.origin.y; [row tap];
    XCTAssertTrue([app.tables[@"cydia.home.root-password.rows"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(app.buttons[@"Done"].exists);
    [self capture:@"after-home-route-copying-password" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.tables[@"cydia.home.copying-files.rows"] waitForExistenceWithTimeout:5]);
    row = app.cells[@"cydia.home.copying-files.change-default-password"];
    XCTAssertTrue(row.isHittable); XCTAssertEqualWithAccuracy(row.frame.origin.y,y,1);
    [self capture:@"after-home-route-copying-return" app:app];
    [app terminate];
}
- (void)testHomeGuidesNativeRoutePackage {
    XCUIApplication *app = [self launchHomeGuideRoutes:@"openssh" profile:@"route-package"];
    XCUIElement *row = [self homeGuideAction:@"cydia.home.guide.openssh-004" app:app];
    CGFloat y = row.frame.origin.y; [row tap];
    XCTAssertTrue([app.staticTexts[@"home-guide.fixture.package"] waitForExistenceWithTimeout:5]);
    XCTAssertEqualObjects(app.staticTexts[@"home-guide.fixture.package"].label,@"Inert package destination: openssh");
    [self capture:@"after-home-route-package" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.tables[@"cydia.home.openssh.rows"] waitForExistenceWithTimeout:5]);
    row = app.cells[@"cydia.home.guide.openssh-004"];
    XCTAssertTrue(row.isHittable); XCTAssertEqualWithAccuracy(row.frame.origin.y,y,1);
    [self capture:@"after-home-route-package-return" app:app];
    [app terminate];
}
- (void)testHomeGuidesNativeRouteBrowsers {
    for (NSArray *sample in @[@[@"developer-resources",@"developer-resources-002",@"http://iphonedevwiki.net/index.php/Main_Page"],
                             @[@"privacy",@"privacy-051",@"http://en.wikipedia.org/wiki/Entropy_(information_theory)"]]) {
        XCUIApplication *app = [self launchHomeGuideRoutes:sample[0] profile:@"route-browsers"];
        NSString *identifier = [@"cydia.home.guide." stringByAppendingString:sample[1]];
        XCUIElement *row = [self homeGuideAction:identifier app:app];
        CGFloat y = row.frame.origin.y; [row tap];
        XCTAssertTrue([app.staticTexts[@"Frozen native guide destination"] waitForExistenceWithTimeout:15]);
        XCTAssertTrue(app.staticTexts[sample[2]].exists);
        [self capture:[@"after-home-route-browser-" stringByAppendingString:sample[0]] app:app];
        [self homeGuideBrowserDone:app table:[NSString stringWithFormat:@"cydia.home.%@.rows",sample[0]]];
        row = app.cells[identifier];
        XCTAssertTrue(row.isHittable); XCTAssertEqualWithAccuracy(row.frame.origin.y,y,1);
        [self capture:[@"after-home-route-browser-return-" stringByAppendingString:sample[0]] app:app];
        [app terminate];
    }
}
- (void)testHomeGuidesNativeRouteCredits {
    XCUIApplication *app = [self launchHomeGuideRoutes:@"credits" profile:@"route-credits"];
    [[self homeGuideAction:@"cydia.home.guide.credits-001" app:app] tap];
    XCTAssertTrue([app.staticTexts[@"Frozen native guide destination"] waitForExistenceWithTimeout:15]);
    NSPredicate *donation = [NSPredicate predicateWithFormat:@"label BEGINSWITH %@",@"https://www.paypal.com/cgi-bin/webscr?cmd=_donations"];
    XCTAssertTrue([app.staticTexts matchingPredicate:donation].firstMatch.exists);
    [self capture:@"after-home-route-donation" app:app];
    [self homeGuideBrowserDone:app table:@"cydia.home.credits.rows"];
    XCUIElement *row = [self homeGuideAction:@"cydia.home.guide.credits-054" app:app];
    CGFloat y = row.frame.origin.y; [row tap];
    XCTAssertTrue([app.staticTexts[@"external-url.destination"] waitForExistenceWithTimeout:5]);
    XCTAssertEqualObjects(app.staticTexts[@"external-url.destination"].label,@"mailto");
    XCTAssertTrue([app.buttons[@"external-url.retry"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(app.buttons[@"Done"].exists); // Real system branch, not Safari.
    [self capture:@"after-home-route-mail-adapter-failure" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.tables[@"cydia.home.credits.rows"] waitForExistenceWithTimeout:5]);
    row = app.cells[@"cydia.home.guide.credits-054"];
    XCTAssertTrue(row.isHittable); XCTAssertEqualWithAccuracy(row.frame.origin.y,y,1);
    [self capture:@"after-home-route-credits-return" app:app];
    [app terminate];
}
- (void)testHomePlaceholdersNative {
    for (NSString *member in @[@"featured", @"themes", @"account"]) {
        XCUIApplication *app = [self launchHomeGuideRoutes:member profile:@"placeholder"];
        NSString *prefix = [NSString stringWithFormat:@"cydia.home.%@", member];
        XCUIElement *empty = app.staticTexts[[prefix stringByAppendingString:@".empty"]];
        XCTAssertTrue([empty waitForExistenceWithTimeout:5]);
        XCTAssertTrue(app.navigationBars.firstMatch.exists);
        XCTAssertFalse(app.buttons[@"Done"].exists);
        [self capture:[NSString stringWithFormat:@"after-home-placeholder-%@", member] app:app];
        [app.navigationBars.buttons.firstMatch tap];
        XCTAssertTrue([app.buttons[@"home-guide.fixture.open"] waitForExistenceWithTimeout:5]);
        [app terminate];
    }
}
- (void)testHomeStorageNative {
    XCUIApplication *app = [self launchHomeGuideRoutes:@"storage" profile:@"storage"];
    XCTAssertTrue([app.staticTexts[@"Storage Information"] waitForExistenceWithTimeout:5]);
    for (NSString *identifier in @[@"system-total", @"system-free", @"private-total",
                                   @"private-free", @"themes", @"itunes", @"apps", @"camera"]) {
        XCUIElement *row = app.cells[[@"cydia.home.storage." stringByAppendingString:identifier]];
        XCTAssertTrue([row waitForExistenceWithTimeout:5]);
        XCTAssertGreaterThanOrEqual(row.frame.size.height, 44);
        for (NSUInteger retry = 0; retry < 30 && ![row.label containsString:@","]; ++retry)
            [NSThread sleepForTimeInterval:.2];
        XCTAssertTrue([row.label containsString:@","]);
    }
    [self capture:@"after-home-storage-top" app:app];
    XCUIElement *camera = [self homeGuideAction:@"cydia.home.storage.camera" app:app];
    XCTAssertTrue(camera.isHittable);
    [self capture:@"after-home-storage-bottom" app:app];
    CGFloat y = camera.frame.origin.y;
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.buttons[@"home-guide.fixture.open"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"home-guide.fixture.open"] tap];
    XCTAssertTrue([app.tables[@"cydia.home.storage.rows"] waitForExistenceWithTimeout:5]);
    camera = [self homeGuideAction:@"cydia.home.storage.camera" app:app];
    XCTAssertEqualWithAccuracy(camera.frame.origin.y, y, 1);
    [app terminate];
}
- (void)exerciseHomeGuideNative:(NSString *)member profile:(NSString *)profile {
    NSDictionary *lastIDs = @{@"openssh":@"openssh-022", @"root-password":@"root-password-017",
        @"developer-resources":@"developer-resources-008", @"credits":@"credits-077", @"privacy":@"privacy-058"};
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.HomeGuidesComparison"];
    app.launchEnvironment = @{@"HOME_GUIDE_PAGE":member, @"HOME_GUIDE_PROFILE":profile};
    [app launch];
    XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:10]);
    XCUIElement *table = app.tables[[NSString stringWithFormat:@"cydia.home.%@.rows", member]];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, .5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, .5);
    NSString *prefix = [NSString stringWithFormat:@"after-home-%@-%@", member, profile];
    [self capture:[prefix stringByAppendingString:@"-top"] app:app];
    // Static guide rows intentionally expose StaticText, while actions expose
    // Cell/Button. Query the stable identifier without inventing a UI role.
    XCUIElement *last = [app descendantsMatchingType:XCUIElementTypeAny][[@"cydia.home.guide." stringByAppendingString:lastIDs[member]]];
    for (NSUInteger step=0; step<90; ++step) {
        if (last.exists && last.isHittable && last.frame.origin.y>=64 && CGRectGetMaxY(last.frame)<=667) break;
        XCUICoordinate *start = [table coordinateWithNormalizedOffset:CGVectorMake(.5,.8)];
        XCUICoordinate *end = [table coordinateWithNormalizedOffset:CGVectorMake(.5,.35)];
        [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:400 thenHoldForDuration:.3];
        if (step%3 == 0) [self capture:[prefix stringByAppendingFormat:@"-scroll-%02lu", (unsigned long)step] app:app];
    }
    XCTAssertTrue(last.exists && last.isHittable);
    XCTAssertGreaterThanOrEqual(last.frame.origin.y,64);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(last.frame),667);
    [self capture:[prefix stringByAppendingString:@"-bottom"] app:app];
    [[app.navigationBars.buttons elementBoundByIndex:0] tap];
    XCTAssertTrue([app.buttons[@"home-guide.fixture.open"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(table.exists);
    XCTAssertEqualObjects(app.staticTexts[@"home-guide.fixture.status"].label,@"Guides: 1 Routes: 0");
    [self capture:[prefix stringByAppendingString:@"-back"] app:app];
    [app.buttons[@"home-guide.fixture.open"] tap];
    XCTAssertTrue([table waitForExistenceWithTimeout:5]);
    [[app.navigationBars.buttons elementBoundByIndex:0] tap];
    XCTAssertTrue([app.buttons[@"home-guide.fixture.open"] waitForExistenceWithTimeout:5]);
    XCTAssertEqualObjects(app.staticTexts[@"home-guide.fixture.status"].label,@"Guides: 2 Routes: 0");
    [app terminate];
}
- (void)testHomeGuidesNativeOpenSSH { [self exerciseHomeGuideNative:@"openssh" profile:@"light"]; }
- (void)testHomeGuidesNativePassword { [self exerciseHomeGuideNative:@"root-password" profile:@"light"]; }
- (void)testHomeGuidesNativeDeveloping { [self exerciseHomeGuideNative:@"developer-resources" profile:@"light"]; }
- (void)testHomeGuidesNativeCredits { [self exerciseHomeGuideNative:@"credits" profile:@"light"]; }
- (void)testHomeGuidesNativePrivacy { [self exerciseHomeGuideNative:@"privacy" profile:@"light"]; }
- (void)testHomeGuidesNativePrivacyDark { [self exerciseHomeGuideNative:@"privacy" profile:@"dark"]; }
- (void)testHomeGuidesNativePrivacyLightAccessibility { [self exerciseHomeGuideNative:@"privacy" profile:@"light-ax"]; }
- (void)testHomeGuidesNativePrivacyDarkAccessibility { [self exerciseHomeGuideNative:@"privacy" profile:@"dark-ax"]; }
- (void)testHomeGuidesNativePasswordDarkAccessibility { [self exerciseHomeGuideNative:@"root-password" profile:@"dark-ax"]; }
- (void)exerciseHomeGuideBefore:(NSString *)member profile:(NSString *)profile {
    NSDictionary *paths = @{@"openssh":@"/openssh.html", @"password":@"/password.html",
        @"developing":@"/faq/developing.html", @"credits":@"/credits.html", @"privacy":@"/policy/privacy/"};
    NSDictionary *starts = @{@"openssh":@"Connecting to the iPhone", @"password":@"If you install OpenSSH",
        @"developing":@"Developing for jailbroken iOS", @"credits":@"Special Thanks to:",
        @"privacy":@"Updated Date: May 24th, 2018"};
    NSDictionary *ends = @{@"openssh":@"Change Default Password", @"password":@"Congratulations!",
        @"developing":@"If you're interested in learning", @"credits":@"ZodTTD",
        @"privacy":@"(Cydia does not provide any service"};
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.GuideComparison.before"];
    app.launchEnvironment = @{@"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18947",
        @"GUIDE_FIXTURE_PATH":paths[member], @"GUIDE_PROFILE":profile};
    [app launch];
    XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:10]);
    XCUIElement *first = [[app descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", starts[member]]].firstMatch;
    XCTAssertTrue([first waitForExistenceWithTimeout:20]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, .5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, .5);
    NSString *prefix = [NSString stringWithFormat:@"before-home-%@-%@", member, profile];
    [self capture:[prefix stringByAppendingString:@"-top"] app:app];
    XCUIElement *last = [[app descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", ends[member]]].firstMatch;
    for (NSUInteger step=0; step<40; ++step) {
        if (last.exists && last.frame.size.height > 0 && last.frame.origin.y >= 65 &&
            CGRectGetMaxY(last.frame) <= 615 && last.isHittable) break;
        // Overlapping held drags, not flings: retain the full terminal/policy/
        // attribution body in actual screenshots rather than only its endpoints.
        XCUICoordinate *start = [app coordinateWithNormalizedOffset:CGVectorMake(.5, .8)];
        XCUICoordinate *end = [app coordinateWithNormalizedOffset:CGVectorMake(.5, .35)];
        [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:400 thenHoldForDuration:.2];
        [self capture:[prefix stringByAppendingFormat:@"-scroll-%02lu", (unsigned long)step] app:app];
    }
    XCTAssertTrue(last.exists && last.isHittable);
    XCTAssertGreaterThanOrEqual(last.frame.origin.y, 65);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(last.frame), 615);
    [self capture:[prefix stringByAppendingString:@"-bottom"] app:app];
    [self finishCopyingFilesBefore:app capture:[prefix stringByAppendingString:@"-return"]];
}
- (void)testHomeGuidesBeforeOpenSSH { [self exerciseHomeGuideBefore:@"openssh" profile:@"light"]; }
- (void)testHomeGuidesBeforePassword { [self exerciseHomeGuideBefore:@"password" profile:@"light"]; }
- (void)testHomeGuidesBeforeDeveloping { [self exerciseHomeGuideBefore:@"developing" profile:@"light"]; }
- (void)testHomeGuidesBeforeCredits { [self exerciseHomeGuideBefore:@"credits" profile:@"light"]; }
- (void)testHomeGuidesBeforePrivacy { [self exerciseHomeGuideBefore:@"privacy" profile:@"light"]; }
- (void)testHomeGuidesBeforePrivacyDark { [self exerciseHomeGuideBefore:@"privacy" profile:@"dark"]; }
- (void)testHomeGuidesBeforePrivacyLightAccessibility { [self exerciseHomeGuideBefore:@"privacy" profile:@"light-ax"]; }
- (void)testHomeGuidesBeforePrivacyDarkAccessibility { [self exerciseHomeGuideBefore:@"privacy" profile:@"dark-ax"]; }
- (void)testHomeGuidesBeforePasswordDarkAccessibility { [self exerciseHomeGuideBefore:@"password" profile:@"dark-ax"]; }
- (void)testHomeGuidesBeforeDonation {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.GuideComparison.before"];
    app.launchEnvironment = @{@"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18947",
        @"GUIDE_FIXTURE_PATH":@"/credits.html", @"GUIDE_PROFILE":@"light"};
    [app launch];
    XCUIElement *donate = [app.links matchingPredicate:
        [NSPredicate predicateWithFormat:@"label BEGINSWITH %@", @"Contribute using"]].firstMatch;
    XCTAssertTrue([donate waitForExistenceWithTimeout:20]);
    [donate tap];
    XCTAssertTrue([app.staticTexts[@"Frozen donation submission"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(app.staticTexts[@"No payment or external request occurred."].exists);
    [self capture:@"before-home-credits-inert-donation" app:app];
    [self finishCopyingFilesBefore:app capture:@"before-home-credits-donation-return"];
}
- (XCUIApplication *)launchCopyingFilesNative:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.CopyingFilesComparison"];
    app.launchEnvironment = @{@"COPYING_PROFILE":profile}; [app launch];
    XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:10]);
    XCTAssertTrue([app.tables[@"cydia.home.copying-files.rows"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    return app;
}
- (XCUIElement *)copyingAction:(NSString *)identifier app:(XCUIApplication *)app {
    XCUIElement *row = app.cells[[@"cydia.home.copying-files." stringByAppendingString:identifier]];
    for (NSUInteger scroll=0; scroll<48; ++scroll) {
        BOOL exists = row.exists;
        CGRect frame = exists ? row.frame : CGRectZero;
        if (exists && frame.origin.y >= 64 && CGRectGetMaxY(frame) <= 667 && row.isHittable) break;
        // A fling can jump an entire section. Short held drags keep overlap,
        // and reverse if a known target is above the viewport after scrolling.
        BOOL above = exists && frame.size.height > 0 && frame.origin.y < 64;
        XCUIElement *table = app.tables[@"cydia.home.copying-files.rows"];
        XCUICoordinate *start = [table coordinateWithNormalizedOffset:CGVectorMake(.5, above ? .4 : .75)];
        XCUICoordinate *end = [table coordinateWithNormalizedOffset:CGVectorMake(.5, above ? .75 : .4)];
        [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:300 thenHoldForDuration:.2];
    }
    XCTAssertTrue(row.exists && row.isHittable);
    XCTAssertGreaterThanOrEqual(row.frame.size.height, 44);
    XCTAssertGreaterThanOrEqual(row.frame.origin.y, 64);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(row.frame), app.frame.size.height);
    return row;
}
- (void)returnFromCopyingFiles:(XCUIApplication *)app {
    [app.navigationBars.buttons[@"Cydia"] tap];
    XCUIElement *open = app.buttons[@"copying.fixture.open"];
    XCTAssertTrue([open waitForExistenceWithTimeout:5]);
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"hittable == YES"] evaluatedWithObject:open handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertFalse(app.tables[@"cydia.home.copying-files.rows"].exists);
}
- (void)exerciseCopyingFilesNative:(NSString *)profile {
    XCUIApplication *app = [self launchCopyingFilesNative:profile];
    [self capture:[@"after-copying-files-top-" stringByAppendingString:profile] app:app];
    [self copyingAction:@"openssh" app:app];
    [self capture:[@"after-copying-files-packages-" stringByAppendingString:profile] app:app];
    [self copyingAction:@"apple-file-conduit-2" app:app];
    [self capture:[@"after-copying-files-desktop-" stringByAppendingString:profile] app:app];
    [self copyingAction:@"phoneview" app:app];
    [self capture:[@"after-copying-files-bottom-" stringByAppendingString:profile] app:app];
    [self returnFromCopyingFiles:app];
    XCTAssertEqualObjects(app.staticTexts[@"copying.fixture.status"].label, @"Guides: 1 Routes: 0");
    [self capture:[@"after-copying-files-return-" stringByAppendingString:profile] app:app];
    [app.buttons[@"copying.fixture.open"] tap];
    XCTAssertTrue([app.staticTexts[@"cydia.home.copying-files.getting-files"] waitForExistenceWithTimeout:5]);
    XCTAssertTrue(app.staticTexts[@"cydia.home.copying-files.getting-files"].isHittable);
    [self returnFromCopyingFiles:app];
    XCTAssertEqualObjects(app.staticTexts[@"copying.fixture.status"].label, @"Guides: 2 Routes: 0");
    [app terminate];
}
- (void)testCopyingFilesNativeLight { [self exerciseCopyingFilesNative:@"light"]; }
- (void)testCopyingFilesNativeDark { [self exerciseCopyingFilesNative:@"dark"]; }
- (void)testCopyingFilesNativeLightAccessibility { [self exerciseCopyingFilesNative:@"light-ax"]; }
- (void)testCopyingFilesNativeDarkAccessibility { [self exerciseCopyingFilesNative:@"dark-ax"]; }
- (void)testCopyingFilesNativeRoutes {
    XCUIApplication *app = [self launchCopyingFilesNative:@"routes"];
    for (NSArray *sample in @[@[@"openssh", @"package", @"openssh"],
            @[@"change-default-password", @"neighbor", @"https://cydia.saurik.com/password.html"],
            @[@"cyberduck", @"external", @"http://cyberduck.ch/"]]) {
        XCUIElement *row = [self copyingAction:sample[0] app:app];
        CGFloat y = row.frame.origin.y; [row tap];
        if ([sample[1] isEqual:@"package"]) {
            XCUIElement *destination = app.staticTexts[@"copying.fixture.package"];
            XCTAssertTrue([destination waitForExistenceWithTimeout:5]);
            XCTAssertEqualObjects(destination.label, @"Inert package destination: openssh");
            [self capture:@"after-copying-files-edge-package" app:app];
            [app.navigationBars.buttons.firstMatch tap];
        } else {
            XCTAssertTrue([[app.staticTexts matchingIdentifier:@"Frozen guide destination"].firstMatch waitForExistenceWithTimeout:15]);
            XCTAssertTrue([app.staticTexts matchingIdentifier:sample[2]].firstMatch.exists);
            [self capture:[@"after-copying-files-edge-" stringByAppendingString:sample[1]] app:app];
            [app.buttons[@"Done"] tap];
            [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] evaluatedWithObject:app.buttons[@"Done"] handler:nil];
            [self waitForExpectationsWithTimeout:5 handler:nil];
        }
        XCTAssertTrue([app.tables[@"cydia.home.copying-files.rows"] waitForExistenceWithTimeout:5]);
        row = app.cells[[@"cydia.home.copying-files." stringByAppendingString:sample[0]]];
        [self expectationForPredicate:[NSPredicate predicateWithFormat:@"hittable == YES"] evaluatedWithObject:row handler:nil];
        [self waitForExpectationsWithTimeout:5 handler:nil];
        XCTAssertEqualWithAccuracy(row.frame.origin.y, y, 1.0);
        [self capture:[@"after-copying-files-edge-return-" stringByAppendingString:sample[1]] app:app];
    }
    [self returnFromCopyingFiles:app];
    XCTAssertEqualObjects(app.staticTexts[@"copying.fixture.status"].label, @"Guides: 1 Routes: 3");
    [app terminate];
}
- (XCUIApplication *)launchCopyingFilesBefore:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.GuideComparison.before"];
    app.launchEnvironment = @{@"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18946",
        @"GUIDE_FIXTURE_PATH":@"/copying.html", @"GUIDE_PROFILE":profile};
    [app launch];
    XCTAssertTrue([[app.links matchingIdentifier:@"OpenSSH"].firstMatch waitForExistenceWithTimeout:20]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    return app;
}
- (void)finishCopyingFilesBefore:(XCUIApplication *)app capture:(NSString *)name {
    [app swipeDown];
    XCTAssertTrue([app.buttons[@"Done"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"]
        evaluatedWithObject:app.buttons[@"Done"] handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [self capture:name app:app]; [app terminate];
}
- (void)exerciseCopyingFilesBefore:(NSString *)profile {
    XCUIApplication *app = [self launchCopyingFilesBefore:profile];
    [self capture:[@"before-copying-files-top-" stringByAppendingString:profile] app:app];
    XCUIElement *last = [app.links matchingIdentifier:@"http://www.ecamm.com/mac/phoneview/"].firstMatch;
    for (NSUInteger scroll=0; scroll<6 && (!last.exists || CGRectGetMaxY(last.frame)>app.frame.size.height-44); ++scroll)
        [app swipeUp];
    XCTAssertTrue(last.exists); XCTAssertGreaterThan(last.frame.size.height, 0);
    XCTAssertGreaterThanOrEqual(last.frame.origin.y, 0);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(last.frame), app.frame.size.height-44);
    [self capture:[@"before-copying-files-bottom-" stringByAppendingString:profile] app:app];
    [self finishCopyingFilesBefore:app capture:[@"before-copying-files-return-" stringByAppendingString:profile]];
    if (![profile isEqual:@"light"]) return;
    // Three semantic edge classes; only transport URLs change. Destination is
    // inert and displays the exact original URL, never package installation.
    NSArray *samples = @[@[@"OpenSSH", @"http://cydia.saurik.com/package/openssh", @"package"],
        @[@"change the default password", @"https://cydia.saurik.com/password.html", @"neighbor"],
        @[@"http://cyberduck.ch/", @"http://cyberduck.ch/", @"external"]];
    for (NSArray *sample in samples) {
        app = [self launchCopyingFilesBefore:profile];
        XCUIElement *link = [app.links matchingIdentifier:sample[0]].firstMatch;
        XCTAssertTrue(link.exists);
        [[link coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
        XCUIElement *destination = [app.staticTexts matchingIdentifier:@"Frozen guide destination"].firstMatch;
        XCTAssertTrue([destination waitForExistenceWithTimeout:10]);
        XCTAssertTrue([app.staticTexts matchingIdentifier:sample[1]].firstMatch.exists);
        [self capture:[@"before-copying-files-edge-" stringByAppendingString:sample[2]] app:app];
        [self finishCopyingFilesBefore:app capture:[@"before-copying-files-edge-return-" stringByAppendingString:sample[2]]];
    }
}
- (void)testCopyingFilesBeforeLight { [self exerciseCopyingFilesBefore:@"light"]; }
- (void)testCopyingFilesBeforeDark { [self exerciseCopyingFilesBefore:@"dark"]; }
- (void)testCopyingFilesBeforeLightAccessibility { [self exerciseCopyingFilesBefore:@"light-ax"]; }
- (void)testCopyingFilesBeforeDarkAccessibility { [self exerciseCopyingFilesBefore:@"dark-ax"]; }
- (void)exerciseSourceRestoration:(NSString *)scenario {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.MoreSourcesRestoration"];
    app.launchEnvironment = @{@"RESTORATION_SCENARIO":scenario}; [app launch];
    XCUIElement *row = app.cells[@"cydia.home.more-sources.modmyi"];
    XCTAssertTrue([row waitForExistenceWithTimeout:10]);
    BOOL accepted = [scenario isEqual:@"accept"] || [scenario isEqual:@"warning-add"];
    if ([scenario isEqual:@"readonly"]) {
        XCTAssertFalse(row.isEnabled);
        [[row coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
        XCTAssertEqual(app.alerts.count, 0);
    } else {
        [row tap];
        XCUIElement *prompt = app.alerts.firstMatch;
        XCTAssertTrue([prompt waitForExistenceWithTimeout:5]);
        XCTAssertTrue([prompt.label containsString:@"ADD_SOURCE"]);
        XCTAssertTrue([[prompt.staticTexts elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'stable main'"]] exists]);
        [self capture:[@"restore-prompt-" stringByAppendingString:scenario] app:app];
        [prompt.buttons[[scenario isEqual:@"cancel"] ? @"CANCEL" : @"ADD_SOURCE"] tap];
        if ([scenario hasPrefix:@"warning-"]) {
            XCUIElement *warning = app.alerts[@"SOURCE_WARNING"];
            XCTAssertTrue([warning waitForExistenceWithTimeout:15]);
            [self capture:[@"restore-warning-" stringByAppendingString:scenario] app:app];
            [warning.buttons[accepted ? @"ADD_ANYWAY" : @"CANCEL"] tap];
        } else if ([scenario isEqual:@"not-repository"] || [scenario isEqual:@"network-error"]) {
            XCUIElement *error = app.alerts[[scenario isEqual:@"not-repository"] ? @"NOT_REPOSITORY" : @"VERIFICATION_ERROR"];
            XCTAssertTrue([error waitForExistenceWithTimeout:15]);
            [self capture:[@"restore-error-" stringByAppendingString:scenario] app:app];
            [error.buttons[@"OK"] tap];
        } else if ([scenario isEqual:@"cancel-pending"]) {
            // Exercise pending network cancellation, not an interrupted
            // UIAlertView dismissal animation. Its old window can otherwise
            // trigger XCTest interruption handling immediately after activate.
            XCUIElement *confirm = app.alerts.buttons[@"ADD_SOURCE"];
            [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] evaluatedWithObject:confirm handler:nil];
            [self waitForExpectationsWithTimeout:5 handler:nil];
            [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
            // Xcode13 returned cached elements after activate while SpringBoard
            // stayed foreground. Resume through the actual owned app icon.
            XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
            XCUIElement *icon = springboard.icons[@"MoreSourcesRestoration"];
            XCTAssertTrue([icon waitForExistenceWithTimeout:5]);
            XCTAssertTrue(icon.isHittable); [icon tap];
            XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:10]);
            XCTAssertTrue([row waitForExistenceWithTimeout:5]);
            [self expectationForPredicate:[NSPredicate predicateWithFormat:@"enabled == YES"] evaluatedWithObject:row handler:nil];
            [self waitForExpectationsWithTimeout:5 handler:nil];
        }
    }
    if (!accepted) {
        XCTAssertTrue(row.exists); XCTAssertEqual(app.alerts.count, 0);
        if ([scenario isEqual:@"cancel-pending"]) {
            [self capture:@"restore-resumed-before-back" app:app];
        }
        [app.navigationBars.buttons[@"Fixture"] tap];
    }
    XCTAssertTrue([app.buttons[@"restoration.open"] waitForExistenceWithTimeout:10]);
    XCUIElement *status = app.staticTexts[@"restoration.status"];
    NSString *expected = accepted ? @"Adds:1 Syncs:1 Installs:1 Network:0" : @"Adds:0 Syncs:0 Installs:0 Network:0";
    NSPredicate *finished = [NSPredicate predicateWithFormat:@"label CONTAINS %@", expected];
    [self expectationForPredicate:finished evaluatedWithObject:status handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertTrue([status.label containsString:@"Unowned:unchanged"]);
    if ([scenario isEqual:@"cancel"] || [scenario isEqual:@"readonly"])
        XCTAssertTrue([status.label containsString:@"HTTP:0"]);
    if (accepted || [scenario isEqual:@"cancel"] || [scenario isEqual:@"warning-cancel"]) {
        [app.buttons[@"restoration.replay"] tap];
        XCTAssertTrue([status.label containsString:expected]);
    }
    [self capture:[@"restore-result-" stringByAppendingString:scenario] app:app];
    [app terminate];
}
- (void)testSourceRestorationCancel { [self exerciseSourceRestoration:@"cancel"]; }
- (void)testSourceRestorationAccept { [self exerciseSourceRestoration:@"accept"]; }
- (void)testSourceRestorationWarningCancel { [self exerciseSourceRestoration:@"warning-cancel"]; }
- (void)testSourceRestorationWarningAdd { [self exerciseSourceRestoration:@"warning-add"]; }
- (void)testSourceRestorationNotRepository { [self exerciseSourceRestoration:@"not-repository"]; }
- (void)testSourceRestorationNetworkError { [self exerciseSourceRestoration:@"network-error"]; }
- (void)testSourceRestorationBackgroundCancel { [self exerciseSourceRestoration:@"cancel-pending"]; }
- (void)testSourceRestorationReadOnly { [self exerciseSourceRestoration:@"readonly"]; }
- (XCUIApplication *)launchMoreSources:(NSString *)scenario {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.MoreSourcesComparison"];
    app.launchEnvironment = @{@"MORE_SOURCES_SCENARIO":scenario};
    [app launch];
    XCTAssertTrue([app.tables[@"cydia.home.more-sources.rows"] waitForExistenceWithTimeout:10]);
    return app;
}
- (void)returnFromMoreSources:(XCUIApplication *)app capture:(NSString *)name {
    XCUIElement *back = app.navigationBars.buttons[@"Cydia"];
    XCTAssertTrue(back.exists); [back tap];
    XCTAssertTrue([app.buttons[@"more-sources.fixture.open"] waitForExistenceWithTimeout:5]);
    NSPredicate *returned = [NSPredicate predicateWithFormat:@"exists == NO"];
    [self expectationForPredicate:returned evaluatedWithObject:app.tables[@"cydia.home.more-sources.rows"] handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [self capture:name app:app];
}
- (void)exerciseMoreSourcesNativeProfile:(NSString *)profile {
    XCUIApplication *app = [self launchMoreSources:@"missing"];
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    CGFloat previousBottom = 0;
    for (NSString *identifier in @[@"bigboss", @"modmyi", @"zodttd"]) {
        XCUIElement *row = app.cells[[@"cydia.home.more-sources." stringByAppendingString:identifier]];
        XCTAssertTrue(row.exists && row.isHittable && row.isEnabled);
        XCTAssertGreaterThanOrEqual(row.frame.size.height, 44);
        XCTAssertGreaterThanOrEqual(row.frame.origin.y, previousBottom);
        previousBottom = CGRectGetMaxY(row.frame);
    }
    XCTAssertEqualObjects(app.cells[@"cydia.home.more-sources.bigboss"].label, @"BigBoss");
    [self capture:[@"after-more-sources-top-" stringByAppendingString:profile] app:app];
    // Informational rows deliberately expose StaticText, not action cells.
    XCUIElement *footer = app.staticTexts[@"cydia.home.more-sources.text.2.0"];
    for (NSUInteger scroll = 0; scroll < 12 && (!footer.exists || !footer.isHittable ||
            CGRectGetMaxY(footer.frame) > app.frame.size.height); ++scroll)
        [app.tables[@"cydia.home.more-sources.rows"] swipeUp];
    XCTAssertTrue(footer.isHittable);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(footer.frame), app.frame.size.height);
    XCTAssertTrue([footer.label containsString:@"Some old repositories"]);
    [self capture:[@"after-more-sources-bottom-" stringByAppendingString:profile] app:app];
    [self returnFromMoreSources:app capture:[@"after-more-sources-return-" stringByAppendingString:profile]];
    [app.buttons[@"more-sources.fixture.open"] tap];
    XCTAssertTrue([app.cells[@"cydia.home.more-sources.bigboss"] waitForExistenceWithTimeout:5]);
    [app terminate];
}
- (void)testMoreSourcesNativeLight { [self exerciseMoreSourcesNativeProfile:@"light"]; }
- (void)testMoreSourcesNativeDark { [self exerciseMoreSourcesNativeProfile:@"dark"]; }
- (void)testMoreSourcesNativeLightAccessibility { [self exerciseMoreSourcesNativeProfile:@"light-ax"]; }
- (void)testMoreSourcesNativeDarkAccessibility { [self exerciseMoreSourcesNativeProfile:@"dark-ax"]; }
- (void)testMoreSourcesNativeSourceStates {
    XCUIApplication *app = [self launchMoreSources:@"partial"];
    XCTAssertTrue(app.cells[@"cydia.home.more-sources.bigboss"].exists);
    XCTAssertTrue(app.cells[@"cydia.home.more-sources.zodttd"].exists);
    XCTAssertFalse(app.cells[@"cydia.home.more-sources.modmyi"].exists);
    [self capture:@"after-more-sources-partial-alias" app:app]; [app terminate];
    app = [self launchMoreSources:@"all"];
    for (NSString *identifier in @[@"bigboss", @"modmyi", @"zodttd"])
        XCTAssertFalse(app.cells[[@"cydia.home.more-sources." stringByAppendingString:identifier]].exists);
    XCTAssertFalse(app.staticTexts[@"DEFAULT SOURCES"].exists);
    XCTAssertTrue(app.staticTexts[@"cydia.home.more-sources.text.1.0"].isHittable);
    [self capture:@"after-more-sources-all-configured" app:app]; [app terminate];
    app = [self launchMoreSources:@"readonly"];
    XCUIElement *row = app.cells[@"cydia.home.more-sources.bigboss"];
    XCTAssertTrue(row.exists); XCTAssertFalse(row.isEnabled);
    [[row coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
    [self capture:@"after-more-sources-readonly" app:app];
    [self returnFromMoreSources:app capture:@"after-more-sources-readonly-return"];
    XCTAssertTrue([app.staticTexts[@"more-sources.fixture.status"].label containsString:@"Fixture requests: 0"]);
    [app terminate];
    app = [self launchMoreSources:@"missing"];
    [app.cells[@"cydia.home.more-sources.modmyi"] tap];
    XCTAssertTrue(app.cells[@"cydia.home.more-sources.modmyi"].isEnabled);
    [self returnFromMoreSources:app capture:@"after-more-sources-request-boundary"];
    NSString *status = app.staticTexts[@"more-sources.fixture.status"].label;
    XCTAssertTrue([status containsString:@"Fixture requests: 1"] && [status containsString:@"Last: modmyi"]);
    XCTAssertTrue([status containsString:@"Source writes: 0"]); [app terminate];
}
- (void)exerciseMoreSourcesBefore:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.GuideComparison.before"];
    app.launchEnvironment = @{@"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18945",
        @"GUIDE_FIXTURE_PATH":@"/sources.html", @"GUIDE_PROFILE":profile};
    [app launch];
    XCUIElement *bigboss = [app.links matchingIdentifier:@"BigBoss"].firstMatch;
    XCTAssertTrue([bigboss waitForExistenceWithTimeout:20]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    [self capture:[@"before-more-sources-top-" stringByAppendingString:profile] app:app];
    if ([profile isEqual:@"light"]) {
        [[bigboss coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
        XCUIElement *cancel = app.buttons[@"Cancel"];
        XCTAssertTrue([cancel waitForExistenceWithTimeout:10]);
        [self capture:@"before-more-sources-confirm-cancel" app:app];
        [cancel tap];
        XCTAssertFalse(cancel.exists);
        XCTAssertTrue(bigboss.exists);
    }
    [app swipeUp];
    XCUIElement *footer = [app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:
        @"label BEGINSWITH 'If you remove a default repository'"]].firstMatch;
    XCTAssertTrue([footer waitForExistenceWithTimeout:10]);
    [self capture:[@"before-more-sources-bottom-" stringByAppendingString:profile] app:app];
    [app swipeDown]; // Reveal Safari's toolbar before Done.
    XCTAssertTrue([app.buttons[@"Done"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(app.buttons[@"Done"].exists);
    [self capture:[@"before-more-sources-return-" stringByAppendingString:profile] app:app];
    [app terminate];
}
- (void)testMoreSourcesBeforeLight { [self exerciseMoreSourcesBefore:@"light"]; }
- (void)testMoreSourcesBeforeDark { [self exerciseMoreSourcesBefore:@"dark"]; }
- (void)testMoreSourcesBeforeLightAccessibility { [self exerciseMoreSourcesBefore:@"light-ax"]; }
- (void)testMoreSourcesBeforeDarkAccessibility { [self exerciseMoreSourcesBefore:@"dark-ax"]; }
- (XCUIApplication *)launchExtensionsAfter:(NSString *)scenario {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.saurik.Cydia.ExtensionsComparison"];
    app.launchEnvironment = @{@"EXTENSIONS_SCENARIO":scenario};
    [app launch]; return app;
}
- (void)testExtensionsNativeNavigation {
    XCUIApplication *app = [self launchExtensionsAfter:@"populated"];
    XCUIElement *safari = app.cells[@"cydia.home.extensions.app.com.apple.mobilesafari"];
    XCTAssertTrue([safari waitForExistenceWithTimeout:10]);
    XCTAssertFalse(app.webViews.firstMatch.exists);
    XCTAssertEqual(app.cells.count, 2); // informational intro has StaticText traits
    XCTAssertGreaterThanOrEqual(safari.frame.size.height, 44);
    XCTAssertEqualObjects(safari.label, @"Safari");
    XCTAssertEqualObjects(safari.value, @"Extensions: 139");
    XCTAssertGreaterThanOrEqual(app.buttons[@"cydia.home.extensions.refresh"].frame.size.width, 44);
    XCTAssertGreaterThanOrEqual(app.buttons[@"cydia.home.extensions.refresh"].frame.size.height, 44);
    [self capture:@"extensions-after-root-light" app:app];
    [safari tap];
    XCUIElement *closeAll = app.cells[@"cydia.home.extensions.package.com.insanj.closeall"];
    XCTAssertTrue([closeAll waitForExistenceWithTimeout:10]);
    XCTAssertTrue([closeAll.label containsString:@"Close all tabs in Safari"]);
    XCTAssertEqualObjects(closeAll.value, @"FREE");
    XCTAssertGreaterThanOrEqual(closeAll.frame.size.height, 44);
    [self capture:@"extensions-after-packages-light" app:app];
    [closeAll tap];
    XCUIElement *destination = app.textViews[@"extensions.fixture.destination"];
    XCTAssertTrue([destination waitForExistenceWithTimeout:10]);
    XCTAssertTrue([destination.value containsString:@"cydia://package/com.insanj.closeall"]);
    XCTAssertTrue([destination.value containsString:@"cydia://home/application-extensions/com.apple.mobilesafari"]);
    [self capture:@"extensions-after-package-route" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([closeAll waitForExistenceWithTimeout:10]);
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([safari waitForExistenceWithTimeout:10]);
    [self capture:@"extensions-after-root-return" app:app];
    [app terminate];
}
- (void)testExtensionsNativeEmptyAndRetry {
    XCUIApplication *app = [self launchExtensionsAfter:@"empty"];
    XCUIElement *state = app.staticTexts[@"cydia.home.extensions.state"];
    XCTAssertTrue([state waitForExistenceWithTimeout:10]);
    NSPredicate *empty = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'No extensions'"];
    [self expectationForPredicate:empty evaluatedWithObject:state handler:nil];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    [self capture:@"extensions-after-empty" app:app];
    [app terminate];
    app = [self launchExtensionsAfter:@"retry"];
    XCUIElement *retry = app.cells[@"cydia.home.extensions.state"];
    XCTAssertTrue([retry waitForExistenceWithTimeout:10]);
    XCTAssertGreaterThanOrEqual(retry.frame.size.height, 44);
    [self capture:@"extensions-after-error" app:app];
    [retry tap];
    XCTAssertTrue([app.cells[@"cydia.home.extensions.app.com.apple.mobilesafari"] waitForExistenceWithTimeout:10]);
    [self capture:@"extensions-after-retry" app:app];
    [app terminate];
}
- (void)revealExtension:(XCUIElement *)element inApp:(XCUIApplication *)app {
    CGFloat top = CGRectGetMaxY(app.navigationBars.firstMatch.frame) + 8;
    CGFloat bottom = CGRectGetMaxY(app.frame) - 8;
    for (NSUInteger attempt = 0; attempt < 24; ++attempt) {
        CGRect frame = element.frame;
        if (CGRectGetMinY(frame) >= top && CGRectGetMaxY(frame) <= bottom && element.isHittable) return;
        CGFloat delta = CGRectGetMaxY(frame) > bottom ? MIN(180, CGRectGetMaxY(frame) - bottom + 12) :
            -MIN(180, top - CGRectGetMinY(frame) + 12);
        XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
        XCUICoordinate *start = [origin coordinateWithOffset:CGVectorMake(app.frame.size.width * 0.75, (top + bottom) / 2)];
        XCUICoordinate *end = [origin coordinateWithOffset:CGVectorMake(app.frame.size.width * 0.75, (top + bottom) / 2 - delta)];
        [start pressForDuration:0.1 thenDragToCoordinate:end];
    }
    XCTAssertTrue(element.isHittable);
    XCTAssertGreaterThanOrEqual(CGRectGetMinY(element.frame), top);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(element.frame), bottom);
}
- (void)exerciseExtensionsProfile:(NSString *)profile {
    [self exerciseExtensionsProfile:profile captureBefore:YES];
}
- (void)exerciseExtensionsProfile:(NSString *)profile captureBefore:(BOOL)captureBefore {
    BOOL large = [profile hasSuffix:@"ax"];
    // The ordinary Light original captures are already sealed in AE1. Other
    // original profiles have not been captured; reuse its exact before binary.
    if (captureBefore && ![profile isEqual:@"light"]) {
        XCUIApplication *before = [self launchExtensionsBefore:@"/ui/ios~iphone/1.1/application/" profile:profile];
        XCTAssertTrue([before.buttons[@"Close"] waitForExistenceWithTimeout:20]);
        [before.buttons[@"Close"] tap];
        XCTAssertTrue([[before.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:
            @"label BEGINSWITH 'Here are lists of extensions'"]].firstMatch waitForExistenceWithTimeout:15]);
        [self capture:[@"extensions-before-root-" stringByAppendingString:profile] app:before];
        [before terminate];
        before = [self launchExtensionsBefore:@"/application/com.apple.mobilesafari/" profile:profile];
        XCTAssertTrue([[before.links matchingPredicate:[NSPredicate predicateWithFormat:
            @"label CONTAINS 'CloseAll'"]].firstMatch waitForExistenceWithTimeout:20]);
        [self capture:[@"extensions-before-packages-" stringByAppendingString:profile] app:before];
        [before terminate];
    }
    XCUIApplication *app = [self launchExtensionsAfter:@"populated"];
    XCUIElement *safari = app.cells[@"cydia.home.extensions.app.com.apple.mobilesafari"];
    XCTAssertTrue([safari waitForExistenceWithTimeout:10]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    [self capture:[@"extensions-after-root-top-" stringByAppendingString:profile] app:app];
    [self revealExtension:safari inApp:app];
    XCTAssertGreaterThanOrEqual(safari.frame.size.height, 56);
    XCTAssertEqualObjects(safari.value, @"Extensions: 139");
    XCTAssertGreaterThanOrEqual(app.buttons[@"cydia.home.extensions.refresh"].frame.size.width, 44);
    XCTAssertGreaterThanOrEqual(app.buttons[@"cydia.home.extensions.refresh"].frame.size.height, 44);
    [self capture:[@"extensions-after-root-apps-" stringByAppendingString:profile] app:app];
    [safari tap];
    XCUIElement *closeAll = app.cells[@"cydia.home.extensions.package.com.insanj.closeall"];
    XCTAssertTrue([closeAll waitForExistenceWithTimeout:10]);
    XCTAssertGreaterThanOrEqual(closeAll.frame.size.height, large ? 150 : 56);
    XCTAssertEqualObjects(closeAll.value, @"FREE");
    XCTAssertTrue([app.images[@"cydia.home.extensions.icon.com.insanj.closeall.loaded"] waitForExistenceWithTimeout:10]);
    XCUIElement *title = app.staticTexts[@"NewTabKeyboard"];
    if (!large) {
        XCTAssertTrue(title.exists);
        XCTAssertLessThan(title.frame.size.height, 30); // regression: no one-letter wrap
    }
    [self capture:[@"extensions-after-packages-top-" stringByAppendingString:profile] app:app];
    XCUIElement *cloud = app.cells[@"cydia.home.extensions.package.org.h2co3.xwebkitspeech"];
    [self revealExtension:cloud inApp:app];
    XCTAssertTrue([app.images[@"cydia.home.extensions.icon.org.h2co3.xwebkitspeech.loaded"] waitForExistenceWithTimeout:10]);
    XCTAssertGreaterThanOrEqual(cloud.frame.size.height, 56);
    XCTAssertTrue([cloud.label containsString:@"support for x-webkit-speech text input"]);
    CGFloat originalY = cloud.frame.origin.y;
    [self capture:[@"extensions-after-packages-scroll-" stringByAppendingString:profile] app:app];
    [cloud tap];
    XCUIElement *destination = app.textViews[@"extensions.fixture.destination"];
    XCTAssertTrue([destination waitForExistenceWithTimeout:10]);
    XCTAssertTrue([destination.value containsString:@"cydia://package/org.h2co3.xwebkitspeech"]);
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([cloud waitForExistenceWithTimeout:10]);
    XCTAssertTrue(cloud.isHittable);
    XCTAssertEqualWithAccuracy(cloud.frame.origin.y, originalY, 2);
    [self capture:[@"extensions-after-packages-return-" stringByAppendingString:profile] app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([safari waitForExistenceWithTimeout:10]);
    XCTAssertTrue(safari.isHittable);
    [self capture:[@"extensions-after-root-return-" stringByAppendingString:profile] app:app];
    [app terminate];
}
- (void)testExtensionsProfileLight { [self exerciseExtensionsProfile:@"light"]; }
- (void)testExtensionsProfileDark { [self exerciseExtensionsProfile:@"dark"]; }
- (void)testExtensionsProfileLightAccessibility { [self exerciseExtensionsProfile:@"light-ax"]; }
- (void)testExtensionsProfileDarkAccessibility { [self exerciseExtensionsProfile:@"dark-ax"]; }
- (void)testExtensionsNativeProfileLight { [self exerciseExtensionsProfile:@"light" captureBefore:NO]; }
- (void)testExtensionsNativeProfileDark { [self exerciseExtensionsProfile:@"dark" captureBefore:NO]; }
- (void)testExtensionsNativeProfileLightAccessibility { [self exerciseExtensionsProfile:@"light-ax" captureBefore:NO]; }
- (void)testExtensionsNativeProfileDarkAccessibility { [self exerciseExtensionsProfile:@"dark-ax" captureBefore:NO]; }
- (XCUIApplication *)launchExtensionsBefore:(NSString *)path {
    return [self launchExtensionsBefore:path profile:@"light"];
}
- (XCUIApplication *)launchExtensionsBefore:(NSString *)path profile:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:
        @"com.saurik.Cydia.GuideComparison.before"];
    app.launchEnvironment = @{@"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18944",
        @"GUIDE_FIXTURE_PATH":path, @"GUIDE_PROFILE":profile};
    [app launch];
    return app;
}
- (void)testExtensionsBeforeRoot {
    XCUIApplication *app = [self launchExtensionsBefore:@"/ui/ios~iphone/1.1/application/"];
    // Real current Safari does not expose the retired Cydia JS bridge.
    // Capture that regression; do not inject a mock bridge to invent a pass.
    // Safari exposes this JavaScript dialog's Close button outside app.alerts.
    XCUIElement *close = app.buttons[@"Close"];
    XCTAssertTrue([close waitForExistenceWithTimeout:20]);
    [self capture:@"extensions-before-root-bridge-error" app:app];
    [close tap];
    XCUIElement *intro = [app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:
        @"label BEGINSWITH 'Here are lists of extensions'"]].firstMatch;
    XCTAssertTrue([intro waitForExistenceWithTimeout:15]);
    XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
    XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
    [self capture:@"extensions-before-root-light" app:app];
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(app.buttons[@"Done"].exists);
    [self capture:@"extensions-before-root-done" app:app];
    [app terminate];
}
- (void)testExtensionsBeforePackages {
    // Direct entry records the real package-list layout; it is NOT a claim
    // that the broken current root supplied a working installed-app link.
    XCUIApplication *app = [self launchExtensionsBefore:@"/application/com.apple.mobilesafari/"];
    XCUIElement *package = [app.links matchingPredicate:[NSPredicate predicateWithFormat:
        @"label CONTAINS 'CloseAll'"]].firstMatch;
    XCTAssertTrue([package waitForExistenceWithTimeout:20]);
    [self capture:@"extensions-before-packages-light" app:app];
    [[package coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
    XCTAssertTrue([app.staticTexts[@"Application extension destination"] waitForExistenceWithTimeout:15]);
    [self capture:@"extensions-before-package-route" app:app];
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(app.buttons[@"Done"].exists);
    [self capture:@"extensions-before-package-done" app:app];
    [app terminate];
}
- (void)exerciseGuideTrace:(NSString *)mode {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:
        @"com.saurik.Cydia.GuideComparison.after"];
    app.launchEnvironment = @{@"GUIDE_PAGE":@"root", @"GUIDE_TRACE_MODE":mode};
    [app launch];
    XCTAssertTrue([app.navigationBars[@"Upgrading"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(app.navigationBars[@"Select a guide"].exists);
    XCUIElement *tools = app.cells[@"cydia.home.upgrading.row.tools"];
    XCTAssertTrue([tools waitForExistenceWithTimeout:10]);
    [self capture:[@"after-trace-root-" stringByAppendingString:mode] app:app];
    [tools tap];
    XCTAssertTrue([app.navigationBars[@"Jailbreaking Tools"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(app.cells[@"cydia.home.upgrading.row.redsn0w"].exists);
    [self capture:[@"after-trace-tools-" stringByAppendingString:mode] app:app];
    [app.navigationBars[@"Jailbreaking Tools"].buttons.firstMatch tap];
    XCTAssertTrue([tools waitForExistenceWithTimeout:10]);
    [self capture:[@"after-trace-return-" stringByAppendingString:mode] app:app];
    [app terminate];
}
- (void)testGuideTraceOptOut { [self exerciseGuideTrace:@"off"]; }
- (void)testGuideTraceOptIn { [self exerciseGuideTrace:@"on"]; }
- (void)capture:(NSString *)name app:(XCUIApplication *)app {
    XCTAttachment *screen = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    screen.name = name;
    screen.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:screen];
    XCTAttachment *tree = [XCTAttachment attachmentWithString:app.debugDescription];
    tree.name = [name stringByAppendingString:@"-accessibility"];
    tree.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:tree];
}
- (XCUIApplication *)launch:(NSString *)mode page:(NSString *)page {
    return [self launch:mode page:page profile:@"light"];
}
- (XCUIApplication *)launch:(NSString *)mode page:(NSString *)page profile:(NSString *)profile {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:
        [@"com.saurik.Cydia.GuideComparison." stringByAppendingString:mode]];
    app.launchEnvironment = @{@"GUIDE_PAGE":page, @"GUIDE_PROFILE":profile,
        @"GUIDE_FIXTURE_URL":@"http://127.0.0.1:18943"};
    [app launch];
    return app;
}
- (void)checkRootProfile:(NSString *)profile {
    XCUIApplication *app = [self launch:@"after" page:@"root" profile:profile];
    XCUIElement *warning = app.staticTexts[@"cydia.home.upgrading.body.text"];
    XCTAssertTrue([warning waitForExistenceWithTimeout:10]);
    XCTAssertTrue([warning.label hasPrefix:@"An iTunes iOS upgrade"]);
    XCUIElement *bulletin = app.staticTexts[@"cydia.home.upgrading.body.continuation"];
    XCTAssertTrue([bulletin.label hasPrefix:@"Archived bulletin"]);
    XCTAssertTrue([bulletin.label hasSuffix:@"Cydia Home footer."]);
    XCTAssertEqual(app.cells.count, 7); // body nodes have StaticText AX traits
    BOOL large = [profile hasSuffix:@"ax"];
    if (large)
        XCTAssertGreaterThan(warning.frame.size.height, 200);
    else
        XCTAssertLessThan(warning.frame.size.height, 200);
    NSArray *identifiers = @[@"tools", @"news", @"shsh"];
    NSArray *titles = @[@"Jailbreaking Tools", @"News and Help", @"Upgrading / Downgrading"];
    CGFloat previousBottom = CGRectGetMaxY(warning.frame);
    // Initial geometry, before any scroll or selection. This fails the old
    // bulletin-first layout even though its links eventually become reachable.
    for (NSString *identifier in identifiers) {
        XCUIElement *row = app.cells[[@"cydia.home.upgrading.row." stringByAppendingString:identifier]];
        XCTAssertGreaterThanOrEqual(row.frame.origin.y, previousBottom);
        XCTAssertGreaterThanOrEqual(row.frame.size.height, 44);
        if (!large) {
            XCTAssertTrue(row.hittable);
            XCTAssertLessThanOrEqual(CGRectGetMaxY(row.frame), app.frame.size.height);
        }
        previousBottom = CGRectGetMaxY(row.frame);
    }
    XCTAssertGreaterThanOrEqual(bulletin.frame.origin.y, previousBottom);
    [self capture:[@"after-root-order-" stringByAppendingString:profile] app:app];
    for (NSUInteger index = 0; index < identifiers.count; ++index) {
        XCUIElement *row = app.cells[[@"cydia.home.upgrading.row." stringByAppendingString:identifiers[index]]];
        for (int step = 0; step < 8 && !row.hittable; ++step) [app swipeUp];
        XCTAssertTrue(row.hittable);
        [row tap];
        XCTAssertTrue([app.navigationBars[titles[index]] waitForExistenceWithTimeout:10]);
        if (index == 2)
            [self capture:[@"after-root-shsh-" stringByAppendingString:profile] app:app];
        [app.navigationBars.buttons.firstMatch tap];
        XCTAssertTrue([app.cells[@"cydia.home.upgrading.row.tools"] waitForExistenceWithTimeout:10]);
    }
    // Exercise a resource in the root's newly separated action section too.
    if ([profile isEqualToString:@"light"]) {
        XCUIElement *reddit = app.cells[@"cydia.home.upgrading.row.reddit"];
        for (int step = 0; step < 8 && !reddit.hittable; ++step) [app swipeUp];
        XCTAssertTrue(reddit.hittable);
        [reddit tap];
        XCTAssertTrue([app.staticTexts[@"Guide external destination"] waitForExistenceWithTimeout:15]);
        [self capture:@"after-root-resource" app:app];
        [app.buttons[@"Done"] tap];
        XCTAssertTrue([app.cells[@"cydia.home.upgrading.row.reddit"] waitForExistenceWithTimeout:10]);
        [self capture:@"after-root-resource-return" app:app];
    }
    [app terminate];
}
- (void)testRootOrderLight { [self checkRootProfile:@"light"]; }
- (void)testRootOrderDark { [self checkRootProfile:@"dark"]; }
- (void)testRootOrderLightAccessibility { [self checkRootProfile:@"light-ax"]; }
- (void)testRootOrderDarkAccessibility { [self checkRootProfile:@"dark-ax"]; }
- (void)waitForPage:(NSString *)page mode:(NSString *)mode app:(XCUIApplication *)app {
    XCUIElement *ready;
    if ([mode isEqualToString:@"after"]) {
        ready = app.staticTexts[@"cydia.home.upgrading.body.text"];
    } else if ([page isEqualToString:@"root"]) {
        ready = [app.links matchingIdentifier:
            @"Which free tools can I use to jailbreak eligible iOS versions?"].firstMatch;
    } else if ([page isEqualToString:@"tools"]) {
        ready = [app.links matchingPredicate:[NSPredicate predicateWithFormat:
            @"label BEGINSWITH[c] 'redsn0w'"]].firstMatch;
    } else if ([page isEqualToString:@"news"]) {
        ready = [app.links matchingPredicate:[NSPredicate predicateWithFormat:
            @"label CONTAINS[c] 'reddit'"]].firstMatch;
    } else {
        NSString *prefix = [page isEqualToString:@"shsh"] ? @"Probably not" : @"redsn0w is a tool";
        ready = [app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:
            @"label BEGINSWITH %@", prefix]].firstMatch;
    }
    XCTAssertTrue([ready waitForExistenceWithTimeout:25], @"%@ %@", mode, page);
}
- (void)captureSharedProfile:(NSString *)profile {
    // Five distinct shared layouts, not another 21-page campaign. Both modes
    // use the identical frozen fixture, viewport and app-local trait request.
    for (NSString *page in @[@"root", @"tools", @"news", @"redsn0w", @"shsh"]) {
        for (NSString *mode in @[@"before", @"after"]) {
            XCUIApplication *app = [self launch:mode page:page profile:profile];
            [self waitForPage:page mode:mode app:app];
            XCTAssertEqualWithAccuracy(app.frame.size.width, 375, 0.5);
            XCTAssertEqualWithAccuracy(app.frame.size.height, 667, 0.5);
            if ([mode isEqualToString:@"after"]) {
                for (XCUIElement *row in app.cells.allElementsBoundByIndex)
                    XCTAssertGreaterThanOrEqual(row.frame.size.height, 44);
                XCUIElement *body = app.staticTexts[@"cydia.home.upgrading.body.text"];
                XCTAssertGreaterThan(body.label.length, 40);
            }
            NSString *name = [NSString stringWithFormat:@"%@-%@-%@", mode, page, profile];
            [self capture:[name stringByAppendingString:@"-top"] app:app];
            if ([page isEqualToString:@"shsh"] || [page isEqualToString:@"redsn0w"]) {
                [app swipeUp];
                [self capture:[name stringByAppendingString:@"-scrolled"] app:app];
            }
            [app terminate];
        }
    }
}
- (void)testSharedPagesDark { [self captureSharedProfile:@"dark"]; }
- (void)testSharedPagesLightAccessibility { [self captureSharedProfile:@"light-ax"]; }
- (void)testSharedPagesDarkAccessibility { [self captureSharedProfile:@"dark-ax"]; }
- (void)testSHSHLightBeforeAfter {
    XCUIApplication *before = [self launch:@"before" page:@"root"];
    XCUIElement *shsh = [before.links matchingIdentifier:
        @"Can I upgrade/downgrade iOS to any version? What is SHSH?"].firstMatch;
    XCTAssertTrue([shsh waitForExistenceWithTimeout:25]);
    [self tapVisibleWebLink:shsh app:before];
    [self waitForPage:@"shsh" mode:@"before" app:before];
    [self capture:@"before-shsh-light-top" app:before];
    [before swipeUp];
    [self capture:@"before-shsh-light-scrolled" app:before];
    // Safari collapses its Done bar when scrolling down the document.
    // Reveal that real browser chrome before asserting/using its return.
    [before swipeDown];
    XCTAssertTrue([before.buttons[@"Done"] waitForExistenceWithTimeout:10]);
    [before.buttons[@"Done"] tap];
    XCTAssertTrue([before.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    [before terminate];

    XCUIApplication *after = [self launch:@"after" page:@"shsh"];
    [self waitForPage:@"shsh" mode:@"after" app:after];
    [self capture:@"after-shsh-light-top" app:after];
    XCUIElement *last = after.cells[@"cydia.home.upgrading.row.wikipedia"];
    for (int step = 0; step < 8 && !last.hittable; ++step) [after swipeUp];
    XCTAssertTrue(last.hittable);
    XCTAssertGreaterThanOrEqual(last.frame.size.height, 44);
    [self capture:@"after-shsh-light-scrolled" app:after];
    [last tap];
    XCTAssertTrue([after.staticTexts[@"Guide external destination"] waitForExistenceWithTimeout:15]);
    [self capture:@"after-shsh-resource" app:after];
    [after.buttons[@"Done"] tap];
    XCTAssertTrue([after.navigationBars[@"Upgrading / Downgrading"] waitForExistenceWithTimeout:10]);
    [self capture:@"after-shsh-resource-return" app:after];
    [after terminate];
}
- (void)tapVisibleWebLink:(XCUIElement *)link app:(XCUIApplication *)app {
    // iOS15/Xcode13 reports a legacy/modern Link type mismatch and false
    // isHittable even for visible links. Use its observed screen geometry for
    // a real coordinate touch, then require the destination to appear.
    // Only visible, unscrolled web links are covered here. Legacy long-list
    // touches are not reliable with this toolchain's remote-scroll snapshots.
    CGRect frame = link.frame;
    XCTAssertGreaterThan(frame.size.width, 0);
    XCTAssertGreaterThan(CGRectGetMidY(frame), 80);
    XCTAssertLessThan(CGRectGetMidY(frame), 590);
    [[[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
        coordinateWithOffset:CGVectorMake(CGRectGetMidX(frame), CGRectGetMidY(frame))] tap];
}
- (void)testBeforeRootToolsAndDone {
    XCUIApplication *app = [self launch:@"before" page:@"root"];
    XCUIElement *tools = [app.links matchingIdentifier:
        @"Which free tools can I use to jailbreak eligible iOS versions?"].firstMatch;
    XCTAssertTrue([tools waitForExistenceWithTimeout:25]);
    [self capture:@"before-root-top" app:app];
    [self tapVisibleWebLink:tools app:app];
    XCUIElement *redsn0w = [app.links matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH[c] 'redsn0w'"]].firstMatch;
    XCTAssertTrue([redsn0w waitForExistenceWithTimeout:10]);
    [self capture:@"before-tools-top" app:app];
    [app.buttons[@"Done"] tap];
    XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
    [self capture:@"before-done" app:app];
    [app terminate];
}
- (void)testBeforeLongToolRendering {
    XCUIApplication *app = [self launch:@"before" page:@"redsn0w"];
    XCTAssertTrue([[app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:
        @"label BEGINSWITH 'redsn0w is a tool'"]].firstMatch waitForExistenceWithTimeout:25]);
    [self capture:@"before-redsn0w-top" app:app];
    [app swipeUp];
    [self capture:@"before-redsn0w-scrolled" app:app];
    [app terminate];
}
- (void)testAfterRootLinks {
    XCUIApplication *app = [self launch:@"after" page:@"root"];
    XCUIElement *tools = app.cells[@"cydia.home.upgrading.row.tools"];
    XCTAssertTrue([tools waitForExistenceWithTimeout:10]);
    [self capture:@"after-root-top" app:app];
    for (int count = 0; count < 6 && !tools.hittable; ++count) [app swipeUp];
    XCTAssertTrue(tools.hittable);
    XCTAssertGreaterThanOrEqual(tools.frame.size.height, 44);
    [tools tap];
    XCUIElement *redsn0w = app.cells[@"cydia.home.upgrading.row.redsn0w"];
    XCTAssertTrue([redsn0w waitForExistenceWithTimeout:10]);
    [self capture:@"after-tools-top" app:app];
    for (int count = 0; count < 8 && !redsn0w.hittable; ++count) [app swipeUp];
    XCTAssertTrue(redsn0w.hittable);
    [redsn0w tap];
    XCTAssertTrue([app.navigationBars[@"redsn0w"] waitForExistenceWithTimeout:10]);
    [self capture:@"after-redsn0w-top" app:app];
    [app swipeUp];
    [self capture:@"after-redsn0w-scrolled" app:app];
    [app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([app.navigationBars[@"Jailbreaking Tools"] waitForExistenceWithTimeout:10]);
    [self capture:@"after-back-tools" app:app];
    [app terminate];
}
- (void)testNewsExternalBeforeAfter {
    for (NSString *mode in @[@"before", @"after"]) {
        XCUIApplication *app = [self launch:mode page:@"news"];
        XCUIElement *link;
        if ([mode isEqualToString:@"before"])
            link = [app.links matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] 'reddit'"]].firstMatch;
        else
            link = app.cells[@"cydia.home.upgrading.row.reddit"];
        XCTAssertTrue([link waitForExistenceWithTimeout:25]);
        [self capture:[mode stringByAppendingString:@"-news-top"] app:app];
        if ([mode isEqualToString:@"before"]) {
            [self tapVisibleWebLink:link app:app];
        } else {
            for (int count = 0; count < 6 && !link.hittable; ++count) [app swipeUp];
            XCTAssertTrue(link.hittable);
            [link tap];
        }
        XCTAssertTrue([app.staticTexts[@"Guide external destination"] waitForExistenceWithTimeout:15]);
        [self capture:[mode stringByAppendingString:@"-news-external"] app:app];
        [app.buttons[@"Done"] tap];
        if ([mode isEqualToString:@"after"])
            XCTAssertTrue([app.cells[@"cydia.home.upgrading.row.reddit"] waitForExistenceWithTimeout:10]);
        else
            XCTAssertTrue([app.navigationBars[@"Cydia"] waitForExistenceWithTimeout:10]);
        [self capture:[mode stringByAppendingString:@"-news-done"] app:app];
        [app terminate];
    }
}
@end
