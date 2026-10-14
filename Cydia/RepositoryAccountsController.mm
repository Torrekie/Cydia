/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/RepositoryPackagePresentation.h"
#import <SafariServices/SafariServices.h>
#import "Cydia/Database.h"
#import "Cydia/Package.h"
#import "Cydia/PackageControllers.h"
#import "Cydia/Source.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

@interface RepositoryAccountsController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *sources;
@property(nonatomic, copy) NSArray<NSDictionary *> *rememberedSources;
@property(nonatomic, copy) NSURL *sourceURL;
@property(nonatomic, copy) NSString *sourceName, *package, *packageName, *version, *architecture;
@property(nonatomic, strong) CydiaRepositoryAccount *account;
@property(nonatomic, copy) NSString *status, *userName, *purchaseStatus;
@property(nonatomic, copy) void (^downloadAction)(void);
@property(nonatomic, copy) BOOL (^selectionValidation)(void);
@property(nonatomic, copy) void (^prepareSelection)(void (^)(BOOL));
@property(nonatomic, copy) NSURL *purchaseURL;
@property(nonatomic, copy) NSURL *recoveryURL;
@property(nonatomic, strong) CydiaRepositoryPackagePresentation *packagePresentation;
@property(nonatomic, copy) NSArray<NSString *> *purchasedItems;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *localItems;
@property(nonatomic, copy) NSDictionary *rememberedMetadata;
@property(nonatomic, copy) NSString *localPackageIdentity;
@property(nonatomic, strong) NSDate *lastChecked;
@property(nonatomic) BOOL busy, loaded, signedIn, authenticationFailed, libraryStale, purchaseInProgress;
@property(nonatomic) BOOL providerCurrent;
@property(nonatomic) BOOL rememberedProviderChanged;
@property(nonatomic) BOOL providerChangedDuringPurchase;
@property(nonatomic) BOOL previousPopGestureEnabled;
@property(nonatomic) BOOL previousHidesBackButton;
@property(nonatomic, strong) UIBarButtonItem *previousLeftBarButtonItem;
@property(nonatomic) NSUInteger requestGeneration;
@end
@implementation RepositoryAccountsController
- (instancetype)init { return [self initWithSourceURL:nil name:nil package:nil]; }
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package {
    return [self initWithSourceURL:sourceURL name:name package:package downloadAction:nil purchaseURL:nil];
}
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL {
    return [self initWithSourceURL:sourceURL name:name package:package packageName:package version:nil architecture:nil
        downloadAction:downloadAction purchaseURL:purchaseURL];
}
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL {
    return [self initWithSourceURL:sourceURL name:name package:package packageName:packageName version:version
        architecture:architecture downloadAction:downloadAction purchaseURL:purchaseURL selectionIsCurrent:nil];
}
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL
               selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent {
    return [self initWithSourceURL:sourceURL name:name package:package packageName:packageName version:version
        architecture:architecture downloadAction:downloadAction purchaseURL:purchaseURL
        selectionIsCurrent:selectionIsCurrent prepareSelection:nil];
}
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL
               selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent
                 prepareSelection:(void (^)(void (^)(BOOL)))prepareSelection {
    if ((self = [super init])) {
        _sourceURL = [sourceURL copy]; _sourceName = [name copy]; _package = [package copy];
        _packageName = [packageName copy]; _version = [version copy]; _architecture = [architecture copy];
        _downloadAction = [downloadAction copy];
        _selectionValidation = [selectionIsCurrent copy];
        _prepareSelection = [prepareSelection copy];
        _purchaseURL = CydiaRepositoryPurchaseWebsite(sourceURL, purchaseURL);
        self.title = packageName.length ? packageName : name.length ? name : CydiaAccountLocalize(@"ACCOUNTS");
    }
    return self;
}
/* Only the root chooser has a stable route; restoring a product page without
 * its owning source/provider and archive selection would lose that scope. */
- (NSURL *)navigationURL { return _sourceURL ? nil : [NSURL URLWithString:@"cydia://home/account"]; }
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
- (void)loadSourceChoices {
    NSMutableArray *sources = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (Source *source in [[Database sharedInstance] sources]) {
        NSString *URL = [source rooturi];
        if (!URL.length || [seen containsObject:URL]) continue;
        [seen addObject:URL];
        [sources addObject:@{@"url": URL, @"name": [source name] ?: URL, @"installed": @YES}];
    }
    NSMutableArray *remembered = [NSMutableArray array];
    for (NSDictionary *account in [[CydiaRepositoryAccountService sharedService] rememberedAccounts]) {
        NSString *URL = account[@"source"];
        if (![URL isKindOfClass:NSString.class] || !URL.length) continue;
        [remembered addObject:@{@"url": URL, @"name": account[@"name"] ?: URL,
            @"installed": @([seen containsObject:URL]), @"metadata": account}];
    }
    _sources = [sources copy]; _rememberedSources = [remembered copy]; [_table reloadData];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_sourceURL) [self loadSourceChoices];
    else if (!_loaded && !_busy) [self loadAccount];
    else if (_loaded && !_busy && _signedIn) [self refreshAccount];
}
- (void)beginLoading {
    _busy = YES; _status = nil; ++_requestGeneration; [_table reloadData];
}
- (BOOL)hasUnresolvedPurchase {
    return _package.length && _account != nil &&
        [[CydiaRepositoryAccountService sharedService] hasUnresolvedPurchase:_package account:_account];
}
- (void)updateRecoveryFromError:(NSError *)error {
    NSURL *URL = [error.domain isEqual:@"CydiaRepositoryAccount"] ?
        CydiaRepositoryPublicWebsite(error.userInfo[CydiaAccountRecoveryURLKey]) : nil;
    if (URL) _recoveryURL = URL;
    else if (!error && ![self hasUnresolvedPurchase]) _recoveryURL = nil;
}
- (void)loadAccount {
    if (_busy || !_sourceURL) return;
    _providerCurrent = NO; _packagePresentation = nil; [self beginLoading];
    NSUInteger generation = _requestGeneration;
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] discoverSource:_sourceURL name:_sourceName ?: _sourceURL.host
        completion:^(CydiaRepositoryAccount *account, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self || self.requestGeneration != generation) return;
        BOOL changedProvider = self.account != nil && account != nil && ![self.account.providerURL isEqual:account.providerURL];
        if (changedProvider) { self.purchasedItems = nil; self.lastChecked = nil; self.purchaseStatus = nil; self.recoveryURL = nil; }
        self.busy = NO; self.loaded = YES; self.providerCurrent = account != nil && error == nil;
        self.rememberedProviderChanged = account != nil && self.rememberedMetadata != nil &&
            ![self.rememberedMetadata[@"provider"] isEqual:account.providerURL.absoluteString];
        if (account != nil) self.account = account;
        if (!self.providerCurrent) self.libraryStale = YES;
        self.status = error.localizedDescription ?: (account && !account.supportsAccountIntegration ? CydiaAccountLocalize(@"ACCOUNT_UNSUPPORTED") : nil);
        self.signedIn = self.account.signedIn;
        [self updateRecoveryFromError:error];
        [self.table reloadData];
        if (self.providerCurrent && self.signedIn) [self refreshAccount];
        else if (self.providerCurrent && self.package.length && account.supportsAccountIntegration) [self refreshPackage];
    }];
}
- (void)updateLocalItems {
    /* Snapshot once after refresh, never repeat APT model lookups while cells
     * scroll. An identical package name at another source is not this item. */
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    Database *database = [Database sharedInstance];
    for (NSString *identifier in _purchasedItems) {
        Package *package = [database packageWithName:identifier];
        if (![[package.source rooturi] isEqual:_sourceURL.absoluteString]) continue;
        if (!package.versionAvailable || !package.architectureSupported) continue;
        items[identifier] = package.name ?: identifier;
    }
    _localItems = [items copy];
}
- (void)refreshAccount {
    if (_busy || !_account || !_providerCurrent) return;
    _packagePresentation = nil; [self beginLoading];
    NSUInteger generation = _requestGeneration;
    __weak RepositoryAccountsController *weakSelf = self;
    [[CydiaRepositoryAccountService sharedService] userInfo:_account completion:^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self || self.requestGeneration != generation) return;
        self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
        if (!error) self.authenticationFailed = NO;
        else if ([error.domain isEqual:@"CydiaRepositoryAccount"] && error.code == CydiaAccountErrorAuthentication)
            self.authenticationFailed = YES;
        id user = info[@"user"];
        if (!error) {
            self.userName = [user isKindOfClass:NSDictionary.class] && [user[@"name"] isKindOfClass:NSString.class] ? user[@"name"] : nil;
            if (self.userName.length > 256) self.userName = [self.userName substringToIndex:256];
            NSArray *items = CydiaRepositoryPurchasedPackageIdentifiers(info);
            if (items != nil) { self.purchasedItems = items; self.lastChecked = [NSDate date]; self.libraryStale = NO; [self updateLocalItems]; }
            else { self.libraryStale = YES; self.status = CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED"); }
        } else self.libraryStale = YES;
        if (!self.signedIn) { self.purchasedItems = nil; self.lastChecked = nil; self.userName = nil; }
        [self updateRecoveryFromError:error];
        [self.table reloadData];
        if (self.package.length && !error) [self refreshPackage];
    }];
}
- (CydiaRepositoryPackagePresentation *)presentationForInfo:(NSDictionary *)info {
    CydiaRepositoryCapabilities capabilities = _account.capabilities;
    BOOL selectedArchiveAction = _downloadAction != nil && _version.length && _architecture.length;
    return [[CydiaRepositoryPackagePresentation alloc] initWithInfo:info
        signedIn:_account.signedIn && !_authenticationFailed supported:_account.supportsAccountIntegration
        downloadAvailable:_downloadAction != nil downloadSupported:!_downloadEngineUnsupported && (capabilities & CydiaRepositoryCapabilityDownload) != 0
        purchaseAvailable:(capabilities & (CydiaRepositoryCapabilityDirectPurchase | CydiaRepositoryCapabilityHostedCheckout)) != 0 &&
            selectedArchiveAction purchaseURL:selectedArchiveAction ? _purchaseURL : nil];
}
- (void)refreshPackage {
    if (_busy || !_account.supportsAccountIntegration || !_package.length || !_providerCurrent) return;
    BOOL authenticated = _account.signedIn;
    _packagePresentation = nil; [self beginLoading];
    NSUInteger generation = _requestGeneration;
    __weak RepositoryAccountsController *weakSelf = self;
    void (^completion)(NSDictionary *, NSError *) = ^(NSDictionary *info, NSError *error) {
        RepositoryAccountsController *self = weakSelf; if (!self || self.requestGeneration != generation) return;
        self.busy = NO; self.signedIn = self.account.signedIn;
        if ([error.domain isEqual:@"CydiaRepositoryAccount"] && error.code == CydiaAccountErrorAuthentication)
            self.authenticationFailed = YES;
        self.packagePresentation = [self presentationForInfo:error ? nil : info];
        Package *localPackage = [[Database sharedInstance] packageWithName:self.package];
        self.localPackageIdentity = [[localPackage.source rooturi] isEqual:self.sourceURL.absoluteString] &&
            localPackage.versionAvailable && localPackage.architectureSupported ? localPackage.id : nil;
        self.status = error.localizedDescription ?: (self.packagePresentation.state == CydiaRepositoryPackageStateUnknown ?
            CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED") : nil);
        if (self.packagePresentation.purchased && !self.packagePresentation.isFree) self.purchaseStatus = nil;
        [self updateRecoveryFromError:error];
        [self.table reloadData];
    };
    if (authenticated) [[CydiaRepositoryAccountService sharedService] packageInfo:_package account:_account completion:completion];
    else [[CydiaRepositoryAccountService sharedService] anonymousPackageInfo:_package account:_account completion:completion];
}
- (NSArray<NSString *> *)accountRows {
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@"source"];
    if (_account) [rows addObject:@"provider"];
    if (_busy) [rows addObject:@"loading"];
    if (_account.supportsAccountIntegration && _providerCurrent) [rows addObject:@"authentication"];
    if (_account.supportsAccountIntegration && _authenticationFailed && _signedIn) [rows addObject:@"logout"];
    if (_loaded && !_busy) [rows addObject:@"refresh"];
    if (_rememberedMetadata && !_busy) [rows addObject:@"forget"];
    if (_recoveryURL && !_busy) [rows addObject:@"help"];
    if ([self hasUnresolvedPurchase] && !_busy) [rows addObject:@"purchase-check"];
    return rows;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return !_sourceURL ? (_rememberedSources.count ? 2 : 1) : 1 + (_package.length ? 1 : 0) + (_signedIn && !_package.length ? 1 : 0);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!_sourceURL) return section == 0 ? _sources.count : _rememberedSources.count;
    if (section == 0) return self.accountRows.count;
    if (section == 1 && _package.length) return 1 + (!_downloadAction && _localPackageIdentity.length ? 1 : 0);
    return MAX((NSUInteger)1, _purchasedItems.count);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!_sourceURL) return CydiaAccountLocalize(section == 0 ? @"ACCOUNT_SOURCES" : @"ACCOUNT_LINKED_ACCOUNTS");
    if (section == 0) return nil;
    return section == 1 && _package.length ? _packageName ?: _package : CydiaAccountLocalize(@"ACCOUNT_PURCHASES");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!_sourceURL) return CydiaAccountLocalize(@"ACCOUNT_SOURCE_HELP");
    if (section == 0) {
        NSMutableArray *messages = [NSMutableArray array];
        if (_downloadEngineUnsupported && !_packagePresentation.isFree) [messages addObject:CydiaAccountLocalize(@"ACCOUNT_DOWNLOAD_ENGINE_UNSUPPORTED")];
        if (_rememberedProviderChanged || _providerChangedDuringPurchase) [messages addObject:CydiaAccountLocalize(@"ACCOUNT_PROVIDER_CHANGED")];
        if (_account.compatibilityNotice.length) [messages addObject:_account.compatibilityNotice];
        if (!_busy && _status.length) [messages addObject:_status];
        if (!_busy && _account.supportsAccountIntegration && !_signedIn) [messages addObject:CydiaAccountLocalize(@"ACCOUNT_SIGN_IN_REQUIRED")];
        return [messages componentsJoinedByString:@"\n\n"];
    }
    if (section == 1 && _package.length) {
        if (_purchaseStatus.length) return _purchaseStatus;
        if (_account && [[CydiaRepositoryAccountService sharedService] hasUnresolvedPurchase:_package account:_account])
            return CydiaAccountLocalize(@"ACCOUNT_PURCHASE_UNKNOWN");
        return _version.length ? [NSString stringWithFormat:@"%@ · %@", _version, _architecture ?: @""] : nil;
    }
    if (!_lastChecked) return nil;
    NSDateFormatter *format = [[NSDateFormatter alloc] init]; format.dateStyle = NSDateFormatterShortStyle; format.timeStyle = NSDateFormatterShortStyle;
    NSString *checked = [NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_LAST_CHECKED"), [format stringFromDate:_lastChecked]];
    return _libraryStale ? [NSString stringWithFormat:@"%@\n%@", CydiaAccountLocalize(@"ACCOUNT_LIBRARY_STALE"), checked] : checked;
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
    cell.accessibilityIdentifier = nil; cell.detailTextLabel.text = nil; cell.textLabel.text = nil; cell.userInteractionEnabled = !_busy;
    if (!_sourceURL) {
        NSDictionary *source = path.section == 0 ? _sources[path.row] : _rememberedSources[path.row]; cell.textLabel.text = source[@"name"];
        NSURL *URL = [NSURL URLWithString:source[@"url"]];
        NSMutableArray *details = [NSMutableArray arrayWithObject:CydiaRepositorySourceDisplayURL(URL) ?: CydiaAccountOrigin(URL)];
        if (source[@"metadata"][@"provider"]) [details addObject:CydiaAccountOrigin([NSURL URLWithString:source[@"metadata"][@"provider"]])];
        if (![source[@"installed"] boolValue]) [details addObject:CydiaAccountLocalize(@"ACCOUNT_SOURCE_REMOVED")];
        cell.detailTextLabel.text = [details componentsJoinedByString:@"\n"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (path.section == 0) {
        NSString *row = self.accountRows[path.row];
        if ([row isEqual:@"source"]) {
            cell.textLabel.text = _sourceName ?: _sourceURL.host;
            cell.detailTextLabel.text = CydiaRepositorySourceDisplayURL(_sourceURL) ?: CydiaAccountOrigin(_sourceURL);
        } else if ([row isEqual:@"provider"]) {
            cell.textLabel.text = _account.name; cell.detailTextLabel.text = CydiaAccountOrigin(_account.providerURL);
        } else if ([row isEqual:@"loading"]) {
            cell.textLabel.text = _purchaseInProgress ? CydiaAccountLocalize(@"ACCOUNT_PURCHASE_PROCESSING") : UCLocalize("LOADING");
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
            spinner.color = cell.textLabel.textColor; [spinner startAnimating]; cell.accessoryView = spinner;
            cell.accessibilityIdentifier = @"cydia.repository.account.loading";
        } else if ([row isEqual:@"authentication"] || [row isEqual:@"logout"]) {
            BOOL logout = [row isEqual:@"logout"] || (_signedIn && !_authenticationFailed);
            cell.textLabel.text = CydiaAccountLocalize(logout ? @"ACCOUNT_SIGN_OUT" : @"ACCOUNT_SIGN_IN");
            cell.detailTextLabel.text = _userName; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if ([row isEqual:@"forget"]) {
            cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_FORGET"); cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.detailTextLabel.text = CydiaAccountOrigin([NSURL URLWithString:_rememberedMetadata[@"provider"]]);
        } else if ([row isEqual:@"help"]) {
            cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_PROVIDER_HELP");
            cell.detailTextLabel.text = [NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_PROVIDER_HELP_DETAIL"),
                CydiaAccountOrigin(_recoveryURL)];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if ([row isEqual:@"purchase-check"]) {
            cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_CHECK_PURCHASE");
            cell.detailTextLabel.text = _packageName ?: _package; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_CHECK_AGAIN"); cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (path.section == 1 && _package.length) {
        if (path.row == 1) {
            cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_VIEW_PACKAGE");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
        NSString *key = @"ACCOUNT_UNAVAILABLE"; BOOL actionable = NO;
        switch (_packagePresentation.state) {
            case CydiaRepositoryPackageStateSignIn: key = @"ACCOUNT_SIGN_IN"; actionable = YES; break;
            case CydiaRepositoryPackageStateBuy: key = @"ACCOUNT_PURCHASE"; actionable = YES; break;
            case CydiaRepositoryPackageStateDownload: key = _returnsToTransactionReview ? @"ACCOUNT_RETURN_TO_REVIEW" : @"ACCOUNT_INSTALL"; actionable = YES; break;
            case CydiaRepositoryPackageStateOwned: key = @"ACCOUNT_OWNED"; break;
            case CydiaRepositoryPackageStateOwnedUnavailable: key = @"ACCOUNT_OWNED_UNAVAILABLE"; break;
            case CydiaRepositoryPackageStateFree: key = @"ACCOUNT_FREE"; break;
            case CydiaRepositoryPackageStateNotPurchased: key = @"ACCOUNT_NOT_PURCHASED"; break;
            case CydiaRepositoryPackageStateUnknown: key = _busy ? @"LOADING" : @"ACCOUNT_CHECK_AGAIN"; actionable = !_busy; break;
            default: break;
        }
        if (!_packagePresentation) { key = _busy ? @"LOADING" : @"ACCOUNT_CHECK_AGAIN"; actionable = !_busy; }
        if (!_busy && !_packagePresentation.isFree && [self hasUnresolvedPurchase]) {
            key = @"ACCOUNT_CHECK_PURCHASE"; actionable = YES;
        }
        cell.textLabel.text = [key isEqual:@"LOADING"] ? UCLocalize("LOADING") : CydiaAccountLocalize(key);
        cell.detailTextLabel.text = _packagePresentation.price.length ?
            [NSString stringWithFormat:@"%@ · %@", _packageName ?: _package, _packagePresentation.price] : _packageName ?: _package;
        cell.accessibilityIdentifier = @"cydia.repository.account.product";
        if (actionable) cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (_purchasedItems.count) {
        NSString *identifier = _purchasedItems[path.row];
        cell.textLabel.text = _localItems[identifier] ?: identifier;
        cell.detailTextLabel.text = _localItems[identifier] ? CydiaAccountLocalize(@"ACCOUNT_OWNED") : CydiaAccountLocalize(@"ACCOUNT_ITEM_NOT_IN_SOURCE");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityIdentifier = [@"cydia.repository.account.item." stringByAppendingString:identifier];
    } else cell.textLabel.text = CydiaAccountLocalize(_purchasedItems ? @"ACCOUNT_NO_PURCHASES" : @"ACCOUNT_CHECK_AGAIN");
    if (cell.selectionStyle == UITableViewCellSelectionStyleDefault) {
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.accessibilityTraits = UIAccessibilityTraitButton | (_busy ? UIAccessibilityTraitNotEnabled : 0);
    }
    return cell;
}
- (void)signIn {
    if (!_providerCurrent || !_account) return;
    NSString *message = [NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_LINK_CONSENT"),
        CydiaRepositorySourceDisplayURL(_sourceURL) ?: CydiaAccountOrigin(_sourceURL), CydiaAccountOrigin(_account.providerURL)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CydiaAccountLocalize(@"ACCOUNT_SIGN_IN")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaAccountLocalize(@"ACCOUNT_SIGN_IN") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
        [self beginLoading];
        [[CydiaRepositoryAccountService sharedService] signIn:self.account presenter:self completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.status = error.localizedDescription;
            if (!error) {
                self.authenticationFailed = NO; self.purchasedItems = nil; self.lastChecked = nil;
                self.userName = nil; self.localItems = nil; self.recoveryURL = nil;
            }
            [self updateRecoveryFromError:error];
            [self.table reloadData]; if (!error) [self refreshAccount];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmPurchase {
    if (_busy || !_providerCurrent || _packagePresentation.state != CydiaRepositoryPackageStateBuy) return;
    if (_selectionValidation && !_selectionValidation()) {
        _downloadAction = nil; _packagePresentation = nil;
        _status = CydiaAccountLocalize(@"ACCOUNT_UNAVAILABLE"); [_table reloadData]; return;
    }
    if ([[CydiaRepositoryAccountService sharedService] hasUnresolvedPurchase:_package account:_account]) { [self refreshPackage]; return; }
    BOOL protocolPurchase = (_account.capabilities & (CydiaRepositoryCapabilityDirectPurchase | CydiaRepositoryCapabilityHostedCheckout)) != 0 &&
        _version.length && _architecture.length && _packagePresentation.price.length;
    if (!protocolPurchase) {
        NSURL *website = _packagePresentation.purchaseURL;
        if (website) [self presentViewController:[[SFSafariViewController alloc] initWithURL:website] animated:YES completion:nil];
        return;
    }
    NSString *price = _packagePresentation.price; CydiaRepositoryAccount *account = _account;
    NSString *message = [NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_PURCHASE_CONFIRM"),
        _packageName ?: _package, price, account.name, CydiaAccountOrigin(account.providerURL)];
    message = [NSString stringWithFormat:@"%@\n\n%@ · %@\n%@", message, _version, _architecture,
        CydiaRepositorySourceDisplayURL(_sourceURL) ?: CydiaAccountOrigin(_sourceURL)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CydiaAccountLocalize(@"ACCOUNT_PURCHASE")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaAccountLocalize(@"ACCOUNT_PURCHASE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (self.busy || self.account != account) return;
        if (self.selectionValidation && !self.selectionValidation()) {
            self.downloadAction = nil; self.packagePresentation = nil;
            self.status = CydiaAccountLocalize(@"ACCOUNT_UNAVAILABLE"); [self.table reloadData]; return;
        }
        self.purchaseInProgress = YES; self.purchaseStatus = nil; [self beginLoading];
        self.previousHidesBackButton = self.navigationItem.hidesBackButton;
        self.previousLeftBarButtonItem = self.navigationItem.leftBarButtonItem;
        [self.navigationItem setHidesBackButton:YES animated:YES];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("CANCEL")
            style:UIBarButtonItemStylePlain target:self action:@selector(cancelPurchase)];
        self.previousPopGestureEnabled = self.navigationController.interactivePopGestureRecognizer.enabled;
        self.navigationController.interactivePopGestureRecognizer.enabled = NO;
        [[CydiaRepositoryAccountService sharedService] purchasePackage:self.package version:self.version architecture:self.architecture
            price:price account:account presenter:self selectionIsCurrent:self.selectionValidation
            prepareSelection:self.prepareSelection completion:^(CydiaRepositoryPurchaseResult *result) {
            self.purchaseInProgress = NO; self.busy = NO;
            self.navigationItem.leftBarButtonItem = self.previousLeftBarButtonItem; self.previousLeftBarButtonItem = nil;
            [self.navigationItem setHidesBackButton:self.previousHidesBackButton animated:YES];
            self.navigationController.interactivePopGestureRecognizer.enabled = self.previousPopGestureEnabled;
            switch (result.state) {
                case CydiaRepositoryPurchaseStateOwned: self.purchaseStatus = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_COMPLETE"); break;
                case CydiaRepositoryPurchaseStateCancelled: self.purchaseStatus = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_CANCELLED"); break;
                case CydiaRepositoryPurchaseStateRejected: self.purchaseStatus = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_REJECTED"); break;
                case CydiaRepositoryPurchaseStatePending: self.purchaseStatus = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_PENDING"); break;
                case CydiaRepositoryPurchaseStateUnknown: self.purchaseStatus = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_UNKNOWN"); break;
            }
            if (result.error) self.status = result.error.localizedDescription;
            [self updateRecoveryFromError:result.error];
            if ([result.error.domain isEqual:@"CydiaRepositoryAccount"] &&
                (result.error.code == CydiaAccountErrorAuthentication || result.error.code == CydiaAccountErrorReauthentication))
                self.authenticationFailed = YES;
            self.packagePresentation = [self presentationForInfo:result.packageInfo];
            [self.table reloadData];
            /* Refresh/restore only reads entitlements. It never repeats the
             * purchase POST, including after cancellation or uncertain I/O. */
            if ([result.error.domain isEqual:@"CydiaRepositoryAccount"] && result.error.code == CydiaAccountErrorProviderChanged) {
                self.providerChangedDuringPurchase = YES;
                [self loadAccount];
            }
            else if (result.state == CydiaRepositoryPurchaseStateOwned) [self refreshAccount];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)cancelPurchase {
    if (_purchaseInProgress) [[CydiaRepositoryAccountService sharedService] cancelPurchaseForAccount:_account];
}
- (void)showOwnedItem:(NSString *)identifier {
    Package *package = [[Database sharedInstance] packageWithName:identifier];
    BOOL sameSource = [[package.source rooturi] isEqual:_sourceURL.absoluteString];
    /* A library item without this source's current supported candidate remains
     * visible for ownership checks, without a route to another repo's copy. */
    RepositoryAccountsController *controller = [[RepositoryAccountsController alloc]
        initWithSourceURL:_sourceURL name:_sourceName package:identifier
        packageName:sameSource ? package.name : identifier version:sameSource ? package.fullVersion : nil
        architecture:sameSource ? package.architecture : nil downloadAction:nil purchaseURL:nil];
    [self.navigationController pushViewController:controller animated:YES];
}
- (void)forgetRememberedAccount {
    NSDictionary *metadata = _rememberedMetadata;
    if (!metadata || _busy) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CydiaAccountLocalize(@"ACCOUNT_FORGET")
        message:[NSString stringWithFormat:CydiaAccountLocalize(@"ACCOUNT_FORGET_CONFIRM"),
            CydiaRepositorySourceDisplayURL([NSURL URLWithString:metadata[@"source"]]) ?:
                CydiaAccountOrigin([NSURL URLWithString:metadata[@"source"]]),
            CydiaAccountOrigin([NSURL URLWithString:metadata[@"provider"]])]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaAccountLocalize(@"ACCOUNT_FORGET") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self beginLoading];
        [[CydiaRepositoryAccountService sharedService] removeRememberedAccount:metadata completion:^(NSError *error) {
            self.busy = NO; self.status = error.localizedDescription;
            if (!error) {
                self.rememberedMetadata = nil; self.purchasedItems = nil; self.lastChecked = nil;
                self.userName = nil; self.signedIn = NO; self.account = nil;
                self.recoveryURL = nil;
            }
            [self.table reloadData];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (_busy) return;
    if (!_sourceURL) {
        NSArray *choices = path.section == 0 ? _sources : _rememberedSources;
        if (path.row < 0 || (NSUInteger)path.row >= choices.count) return;
        NSDictionary *source = choices[path.row];
        RepositoryAccountsController *controller = [[RepositoryAccountsController alloc]
            initWithSourceURL:[NSURL URLWithString:source[@"url"]] name:source[@"name"] package:nil];
        controller.rememberedMetadata = source[@"metadata"];
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }
    if (path.section != 0) {
        if (path.section == 1 && _package.length) {
            if (path.row == 1 && _localPackageIdentity.length) {
                Package *package = [[Database sharedInstance] packageWithName:_localPackageIdentity];
                if (![[package.source rooturi] isEqual:_sourceURL.absoluteString]) { [self refreshPackage]; return; }
                CYPackageController *controller = [[CYPackageController alloc] initWithDatabase:[Database sharedInstance]
                    forPackage:_localPackageIdentity withReferrer:nil];
                [controller setDelegate:self.delegate];
                [self.navigationController pushViewController:controller animated:YES];
            } else if (!_packagePresentation.isFree && [self hasUnresolvedPurchase]) {
                if (!_providerCurrent) [self loadAccount];
                else if (!_account.signedIn) [self signIn];
                else [self refreshPackage];
            } else if (!_packagePresentation || _packagePresentation.state == CydiaRepositoryPackageStateUnknown) {
                if (_account && _providerCurrent) [self refreshPackage]; else [self loadAccount];
            }
            else if (_packagePresentation.state == CydiaRepositoryPackageStateSignIn) [self signIn];
            else if (_packagePresentation.state == CydiaRepositoryPackageStateBuy) [self confirmPurchase];
            else if (_packagePresentation.state == CydiaRepositoryPackageStateDownload && _downloadAction) {
                void (^download)(void) = _downloadAction; _downloadAction = nil;
                _packagePresentation = nil; [_table reloadData]; download();
            }
        } else if ((NSUInteger)path.row < _purchasedItems.count) [self showOwnedItem:_purchasedItems[path.row]];
        return;
    }
    NSArray<NSString *> *rows = self.accountRows;
    if (path.row < 0 || (NSUInteger)path.row >= rows.count) return;
    NSString *row = rows[path.row];
    if ([row isEqual:@"purchase-check"]) {
        if (!_providerCurrent) [self loadAccount]; else if (!_account.signedIn) [self signIn]; else [self refreshPackage];
        return;
    }
    if ([row isEqual:@"help"] && _recoveryURL) {
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:_recoveryURL] animated:YES completion:nil]; return;
    }
    if ([row isEqual:@"forget"]) { [self forgetRememberedAccount]; return; }
    if ([row isEqual:@"refresh"]) { [self loadAccount]; return; }
    if ((![row isEqual:@"authentication"] && ![row isEqual:@"logout"]) || !_account.supportsAccountIntegration) return;
    if ([row isEqual:@"logout"] || (_signedIn && !_authenticationFailed)) {
        [self beginLoading];
        [[CydiaRepositoryAccountService sharedService] signOut:_account completion:^(NSError *error) {
            self.busy = NO; self.signedIn = self.account.signedIn; self.userName = nil; self.packagePresentation = nil;
            self.purchasedItems = nil; self.lastChecked = nil; self.purchaseStatus = nil;
            self.recoveryURL = nil;
            if (!error) self.authenticationFailed = NO;
            self.status = error.localizedDescription; [self.table reloadData];
            if (!error && self.package.length) [self refreshPackage];
        }];
    } else [self signIn];
}
@end
