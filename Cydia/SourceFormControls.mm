/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceFormControls.h"
#import "Cydia/Appearance.h"
#import "CyteKit/Localize.h"

NSString *CydiaSourceText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Sources"];
}
void CydiaStyleSourceForm(UITableView *table, UITraitCollection *traits) {
    table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
    table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits];
}
void CydiaStyleSourceFormCell(UITableViewCell *cell, UITraitCollection *traits) {
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:traits];
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:traits];
}

@implementation CydiaSourceFieldCell
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder
                         URL:(BOOL)URL traits:(UITraitCollection *)traits {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]) != nil) {
        CydiaStyleSourceFormCell(self, traits); self.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *label([[UILabel alloc] init]); label.text = title; label.numberOfLines = 0;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.adjustsFontForContentSizeCategory = YES;
        label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
        _field = [[UITextField alloc] init]; _field.text = value; _field.placeholder = placeholder;
        _field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _field.adjustsFontForContentSizeCategory = YES;
        _field.textColor = label.textColor; _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone; _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.smartQuotesType = UITextSmartQuotesTypeNo; _field.smartDashesType = UITextSmartDashesTypeNo;
        _field.keyboardType = URL ? UIKeyboardTypeURL : UIKeyboardTypeASCIICapable;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing; _field.returnKeyType = UIReturnKeyDone;
        _field.accessibilityLabel = title;
        UIStackView *stack([[UIStackView alloc] initWithArrangedSubviews:@[label, _field]]);
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [_field.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    }
    return self;
}
@end

@implementation CydiaSourceFormatCell
- (instancetype)initWithTitle:(NSString *)title traits:(UITraitCollection *)traits {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]) != nil) {
        CydiaStyleSourceFormCell(self, traits); self.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *label([[UILabel alloc] init]); label.text = title; label.numberOfLines = 0;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.adjustsFontForContentSizeCategory = YES;
        label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
        _control = [[UISegmentedControl alloc] initWithItems:@[@".list", @".sources"]]; _control.accessibilityLabel = title;
        UIStackView *stack([[UIStackView alloc] initWithArrangedSubviews:@[label, _control]]);
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [_control.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    }
    return self;
}
@end

@implementation CydiaSourceTextCell
- (instancetype)initWithText:(NSString *)text title:(NSString *)title traits:(UITraitCollection *)traits {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]) != nil) {
        CydiaStyleSourceFormCell(self, traits); self.selectionStyle = UITableViewCellSelectionStyleNone;
        _editor = [[UITextView alloc] init]; _editor.text = text;
        _editor.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _editor.adjustsFontForContentSizeCategory = YES;
        _editor.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
        _editor.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
        _editor.layer.cornerRadius = 8; _editor.layer.borderWidth = 1;
        _editor.layer.borderColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits].CGColor;
        _editor.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
        _editor.autocapitalizationType = UITextAutocapitalizationTypeNone; _editor.autocorrectionType = UITextAutocorrectionTypeNo;
        _editor.smartQuotesType = UITextSmartQuotesTypeNo; _editor.smartDashesType = UITextSmartDashesTypeNo;
        _editor.keyboardType = UIKeyboardTypeASCIICapable; _editor.accessibilityLabel = title;
        _editor.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:_editor];
        [NSLayoutConstraint activateConstraints:@[
            [_editor.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_editor.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_editor.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [_editor.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [_editor.heightAnchor constraintEqualToConstant:200]]];
    }
    return self;
}
@end

@implementation CydiaSourceTextController {
    NSString *initial_, *explanation_;
    BOOL URL_, multiline_;
    void (^saved_)(NSString *);
    UITextView *text_;
    NSLayoutConstraint *bottom_;
}
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value
                  explanation:(NSString *)explanation URL:(BOOL)URL multiline:(BOOL)multiline
                         saved:(void (^)(NSString *))saved {
    if ((self = [super init]) != nil) {
        self.title = title; initial_ = [value copy]; explanation_ = [explanation copy];
        URL_ = URL; multiline_ = multiline; saved_ = [saved copy];
    }
    return self;
}
- (void)loadView {
    UIView *root([[UIView alloc] init]);
    UILabel *help([[UILabel alloc] init]); help.text = explanation_; help.numberOfLines = 0;
    help.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; help.adjustsFontForContentSizeCategory = YES;
    help.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    text_ = [[UITextView alloc] init]; text_.text = initial_ ?: @"";
    text_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text_.adjustsFontForContentSizeCategory = YES;
    text_.keyboardType = URL_ ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
    text_.autocapitalizationType = UITextAutocapitalizationTypeNone; text_.autocorrectionType = UITextAutocorrectionTypeNo;
    text_.smartQuotesType = UITextSmartQuotesTypeNo; text_.smartDashesType = UITextSmartDashesTypeNo;
    text_.accessibilityLabel = self.title; text_.accessibilityIdentifier = @"cydia.source-draft.text";
    text_.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    text_.layer.cornerRadius = 8; text_.layer.borderWidth = 1;
    UIStackView *stack([[UIStackView alloc] initWithArrangedSubviews:@[help, text_]]);
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];
    bottom_ = [stack.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-12];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12], bottom_]];
    self.view = root; [self applyAppearance];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE")
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:)
        name:UIKeyboardWillHideNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)keyboard:(NSNotification *)notification {
    if (self.view.window == nil) return;
    CGRect frame([self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]
        fromView:nil]);
    const CGRect overlap(CGRectIntersection(self.view.bounds, frame));
    const CGFloat height([notification.name isEqual:UIKeyboardWillHideNotification] || CGRectIsNull(overlap) ? 0 : overlap.size.height);
    bottom_.constant = -12 - MAX(0, height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]
        animations:^{ [self.view layoutIfNeeded]; }];
}
- (void)applyAppearance {
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    text_.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    text_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    text_.layer.borderColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection].CGColor;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous]; [self applyAppearance]; }
- (void)save {
    NSString *value(text_.text ?: @"");
    if (!multiline_) value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    void (^saved)(NSString *)(saved_);
    UINavigationController *navigation(self.navigationController);
    [navigation popViewControllerAnimated:YES];
    if (navigation.transitionCoordinator != nil)
        [navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (saved != nil) saved(value);
        }];
    else if (saved != nil) saved(value);
}
@end

@interface CydiaSourceChoicesController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaSourceChoicesController {
    NSArray<NSDictionary *> *choices_;
    NSMutableSet<NSString *> *selected_;
    BOOL multiple_;
    NSString *explanation_;
    void (^saved_)(NSSet<NSString *> *);
    UITableView *table_;
}
- (instancetype)initWithTitle:(NSString *)title choices:(NSArray<NSDictionary *> *)choices
                     selected:(NSSet<NSString *> *)selected multiple:(BOOL)multiple
                  explanation:(NSString *)explanation saved:(void (^)(NSSet<NSString *> *))saved {
    if ((self = [super init]) != nil) {
        self.title = title; choices_ = [choices copy]; selected_ = [selected mutableCopy] ?: [NSMutableSet set];
        multiple_ = multiple; explanation_ = [explanation copy]; saved_ = [saved copy];
    }
    return self;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self; table_.rowHeight = UITableViewAutomaticDimension;
    table_.estimatedRowHeight = 64; self.view = table_; CydiaStyleSourceForm(table_, self.traitCollection);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE")
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; CydiaStyleSourceForm(table_, self.traitCollection); [table_ reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return choices_.count; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { return explanation_; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"SourceChoice"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SourceChoice"];
    CydiaStyleSourceFormCell(cell, self.traitCollection); NSDictionary *choice(choices_[path.row]);
    cell.textLabel.text = choice[@"title"]; cell.detailTextLabel.text = choice[@"detail"];
    BOOL selected([selected_ containsObject:choice[@"value"]]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits = (cell.accessibilityTraits & ~UIAccessibilityTraitSelected) | UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSString *value(choices_[path.row][@"value"]);
    if (!multiple_ || [choices_[path.row][@"exclusive"] boolValue]) [selected_ removeAllObjects];
    else for (NSDictionary *choice in choices_) if ([choice[@"exclusive"] boolValue]) [selected_ removeObject:choice[@"value"]];
    if ([selected_ containsObject:value]) [selected_ removeObject:value]; else [selected_ addObject:value];
    [table reloadData];
}
- (void)save {
    NSSet *selected([selected_ copy]); void (^saved)(NSSet<NSString *> *)(saved_);
    UINavigationController *navigation(self.navigationController);
    [navigation popViewControllerAnimated:YES];
    if (navigation.transitionCoordinator != nil)
        [navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (saved != nil) saved(selected);
        }];
    else if (saved != nil) saved(selected);
}
@end
