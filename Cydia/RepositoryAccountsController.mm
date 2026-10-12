/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/Database.h"
#import "Cydia/Source.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

@interface RepositoryAccountsController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *sources;
@property(nonatomic, copy) NSURL *sourceURL;
@property(nonatomic, copy) NSString *sourceName, *package;
@property(nonatomic, strong) CydiaRepositoryAccount *account;
@property(nonatomic, copy) NSString *status, *userName, *packageState;
@property(nonatomic) BOOL busy, loaded, signedIn;
@end
@implementation RepositoryAccountsController
- (instancetype)init { return [self initWithSourceURL:nil name:nil package:nil]; }
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package {
    if ((self = [super init])) {
        _sourceURL = [sourceURL copy]; _sourceName = [name copy]; _package = [package copy];
        self.title = name.length ? name : CydiaAccountLocalize(@"ACCOUNTS");
    }
    return self;
}
- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/account"]; }
- (void)loadView {
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.delegate = self; _table.dataSource = self;
    _table.rowHeight = UITableViewAutomaticDimension; _table.estimatedRowHeight = 64;
    _table.accessibilityIdentifier = @"cydia.repository.accounts";
    self.view = _table; [self applyAppearance];
}
- (void)applyAppearance {
    _table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    _table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    [_table reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; [self applyAppearance];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_sourceURL) {
        NSMutableArray *sources = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
        for (Source *source in [[Database sharedInstance] sources]) {
            NSString *URL = [source rooturi];
            if (!URL.length || [seen containsObject:URL]) continue;
            [seen addObject:URL];
            [sources addObject:@{@"url": URL, @"name": [source name] ?: URL}];
        }
        _sources = [sources copy]; [_table reloadData];
    } else if (!_loaded && !_busy) {
        _busy = YES; _status = UCLocalize("LOADING"); [_table reloadData];
        __weak RepositoryAccountsController *weakSelf = self;
        [[CydiaRepositoryAccountService sharedService] discoverSource:_sourceURL name:_sourceName ?: _sourceURL.host
            completion:^(CydiaRepositoryAccount *account, NSError *error) {
            RepositoryAccountsController *self = weakSelf; if (!self) return;
            self.busy = NO; self.loaded = YES; self.account = account;
            self.status = error.localizedDescription ?: (account && !account.supportsAccountIntegration ? CydiaAccountLocalize(@"ACCOUNT_UNSUPPORTED") : nil); self.signedIn = account.signedIn;
            [self.table reloadData]; if (self.signedIn) [self refreshAccount];
        }];
    }
}
- (void)refreshAccount {
    if (_busy || !_account) return;
    _busy = YES; [_table reloadData];
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] userInfo:_account completion:^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self) return;
        self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
        id user = info[@"user"];
        self.userName = [user isKindOfClass:NSDictionary.class] && [user[@"name"] isKindOfClass:NSString.class] ? user[@"name"] : nil;
        if (self.userName.length > 256) self.userName = [self.userName substringToIndex:256];
        [self.table reloadData];
        if (self.package.length && !error) [self refreshPackage];
    }];
}
- (void)refreshPackage {
    _busy = YES;
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] packageInfo:_package account:_account completion:^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self) return;
        self.busy = NO; self.status = error.localizedDescription;
        BOOL available = [info[@"available"] respondsToSelector:@selector(boolValue)] && [info[@"available"] boolValue];
        BOOL purchased = [info[@"purchased"] respondsToSelector:@selector(boolValue)] && [info[@"purchased"] boolValue];
        self.packageState = error ? nil : CydiaAccountLocalize(available ? (purchased ? @"ACCOUNT_OWNED" : @"ACCOUNT_NOT_OWNED") : @"ACCOUNT_UNAVAILABLE");
        [self.table reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!_sourceURL) return _sources.count;
    return 1 + (_account ? 1 : 0) + (_account.supportsAccountIntegration ? 1 : 0) + (_packageState.length ? 1 : 0);
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!_sourceURL) return CydiaAccountLocalize(@"ACCOUNT_SOURCE_HELP");
    return _status.length ? _status : (_account && !_signedIn ? CydiaAccountLocalize(@"ACCOUNT_SIGN_IN_REQUIRED") : nil);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"account"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"account"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.text = nil; cell.userInteractionEnabled = !_busy;
    if (!_sourceURL) {
        NSDictionary *source = _sources[path.row]; cell.textLabel.text = source[@"name"];
        NSURL *URL = [NSURL URLWithString:source[@"url"]]; cell.detailTextLabel.text = URL.host;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (path.row == 0) {
        cell.textLabel.text = _sourceName ?: _sourceURL.host; cell.detailTextLabel.text = _sourceURL.host;
    } else if (path.row == 1) {
        cell.textLabel.text = _account.name; cell.detailTextLabel.text = CydiaAccountOrigin(_account.providerURL);
    } else if (path.row == 2 && _account.supportsAccountIntegration) {
        cell.textLabel.text = CydiaAccountLocalize(_signedIn ? @"ACCOUNT_SIGN_OUT" : @"ACCOUNT_SIGN_IN");
        cell.detailTextLabel.text = _userName;
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = _package; cell.detailTextLabel.text = _packageState;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (_busy) return;
    if (!_sourceURL) {
        NSDictionary *source = _sources[path.row];
        [self.navigationController pushViewController:[[RepositoryAccountsController alloc]
            initWithSourceURL:[NSURL URLWithString:source[@"url"]] name:source[@"name"] package:nil] animated:YES];
        return;
    }
    if (path.row != 2 || !_account.supportsAccountIntegration) return;
    if (_signedIn) {
        _busy = YES; [_table reloadData];
        [[CydiaRepositoryAccountService sharedService] signOut:_account completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.userName = nil; self.packageState = nil;
            self.status = error.localizedDescription; [self.table reloadData];
        }];
        return;
    }
    NSString *message = [NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_LINK_CONSENT"),
        CydiaAccountOrigin(_sourceURL), CydiaAccountOrigin(_account.providerURL)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CydiaAccountLocalize(@"ACCOUNT_SIGN_IN")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaAccountLocalize(@"ACCOUNT_SIGN_IN") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
        self.busy = YES; [self.table reloadData];
        [[CydiaRepositoryAccountService sharedService] signIn:self.account presenter:self completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
            [self.table reloadData]; if (!error) [self refreshAccount];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
