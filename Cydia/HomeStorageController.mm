/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/HomeStorageController.h"
#import "Cydia/UIColor+Cydia.h"
#import "Cydia/HomeTableAppearance.h"
#import "Cydia/NativeAccessibilityTrace.h"
#import "CyteKit/Localize.h"
#include <dirent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <limits.h>
#include <string.h>

static NSString *StorageTitle(NSString *fallback) {
    return [[NSBundle mainBundle] localizedStringForKey:@"HOME_STORAGE_INFORMATION"
        value:UCLocalizeEx(@"HOME_STORAGE_INFORMATION", fallback) table:@"Home"];
}

static unsigned long long AllocatedUsageAtPath(const char *path) {
    struct stat item;
    if (lstat(path, &item) != 0)
        return 0;
    unsigned long long result = (unsigned long long)item.st_blocks * 512ULL;
    if ((item.st_mode & S_IFMT) != S_IFDIR)
        return result;
    DIR *directory = opendir(path);
    if (directory == NULL)
        return result;
    while (struct dirent *entry = readdir(directory)) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        char child[PATH_MAX];
        int length = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
        if (length > 0 && (size_t)length < sizeof(child))
            result += AllocatedUsageAtPath(child);
    }
    closedir(directory);
    return result;
}

static unsigned long long AllocatedUsage(NSString *path) {
    return AllocatedUsageAtPath(path.fileSystemRepresentation);
}

static NSString *StorageSize(unsigned long long bytes) {
    double value = bytes / (1024.0 * 1024.0);
    if (value < 1000.0)
        return [NSString stringWithFormat:@"%.1f MB", value];
    return [NSString stringWithFormat:@"%.1f GB", value / 1024.0];
}

static NSString *StoragePercent(unsigned long long bytes, unsigned long long total) {
    if (total == 0)
        return @"—";
    return [NSString stringWithFormat:@"%.1f%%", 100.0 * bytes / (double)total];
}

@interface HomeStorageController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@property(nonatomic) BOOL collecting;
@end

@implementation HomeStorageController
- (instancetype)init {
    if ((self = [super init]))
        self.title = StorageTitle(@"Storage Information");
    return self;
}

- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/storage"]; }

- (void)loadView {
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 54;
    _table.accessibilityIdentifier = @"cydia.home.storage.rows";
    self.view = _table;
    _sections = @[
        @{@"header": UCLocalizeEx(@"HOME_STORAGE_INFORMATION", @"Storage"),
          @"rows": @[
              @{@"id": @"intro", @"text": UCLocalizeEx(@"HOME_STORAGE_INTRO",
                  @"This feature shows how much storage space you have on your device, to show how much room you have for new packages.")},
              @{@"id": @"warning", @"text": UCLocalizeEx(@"HOME_STORAGE_WARNING",
                  @"Note: Storage may take a long time to display while data is measured.")},
          ]},
        @{@"header": UCLocalizeEx(@"HOME_STORAGE_SYSTEM", @"System"),
          @"rows": @[
              @{@"id": @"system-total", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
              @{@"id": @"system-used", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
              @{@"id": @"system-free", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
          ]},
        @{@"header": UCLocalizeEx(@"HOME_STORAGE_PRIVATE", @"Private"),
          @"rows": @[
              @{@"id": @"private-total", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
              @{@"id": @"private-used", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
              @{@"id": @"private-free", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
              @{@"id": @"private-other", @"text": UCLocalizeEx(@"HOME_STORAGE_CALCULATING", @"Measuring…")},
          ]},
        @{@"header": UCLocalizeEx(@"HOME_STORAGE_CATEGORIES", @"Private data"),
          @"rows": @[
              @{@"id": @"themes", @"text": UCLocalizeEx(@"HOME_STORAGE_THEMES", @"Themes")},
              @{@"id": @"itunes", @"text": UCLocalizeEx(@"HOME_STORAGE_ITUNES", @"iTunes")},
              @{@"id": @"apps", @"text": UCLocalizeEx(@"HOME_STORAGE_APPS", @"App Store")},
              @{@"id": @"camera", @"text": UCLocalizeEx(@"HOME_STORAGE_CAMERA", @"Camera")},
          ]},
    ];
    [self applyAppearance];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section][@"header"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _sections[indexPath.section][@"rows"][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                    reuseIdentifier:nil];
    cell.accessibilityIdentifier = [@"cydia.home.storage." stringByAppendingString:row[@"id"]];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row[@"text"];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.text = row[@"value"];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                      compatibleWithTraitCollection:self.traitCollection];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                            compatibleWithTraitCollection:self.traitCollection];
    cell.accessibilityLabel = row[@"value"] ? [NSString stringWithFormat:@"%@, %@", row[@"text"], row[@"value"]] : row[@"text"];
    [self applyAppearanceToCell:cell];
    return cell;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CydiaCaptureNativeAccessibility(self, @"home-storage");
    if (!_collecting) {
        _collecting = YES;
        [self collectUsage];
    }
}

- (void)collectUsage {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        struct statfs systemInfo = {0}, privateInfo = {0};
        BOOL systemOK = statfs("/", &systemInfo) == 0;
        BOOL privateOK = statfs("/private/var", &privateInfo) == 0;
        unsigned long long systemTotal = systemOK ? (unsigned long long)systemInfo.f_blocks * systemInfo.f_bsize : 0;
        unsigned long long systemFree = systemOK ? (unsigned long long)systemInfo.f_bfree * systemInfo.f_bsize : 0;
        unsigned long long privateTotal = privateOK ? (unsigned long long)privateInfo.f_blocks * privateInfo.f_bsize : 0;
        unsigned long long privateFree = privateOK ? (unsigned long long)privateInfo.f_bfree * privateInfo.f_bsize : 0;
        NSArray *paths = @[
            @[@"themes", @"/Library/Themes"],
            @[@"itunes", @"/var/mobile/Media/iTunes_Control"],
            @[@"apps", @"/var/mobile/Applications"],
            @[@"apps", @"/var/mobile/Containers"],
            @[@"camera", @"/var/mobile/Media/DCIM"],
        ];
        NSMutableDictionary *usage = [NSMutableDictionary dictionary];
        for (NSArray *pair in paths)
            usage[pair[0]] = @([usage[pair[0]] unsignedLongLongValue] + AllocatedUsage(pair[1]));
        unsigned long long used = 0;
        for (NSNumber *value in usage.allValues)
            used += value.unsignedLongLongValue;
        unsigned long long other = privateTotal > privateFree + used ? privateTotal - privateFree - used : 0;
        NSDictionary *values = @{
            @"system-total": systemOK ? StorageSize(systemTotal) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"system-used": systemOK ? StorageSize(systemTotal > systemFree ? systemTotal - systemFree : 0) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"system-free": systemOK ? StorageSize(systemFree) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"private-total": privateOK ? StorageSize(privateTotal) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"private-used": privateOK ? StorageSize(privateTotal > privateFree ? privateTotal - privateFree : 0) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"private-free": privateOK ? StorageSize(privateFree) : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"private-other": privateOK ? [NSString stringWithFormat:@"%@ (%@)", StorageSize(other), StoragePercent(other, privateTotal)] : UCLocalizeEx(@"HOME_STORAGE_ERROR", @"Unavailable"),
            @"themes": [NSString stringWithFormat:@"%@ (%@)", StorageSize([usage[@"themes"] unsignedLongLongValue]), StoragePercent([usage[@"themes"] unsignedLongLongValue], privateTotal)],
            @"itunes": [NSString stringWithFormat:@"%@ (%@)", StorageSize([usage[@"itunes"] unsignedLongLongValue]), StoragePercent([usage[@"itunes"] unsignedLongLongValue], privateTotal)],
            @"apps": [NSString stringWithFormat:@"%@ (%@)", StorageSize([usage[@"apps"] unsignedLongLongValue]), StoragePercent([usage[@"apps"] unsignedLongLongValue], privateTotal)],
            @"camera": [NSString stringWithFormat:@"%@ (%@)", StorageSize([usage[@"camera"] unsignedLongLongValue]), StoragePercent([usage[@"camera"] unsignedLongLongValue], privateTotal)],
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *sections = [_sections mutableCopy];
            for (NSUInteger s = 0; s < sections.count; ++s) {
                NSMutableDictionary *section = [sections[s] mutableCopy];
                NSMutableArray *rows = [section[@"rows"] mutableCopy];
                for (NSUInteger r = 0; r < rows.count; ++r) {
                    NSMutableDictionary *row = [rows[r] mutableCopy];
                    NSString *value = values[row[@"id"]];
                    if (value) row[@"value"] = value;
                    rows[r] = row;
                }
                section[@"rows"] = rows;
                sections[s] = section;
            }
            _sections = sections;
            [_table reloadData];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self applyAppearance]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) {
        [_table reloadData];
        [self applyAppearance];
    }
}
- (void)applyAppearanceToCell:(UITableViewCell *)cell {
    HomeApplyCellSurface(cell, CydiaColorRoleCellBackground, self.traitCollection);
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
}
- (void)applyAppearance {
    _table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    _table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    for (UITableViewCell *cell in _table.visibleCells)
        [self applyAppearanceToCell:cell];
    self.navigationController.navigationBar.barStyle =
        self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
    self.navigationController.navigationBar.tintColor =
        [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
}
@end
