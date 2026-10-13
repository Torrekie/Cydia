/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/RepositoryPackagePresentation.h"
#import <SafariServices/SafariServices.h>
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
@property(nonatomic, copy) NSString *status, *userName;
@property(nonatomic, copy) void (^downloadAction)(void);
@property(nonatomic, copy) NSURL *purchaseURL;
@property(nonatomic, strong) CydiaRepositoryPackagePresentation *packagePresentation;
@property(nonatomic) BOOL busy, loaded, signedIn, authenticationFailed;
@end
@implementation RepositoryAccountsController
- (instancetype)init { return [self initWithSourceURL:nil name:nil package:nil]; }
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package {
    return [self initWithSourceURL:sourceURL name:name package:package downloadAction:nil purchaseURL:nil];
}
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL {
    if ((self = [super init])) {
        _sourceURL = [sourceURL copy]; _sourceName = [name copy]; _package = [package copy];
        _downloadAction = [downloadAction copy];
        _purchaseURL = CydiaRepositoryPurchaseWebsite(sourceURL, purchaseURL);
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
    } else if (!_loaded && !_busy) [self loadAccount];
    else if (_loaded && !_busy && _signedIn && _package.length) [self refreshAccount];
}
- (void)beginLoading {
    _busy = YES; _status = nil; [_table reloadData];
}
- (void)loadAccount {
    if (_busy || !_sourceURL) return;
    _packagePresentation = nil; _userName = nil; [self beginLoading];
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] discoverSource:_sourceURL name:_sourceName ?: _sourceURL.host
        completion:^(CydiaRepositoryAccount *account, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self) return;
        self.busy = NO; self.loaded = YES; self.account = account;
        self.status = error.localizedDescription ?: (account && !account.supportsAccountIntegration ? CydiaAccountLocalize(@"ACCOUNT_UNSUPPORTED") : nil); self.signedIn = account.signedIn;
        [self.table reloadData];
        if (self.signedIn) [self refreshAccount];
        else if (self.package.length && account.supportsAccountIntegration) [self refreshPackage];
    }];
}
- (void)refreshAccount {
    if (_busy || !_account) return;
    _packagePresentation = nil; [self beginLoading];
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] userInfo:_account completion:^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self) return;
        self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
        if (!error) self.authenticationFailed = NO;
        else if ([error.domain isEqual:@"CydiaRepositoryAccount"] && error.code == CydiaAccountErrorAuthentication)
            self.authenticationFailed = YES;
        id user = info[@"user"];
        self.userName = [user isKindOfClass:NSDictionary.class] && [user[@"name"] isKindOfClass:NSString.class] ? user[@"name"] : nil;
        if (self.userName.length > 256) self.userName = [self.userName substringToIndex:256];
        [self.table reloadData];
        if (self.package.length && !error) [self refreshPackage];
    }];
}
- (void)refreshPackage {
    if (_busy || !_account.supportsAccountIntegration || !_package.length) return;
    const BOOL authenticated = _account.signedIn;
    _packagePresentation = nil; [self beginLoading];
    __weak RepositoryAccountsController *weakSelf = self;
    void (^completion)(NSDictionary *, NSError *) = ^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self) return;
        self.busy = NO; self.signedIn = self.account.signedIn;
        if ([error.domain isEqual:@"CydiaRepositoryAccount"] && error.code == CydiaAccountErrorAuthentication)
            self.authenticationFailed = YES;
        self.packagePresentation = [[CydiaRepositoryPackagePresentation alloc] initWithInfo:error ? nil : info
            signedIn:authenticated && self.signedIn && !self.authenticationFailed supported:self.account.supportsAccountIntegration
            downloadAvailable:self.downloadAction != nil purchaseURL:self.purchaseURL];
        self.status = error.localizedDescription ?: (self.packagePresentation.state == CydiaRepositoryPackageStateUnknown ?
            CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED") : nil);
        [self.table reloadData];
    };
    if (authenticated)
        [[CydiaRepositoryAccountService sharedService] packageInfo:_package account:_account completion:completion];
    else
        [[CydiaRepositoryAccountService sharedService] anonymousPackageInfo:_package account:_account completion:completion];
}
- (NSArray<NSString *> *)accountRows {
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@"source"];
    if (_account) [rows addObject:@"provider"];
    if (_busy) [rows addObject:@"loading"];
    if (_account.supportsAccountIntegration) [rows addObject:@"authentication"];
    if (_account.supportsAccountIntegration && _authenticationFailed && _signedIn) [rows addObject:@"logout"];
    if (_packagePresentation && _packagePresentation.state != CydiaRepositoryPackageStateUnknown)
        [rows addObject:@"package"];
    if (_loaded && !_busy) [rows addObject:@"refresh"];
    return rows;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!_sourceURL) return _sources.count;
    return self.accountRows.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!_sourceURL) return CydiaAccountLocalize(@"ACCOUNT_SOURCE_HELP");
    if (_busy) return nil;
    return _status.length ? _status : (_account.supportsAccountIntegration && !_signedIn ? CydiaAccountLocalize(@"ACCOUNT_SIGN_IN_REQUIRED") : nil);
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
    cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    cell.accessibilityIdentifier = nil;
    cell.detailTextLabel.text = nil; cell.userInteractionEnabled = !_busy;
    if (!_sourceURL) {
        NSDictionary *source = _sources[path.row]; cell.textLabel.text = source[@"name"];
        NSURL *URL = [NSURL URLWithString:source[@"url"]]; cell.detailTextLabel.text = URL.host;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if ([self.accountRows[path.row] isEqual:@"source"]) {
        cell.textLabel.text = _sourceName ?: _sourceURL.host; cell.detailTextLabel.text = _sourceURL.host;
    } else if ([self.accountRows[path.row] isEqual:@"provider"]) {
        cell.textLabel.text = _account.name; cell.detailTextLabel.text = CydiaAccountOrigin(_account.providerURL);
    } else if ([self.accountRows[path.row] isEqual:@"loading"]) {
        cell.textLabel.text = UCLocalize("LOADING");
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        spinner.color = cell.textLabel.textColor; [spinner startAnimating]; cell.accessoryView = spinner;
        cell.accessibilityIdentifier = @"cydia.repository.account.loading";
    } else if ([self.accountRows[path.row] isEqual:@"authentication"] || [self.accountRows[path.row] isEqual:@"logout"]) {
        const BOOL logout = [self.accountRows[path.row] isEqual:@"logout"] || (_signedIn && !_authenticationFailed);
        cell.textLabel.text = CydiaAccountLocalize(logout ? @"ACCOUNT_SIGN_OUT" : @"ACCOUNT_SIGN_IN");
        cell.detailTextLabel.text = _userName;
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if ([self.accountRows[path.row] isEqual:@"refresh"]) {
        cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_CHECK_AGAIN");
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        NSString *key = @"ACCOUNT_UNAVAILABLE";
        BOOL actionable = NO;
        switch (_packagePresentation.state) {
            case CydiaRepositoryPackageStateSignIn: key = @"ACCOUNT_SIGN_IN_REQUIRED"; break;
            case CydiaRepositoryPackageStateBuy: key = @"ACCOUNT_BUY"; actionable = YES; break;
            case CydiaRepositoryPackageStateDownload: key = @"ACCOUNT_DOWNLOAD"; actionable = YES; break;
            case CydiaRepositoryPackageStateOwned: key = @"ACCOUNT_OWNED"; break;
            case CydiaRepositoryPackageStateNotPurchased:
                key = CydiaRepositoryPublicWebsite(_sourceURL) ? @"ACCOUNT_WEBSITE" : @"ACCOUNT_NOT_OWNED";
                actionable = CydiaRepositoryPublicWebsite(_sourceURL) != nil; break;
            default: break;
        }
        cell.textLabel.text = actionable ? CydiaAccountLocalize(key) : _package;
        cell.detailTextLabel.text = actionable ? _package : CydiaAccountLocalize(key);
        if (_packagePresentation.state == CydiaRepositoryPackageStateBuy)
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", _package,
                CydiaAccountOrigin(_packagePresentation.purchaseURL)];
        if (actionable) {
            cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    }
    if (cell.selectionStyle == UITableViewCellSelectionStyleDefault)
        cell.accessibilityTraits = UIAccessibilityTraitButton | (_busy ? UIAccessibilityTraitNotEnabled : 0);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (_busy) return;
    if (!_sourceURL) {
        if (path.row < 0 || (NSUInteger)path.row >= _sources.count) return;
        NSDictionary *source = _sources[path.row];
        [self.navigationController pushViewController:[[RepositoryAccountsController alloc]
            initWithSourceURL:[NSURL URLWithString:source[@"url"]] name:source[@"name"] package:nil] animated:YES];
        return;
    }
    NSArray<NSString *> *rows = self.accountRows;
    if (path.row < 0 || (NSUInteger)path.row >= rows.count) return;
    NSString *row = rows[path.row];
    if ([row isEqual:@"refresh"]) { [self loadAccount]; return; }
    if ([row isEqual:@"package"] && _account.supportsAccountIntegration && _account.signedIn && !_authenticationFailed) {
        if (_packagePresentation.state == CydiaRepositoryPackageStateDownload && _downloadAction) {
            void (^download)(void) = _downloadAction; _downloadAction = nil;
            _packagePresentation = nil; [_table reloadData]; download();
        } else {
            NSURL *website = _packagePresentation.state == CydiaRepositoryPackageStateBuy ? _packagePresentation.purchaseURL :
                _packagePresentation.state == CydiaRepositoryPackageStateNotPurchased ? CydiaRepositoryPublicWebsite(_sourceURL) : nil;
            if (website) [self presentViewController:[[SFSafariViewController alloc] initWithURL:website] animated:YES completion:nil];
        }
        return;
    }
    if ((![row isEqual:@"authentication"] && ![row isEqual:@"logout"]) || !_account.supportsAccountIntegration) return;
    if ([row isEqual:@"logout"] || (_signedIn && !_authenticationFailed)) {
        [self beginLoading];
        [[CydiaRepositoryAccountService sharedService] signOut:_account completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.userName = nil; self.packagePresentation = nil;
            if (!error) self.authenticationFailed = NO;
            self.status = error.localizedDescription; [self.table reloadData];
            if (!error && self.package.length) [self refreshPackage];
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
        [self beginLoading];
        [[CydiaRepositoryAccountService sharedService] signIn:self.account presenter:self completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
            if (!error) self.authenticationFailed = NO;
            [self.table reloadData]; if (!error) [self refreshAccount];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
