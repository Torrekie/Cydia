/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceRepositoryOptionsController.h"
#import "Cydia/SourceFormControls.h"
#import "CyteKit/Localize.h"

@interface CydiaSourceRepositoryOptionsController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation CydiaSourceRepositoryOptionsController {
    NSArray<NSDictionary *> *options_;
    NSString *suite_;
    NSDictionary *selectedOption_;
    NSMutableSet<NSString *> *components_;
    UITableView *table_;
    void (^saved_)(NSString *, NSSet<NSString *> *);
}
- (instancetype)initWithOptions:(NSArray<NSDictionary *> *)options selectedSuite:(NSString *)suite
            selectedComponents:(NSSet<NSString *> *)components saved:(void (^)(NSString *, NSSet<NSString *> *))saved {
    if ((self = [super init]) != nil) {
        options_ = [options copy]; saved_ = [saved copy]; components_ = [NSMutableSet set];
        self.title = CydiaSourceText(@"SOURCE_ADD_PUBLISHED_OPTIONS");
        for (NSDictionary *option in options_) if ([option[@"suite"] isEqual:suite]) {
            suite_ = [suite copy]; selectedOption_ = option;
            for (NSString *component in option[@"components"])
                if ([components containsObject:component]) [components_ addObject:component];
            break;
        }
    }
    return self;
}
- (NSDictionary *)selectedOption {
    return selectedOption_;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self; table_.rowHeight = UITableViewAutomaticDimension;
    table_.estimatedRowHeight = 76; table_.accessibilityIdentifier = @"cydia.source-draft.discovered-options";
    self.view = table_; CydiaStyleSourceForm(table_, self.traitCollection);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE")
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [self updateSelection];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; CydiaStyleSourceForm(table_, self.traitCollection); [table_ reloadData];
}
- (void)updateSelection {
    NSDictionary *option([self selectedOption]);
    self.navigationItem.rightBarButtonItem.enabled = option != nil && ([option[@"flat"] boolValue] || components_.count != 0);
    [table_ reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return [self selectedOption] == nil ? 1 : 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? options_.count : [[self selectedOption][@"components"] count];
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return CydiaSourceText(section == 0 ? @"SOURCE_ADD_PUBLISHED_SUITES" : @"SOURCE_ADD_COMPONENTS");
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) return CydiaSourceText(@"SOURCE_ADD_OPTIONS_UNVERIFIED");
    NSDictionary *option([self selectedOption]);
    if ([option[@"flat"] boolValue]) return CydiaSourceText(@"SOURCE_ADD_COMPONENTS_HELP");
    return CydiaSourceText([option[@"components"] count] == 0 ? @"SOURCE_ADD_COMPONENTS_NOT_PUBLISHED" : @"SOURCE_ADD_COMPONENT_SELECTION");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"RepositoryOption"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RepositoryOption"];
    cell.detailTextLabel.text = nil;
    CydiaStyleSourceFormCell(cell, self.traitCollection); BOOL selected(NO);
    if (path.section == 0) {
        NSDictionary *option(options_[path.row]); NSString *suite(option[@"suite"]);
        cell.textLabel.text = suite;
        NSArray *architectures(option[@"architectures"]);
        cell.detailTextLabel.text = architectures.count ? [NSString stringWithFormat:CydiaSourceText(@"SOURCE_ADD_ADVERTISED_ARCHITECTURES"),
            [architectures componentsJoinedByString:@", "]] : CydiaSourceText(@"SOURCE_ADD_ARCHITECTURES_NOT_PUBLISHED");
        selected = [suite isEqual:suite_];
        cell.accessibilityIdentifier = [@"cydia.source-draft.suite." stringByAppendingString:suite];
    } else {
        NSString *component([self selectedOption][@"components"][path.row]);
        cell.textLabel.text = component; selected = [components_ containsObject:component];
        cell.accessibilityIdentifier = [@"cydia.source-draft.component." stringByAppendingString:component];
    }
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits = (cell.accessibilityTraits & ~UIAccessibilityTraitSelected) | UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    BOOL hadOption([self selectedOption] != nil);
    if (path.section == 0) {
        NSDictionary *option(options_[path.row]); NSString *suite(option[@"suite"]);
        if (![suite_ isEqual:suite]) {
            suite_ = [suite copy]; selectedOption_ = option; [components_ removeAllObjects];
            if ([option[@"components"] containsObject:@"main"]) [components_ addObject:@"main"];
        }
    } else {
        NSString *component([self selectedOption][@"components"][path.row]);
        if ([components_ containsObject:component]) [components_ removeObject:component]; else [components_ addObject:component];
    }
    NSDictionary *option([self selectedOption]);
    self.navigationItem.rightBarButtonItem.enabled = option != nil && ([option[@"flat"] boolValue] || components_.count != 0);
    [table beginUpdates];
    if (!hadOption && option != nil) [table insertSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    else if (hadOption && option == nil) [table deleteSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    else if (hadOption) [table reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    [table endUpdates];
    [table reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)save {
    NSDictionary *option([self selectedOption]);
    if (option == nil || (![option[@"flat"] boolValue] && components_.count == 0)) return;
    NSString *suite([suite_ copy]); NSSet<NSString *> *components([components_ copy]);
    void (^saved)(NSString *, NSSet<NSString *> *)([saved_ copy]);
    [self.navigationController popViewControllerAnimated:YES];
    // Values are applied after returning to the draft; callbacks never race a
    // later push against this controller's pending pop.
    id<UIViewControllerTransitionCoordinator> transition(self.transitionCoordinator);
    if (transition != nil) [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!context.isCancelled && saved != nil) saved(suite, components);
    }];
    else if (saved != nil) saved(suite, components);
}
@end
