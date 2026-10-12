/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceAddController.h"
#import "Cydia/SourceAddSession.h"
#import "Cydia/SourceFormControls.h"

@interface CydiaSourceAddController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UITextFieldDelegate, UITextViewDelegate>
@property(nonatomic, strong) CydiaSourceAddSession *session;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *displayedRows;
@property(nonatomic, copy) NSString *editingKey;
@property(nonatomic) BOOL displayedReview;
@property(nonatomic, weak) CyteViewController *presenter;
@property(nonatomic, copy) NSString *originalURL;
@property(nonatomic) BOOL reviewPage, finding, cancelled;
@property(nonatomic, strong) NSProgress *discoveryProgress;
@property(nonatomic, copy) NSString *discoveredRepositoryURI;
@property(nonatomic, copy) NSArray<NSDictionary *> *discoveredPublisherKeys;
- (void)showMessage:(NSString *)message;
- (void)refreshForm;
- (void)changed;
- (BOOL)formFields:(CydiaSources::SourceDraft *)fields;
- (BOOL)applyFields:(const CydiaSources::SourceDraft &)fields;
- (void)showAdvanced;
- (void)check;
@end
@interface CydiaSourceAddController (Discovery)
- (void)findOptions;
- (void)findSigningKey;
- (void)cancelDiscovery;
@end
