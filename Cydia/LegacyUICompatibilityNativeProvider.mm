/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityNativeProvider.h"

#include "Cydia/AppState.h"
#include "Cydia/Application.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/Source.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/LegacyUICompatibilityNativeSnapshot.h"
#include "Cydia/NativeMutationConfirmation.h"
#include "Cydia/UIRouteDispatch.h"
#include "CyteKit/Localize.h"
#include "Sources.h"

#include <dispatch/dispatch.h>
#include <objc/runtime.h>

id CopyValue(id value);

@interface CydiaLegacyUICompatibilityNativeCapability (ProviderBinding)
- (BOOL) _isIssuedForApplication:(id)application;
@end

/* Snapshot construction is deliberately private to this app-owned provider;
 * no native model type crosses the Foundation compatibility boundary. */
@interface CydiaLegacyUICompatibilityNativeSnapshot (ProviderFactory)
+ (instancetype) operationSnapshotWithOperator:(NSString *)operatorValue
                                          value:(NSString *)value
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) clauseSnapshotWithPackage:(NSString *)package
                                    version:(id)version
                              parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) relationSnapshotWithClauses:(NSArray *)clauses
                                  relationship:(NSString *)relationship
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) mimeAddressSnapshotWithAddress:(NSString *)address
                                            name:(NSString *)name
                                    parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
- (BOOL) isBoundToSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
@end

namespace {

BOOL OnMain(BOOL (^operation)(void)) {
    if (operation == nil)
        return NO;
    if ([NSThread isMainThread])
        return operation();
    __block BOOL result(NO);
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = operation();
    });
    return result;
}

BOOL ExactClass(id object, Class expected) {
    return object != nil && expected != Nil && object_getClass(object) == expected;
}

BOOL SafeString(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
        return NO;
    return [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

BOOL SafeSourceText(id value) {
    if (!SafeString(value))
        return NO;
    NSString *text((NSString *)value);
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length ==
        text.length && [text rangeOfString:@"#"].location == NSNotFound;
}

BOOL SafeSourceURL(id value) {
    if (!SafeSourceText(value))
        return NO;
    return CydiaExternalURLIsValidWebURL([NSURL URLWithString:value]);
}

BOOL SafeSourceKey(id value) {
    if (!SafeString(value) || [value length] > 2048 ||
        [value rangeOfString:@"\\"].location != NSNotFound)
        return NO;
    NSString *key((NSString *)value);
    if (![key hasPrefix:@"deb:"] && ![key hasPrefix:@"deb-src:"])
        return NO;
    NSArray *parts([key componentsSeparatedByString:@":"]);
    return [parts count] >= 3 && [[parts objectAtIndex:0] length] != 0 &&
        [[parts objectAtIndex:1] length] != 0 && [[parts lastObject] length] != 0;
}

CydiaLegacyUICompatibilityNativeSnapshot *SnapshotOperation(
    CydiaOperation *operation,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (!ExactClass(operation, [CydiaOperation class]))
        return nil;
    return [CydiaLegacyUICompatibilityNativeSnapshot
        operationSnapshotWithOperator:[operation operator]
        value:[operation value] parentSession:parent];
}

id SnapshotClauseVersion(id version,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (version == nil || version == [NSNull null])
        return [NSNull null];
    return SnapshotOperation((CydiaOperation *)version, parent);
}

CydiaLegacyUICompatibilityNativeSnapshot *SnapshotClause(
    CydiaClause *clause,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (!ExactClass(clause, [CydiaClause class]))
        return nil;
    NSString *package([clause package]);
    id version(SnapshotClauseVersion([clause version], parent));
    if (version == nil)
        return nil;
    return [CydiaLegacyUICompatibilityNativeSnapshot
        clauseSnapshotWithPackage:package version:version parentSession:parent];
}

CydiaLegacyUICompatibilityNativeSnapshot *SnapshotRelation(
    CydiaRelation *relation,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (!ExactClass(relation, [CydiaRelation class]))
        return nil;
    NSArray *models([relation clauses]);
    if (![models isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray *clauses([NSMutableArray arrayWithCapacity:[models count]]);
    for (id model in models) {
        CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
            SnapshotClause((CydiaClause *)model, parent));
        if (snapshot == nil)
            return nil;
        [clauses addObject:snapshot];
    }
    return [CydiaLegacyUICompatibilityNativeSnapshot
        relationSnapshotWithClauses:clauses
        relationship:[relation relationship] parentSession:parent];
}

NSArray *SnapshotPackageRelations(Package *package,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    NSArray *models([package relations]);
    if (![models isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray *snapshots([NSMutableArray arrayWithCapacity:[models count]]);
    for (id model in models) {
        CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
            SnapshotRelation((CydiaRelation *)model, parent));
        if (snapshot == nil)
            return nil;
        [snapshots addObject:snapshot];
    }
    return [[NSArray alloc] initWithArray:snapshots copyItems:YES];
}

CydiaLegacyUICompatibilityNativeSnapshot *SnapshotMIMEAddress(
    MIMEAddress *address,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (!ExactClass(address, [MIMEAddress class]))
        return nil;
    return [CydiaLegacyUICompatibilityNativeSnapshot
        mimeAddressSnapshotWithAddress:[address address]
        name:[address name] parentSession:parent];
}

/* Package::name may be a CYString view into Database's temporary pool.  A
 * global compatibility read can outlive the lookup object, so materialize an
 * owned Foundation string before returning it. */
NSString *OwnedPackageDisplayName(Package *package) {
    if (!ExactClass(package, [Package class]))
        return nil;
    NSString *name([package name]);
    if (![name isKindOfClass:[NSString class]])
        return nil;
    NSMutableString *owned([[NSMutableString alloc] initWithCapacity:[name length]]);
    [owned appendString:name];
    return [owned copy];
}

/* Database::packageWithName: intentionally creates a short-lived Package when
 * the caller is not walking the canonical package array.  Resolve through APT
 * first (retaining its qualified/unqualified architecture semantics), parse as
 * the historical CydiaObject method did, then return only the exact current
 * Package object so a subsequent sessionForPackage: can bind by identity. */
Package *CanonicalPackageForIdentifier(Database *database, NSString *identifier) {
    if (database == nil || ![identifier isKindOfClass:[NSString class]])
        return nil;

    Package *lookup([database packageWithName:identifier]);
    if (!ExactClass(lookup, [Package class]))
        return nil;
    [lookup parse];

    NSString *resolved([[lookup id] copy]);
    if (![resolved isKindOfClass:[NSString class]] || [resolved length] == 0 ||
        [resolved rangeOfString:@"/"].location != NSNotFound ||
        [resolved rangeOfString:@"\\"].location != NSNotFound)
        return nil;

    Package *canonical(nil);
    @synchronized (database) {
        for (id candidate in [database packages]) {
            if (!ExactClass(candidate, [Package class]))
                continue;
            NSString *candidateIdentity([(Package *)candidate id]);
            if ([candidateIdentity isKindOfClass:[NSString class]] &&
                [candidateIdentity isEqualToString:resolved]) {
                canonical = (Package *)candidate;
                break;
            }
        }
    }
    if (canonical != nil)
        [canonical parse];
    return canonical;
}

/* SessionData_ is an old process-local dictionary and may contain mutable
 * Foundation values.  Preserve its historical object semantics while making
 * the value returned across the native session boundary an owned copy whenever
 * the value advertises NSCopying. */
id CopySessionValue(id value) {
    if (value == nil || value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value])
        return value;
    if (![value conformsToProtocol:@protocol(NSCopying)])
        return value;
    @try {
        id copy([value copy]);
        return copy ?: value;
    } @catch (NSException *exception) {
        (void)exception;
        return value;
    }
}

BOOL CurrentPackage(Database *database, Package *package, NSString **identity) {
    if (!ExactClass(package, [Package class]) || database == nil)
        return NO;
    NSString *value([package id]);
    if (!SafeString(value) || [value rangeOfString:@"/"].location != NSNotFound ||
        [value rangeOfString:@"\\"].location != NSNotFound)
        return NO;
    BOOL present(NO);
    for (Package *current in [database packages])
        if (current == package) {
            present = YES;
            break;
        }
    if (!present)
        return NO;
    if (identity != NULL)
        *identity = [value copy];
    return YES;
}

BOOL CurrentSource(Database *database, Source *source, NSString **key) {
    if (!ExactClass(source, [Source class]) || database == nil)
        return NO;
    NSString *value([source key]);
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return NO;
    BOOL present(NO);
    for (Source *current in [database sources])
        if (current == source) {
            present = YES;
            break;
        }
    if (!present)
        return NO;
    if (key != NULL)
        *key = [value copy];
    return YES;
}

BOOL StringsOnly(NSArray *values) {
    if (![values isKindOfClass:[NSArray class]])
        return NO;
    for (id value in values)
        if (!SafeSourceText(value))
            return NO;
    return YES;
}

/* Materialize caller-controlled strings before a confirmation block captures
 * them.  copy on an NSString subclass is not required to return an immutable
 * object, so build an owned immutable value through NSMutableString instead. */
NSString *OwnedCompatibilityString(NSString *value) {
    if (![value isKindOfClass:[NSString class]])
        return nil;
    NSMutableString *owned([[NSMutableString alloc] initWithCapacity:[value length]]);
    [owned appendString:value];
    return [owned copy];
}

NSDictionary *CopySourceMutationPayload(NSString *uri,
                                         NSString *distribution,
                                         NSArray *sections) {
    if (!SafeSourceURL(uri) || !SafeSourceText(distribution) ||
        !StringsOnly(sections))
        return nil;

    NSString *ownedURI(OwnedCompatibilityString(uri));
    NSString *ownedDistribution(OwnedCompatibilityString(distribution));
    if (ownedURI == nil || ownedDistribution == nil)
        return nil;

    NSMutableArray *ownedSections([[NSMutableArray alloc]
        initWithCapacity:[sections count]]);
    for (id value in sections) {
        NSString *ownedSection(OwnedCompatibilityString((NSString *)value));
        if (ownedSection == nil)
            return nil;
        [ownedSections addObject:ownedSection];
    }

    NSArray *sectionSnapshot([[NSArray alloc]
        initWithArray:ownedSections copyItems:YES]);
    return [[NSDictionary alloc] initWithObjectsAndKeys:
        @"deb", @"Type", ownedURI, @"URI", ownedDistribution, @"Distribution",
        sectionSnapshot, @"Sections", nil];
}

/* Retain each package and its canonical identity in an immutable snapshot.
 * The original argument array may be mutable and is intentionally never
 * captured by an asynchronous operation. */
NSArray *CopyPackageMutationSnapshot(NSArray *values, Database *database) {
    if (![values isKindOfClass:[NSArray class]] || database == nil)
        return nil;

    NSArray *input([[NSArray alloc] initWithArray:values copyItems:NO]);
    NSMutableArray *snapshot([[NSMutableArray alloc]
        initWithCapacity:[input count]]);
    for (id value in input) {
        NSString *identity(nil);
        if (!CurrentPackage(database, (Package *)value, &identity))
            return nil;
        NSString *ownedIdentity(OwnedCompatibilityString(identity));
        if (ownedIdentity == nil)
            return nil;
        /* The pair retains the Package object and freezes the identity used
         * for the later main-thread authority check. */
        [snapshot addObject:@[(Package *)value, ownedIdentity]];
    }
    /* Do not ask NSArray to copy the Package objects themselves; retaining
     * the immutable pair is the intended lifetime guarantee. */
    return [[NSArray alloc] initWithArray:snapshot copyItems:NO];
}

BOOL RevalidatePackageMutationSnapshot(NSArray *snapshot, Database *database,
                                        NSArray **packages) {
    if (![snapshot isKindOfClass:[NSArray class]] || database == nil)
        return NO;
    NSMutableArray *validated([[NSMutableArray alloc]
        initWithCapacity:[snapshot count]]);
    for (id value in snapshot) {
        if (![value isKindOfClass:[NSArray class]] || [value count] != 2)
            return NO;
        Package *package([value objectAtIndex:0]);
        NSString *expected([value objectAtIndex:1]);
        NSString *current(nil);
        if (!ExactClass(package, [Package class]) ||
            ![expected isKindOfClass:[NSString class]] ||
            !CurrentPackage(database, package, &current) ||
            ![current isEqualToString:expected])
            return NO;
        [validated addObject:package];
    }
    if (packages != NULL)
        *packages = [validated copy];
    return YES;
}

BOOL IsPackageMutation(NSString *name) {
    return [@[@"clear", @"install", @"remove"] containsObject:name];
}

/* CydiaValues is loaded from CFPreferences as a property-list dictionary.
 * Keep metadata reads bounded and detached from that mutable global before
 * crossing the native compatibility boundary.  A malformed legacy value is
 * treated as unavailable rather than exposing a live object or an arbitrary
 * Objective-C class to the caller. */
const NSUInteger kMaximumMetadataReadKeyCount = 1024;

NSArray *CopyMetadataKeys(NSDictionary *values) {
    if (![values isKindOfClass:[NSDictionary class]])
        return nil;
    @try {
        if ([values count] > kMaximumMetadataReadKeyCount)
            return nil;
        NSArray *rawKeys([values allKeys]);
        if (![rawKeys isKindOfClass:[NSArray class]] ||
            [rawKeys count] != [values count] ||
            [rawKeys count] > kMaximumMetadataReadKeyCount)
            return nil;
        id normalized(nil);
        BOOL removesValue(NO);
        if (!CydiaLegacyUICompatibilityCopyMetadataValue(rawKeys,
                &normalized, &removesValue) || removesValue ||
            ![normalized isKindOfClass:[NSArray class]])
            return nil;
        NSMutableArray *keys([NSMutableArray arrayWithCapacity:[rawKeys count]]);
        for (id rawKey in (NSArray *)normalized) {
            NSString *key(CydiaLegacyUICompatibilityCopyMetadataKey(rawKey));
            if (key == nil)
                return nil;
            [keys addObject:key];
        }
        return [keys copy];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

id CopyMetadataReadValue(id value) {
    if (value == nil || value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value])
        return nil;
    id copy(nil);
    BOOL removesValue(NO);
    if (!CydiaLegacyUICompatibilityCopyMetadataValue(value, &copy,
            &removesValue) || removesValue)
        return nil;
    return copy;
}

} // namespace

/* Source's public mutation methods intentionally queue their internal work.
 * Compatibility commands must defer that work until after the user accepts
 * the native confirmation, so use the existing main-thread primitives here.
 */
@interface Source (CydiaLegacyUICompatibilityNativeConfirmation)
- (bool) _addSection:(NSString *)section;
- (bool) _removeSection:(NSString *)section;
- (void) _remove;
@end


@interface CydiaLegacyUICompatibilityNativeProvider () {
    __weak Cydia *application_;
    __weak Database *database_;
    __weak id presenter_;
    __weak CydiaLegacyUICompatibilityNativeCaller *caller_;
    NSHashTable *sessions_;
    BOOL active_;
}
- (BOOL) sessionIsOwnedAndActive:(CydiaLegacyUICompatibilityNativeSession *)session;
- (CydiaLegacyUICompatibilityNativeSession *) retainSession:(CydiaLegacyUICompatibilityNativeSession *)session;
@end

@implementation CydiaLegacyUICompatibilityNativeProvider

- (instancetype) initWithApplication:(Cydia *)application
                              database:(Database *)database
                             presenter:(id)presenter {
    if (!ExactClass(application, NSClassFromString(@"Cydia")) ||
        !ExactClass(database, [Database class]) || presenter == nil)
        return nil;
    if ((self = [super init]) != nil) {
        application_ = application;
        database_ = database;
        presenter_ = presenter;
        sessions_ = [NSHashTable hashTableWithOptions:
            NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
        active_ = YES;
    }
    return self;
}

- (Cydia *) application { return application_; }
- (Database *) database { return database_; }
- (id) presenter { return presenter_; }
- (BOOL) isActive {
    __block BOOL active(NO);
    __strong Cydia *application(nil);
    __strong Database *database(nil);
    __strong id presenter(nil);
    __strong CydiaLegacyUICompatibilityNativeCaller *caller(nil);
    @synchronized (self) {
        active = active_;
        application = application_;
        database = database_;
        presenter = presenter_;
        caller = caller_;
    }
    return active && application != nil && database != nil && presenter != nil &&
        caller != nil && [caller isActive] &&
        [[caller capability] _isIssuedForApplication:application];
}

- (void) attachCaller:(CydiaLegacyUICompatibilityNativeCaller *)caller {
    if (!ExactClass(caller, [CydiaLegacyUICompatibilityNativeCaller class]) ||
        ![caller isActive] ||
        ![[caller capability] _isIssuedForApplication:application_] ||
        [caller reader] != self || [caller commander] != self ||
        [caller router] != self)
        return;
    @synchronized (self) {
        if (!active_ || (caller_ != nil && caller_ != caller))
            return;
        caller_ = caller;
    }
}

- (BOOL) sessionIsOwnedAndActive:(CydiaLegacyUICompatibilityNativeSession *)session {
    __strong Cydia *application(nil);
    __strong Database *database(nil);
    __strong CydiaLegacyUICompatibilityNativeCaller *caller(nil);
    __strong id presenter(nil);
    BOOL active(NO);
    BOOL member(NO);
    @synchronized (self) {
        active = active_;
        application = application_;
        database = database_;
        caller = caller_;
        presenter = presenter_;
        member = session != nil && [sessions_ containsObject:session];
    }
    return active && member && application != nil && database != nil &&
        presenter != nil && caller != nil && [caller isActive] &&
        [[caller capability] _isIssuedForApplication:application] &&
        ExactClass(session, [CydiaLegacyUICompatibilityNativeSession class]) &&
        [session isActive] &&
        [session presenter] != nil && [session presenter] == presenter &&
        [[session context] inProcessCapability] == [caller capability] &&
        [[session context] caller] == CydiaUIRouteCallerTrustedInProcess;
}

- (CydiaLegacyUICompatibilityNativeSession *) retainSession:(CydiaLegacyUICompatibilityNativeSession *)session {
    if (ExactClass(session, [CydiaLegacyUICompatibilityNativeSession class])) {
        @synchronized (self) {
            if (active_)
                [sessions_ addObject:session];
            else
                session = nil;
        }
    }
    return session;
}

- (void) revokeAuthorityForDiagnosticBoundary:(NSString *)boundary {
    NSString *requested([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BOUNDARY"]);
    if (![NSThread isMainThread] || ![boundary isKindOfClass:[NSString class]] ||
        ![boundary isEqualToString:requested] ||
        !([boundary isEqualToString:@"target"] || [boundary isEqualToString:@"presenter"]))
        return;
    @synchronized (self) {
        /* Clearing the weak provider binding models the two independent
         * authority lifetimes while leaving the session object alive.  The
         * confirmation action must then fail its existing target/presenter
         * rechecks without running an effect. */
        if ([boundary isEqualToString:@"target"])
            database_ = nil;
        else if ([boundary isEqualToString:@"presenter"])
            presenter_ = nil;
    }
}

- (CydiaLegacyUICompatibilityNativeSession *) sessionForPackage:(Package *)package
                                                       presenter:(id)presenter {
    NSString *identity(nil);
    Database *database(database_);
    CydiaLegacyUICompatibilityNativeCaller *caller(caller_);
    id effectivePresenter(presenter ?: presenter_);
    if (!self.isActive || effectivePresenter != presenter_ ||
        !CurrentPackage(database, package, &identity) || caller == nil)
        return nil;
    return [self retainSession:[caller sessionForScope:@"Package" target:package
        packageIdentity:identity sourceKey:nil presenter:effectivePresenter]];
}

- (CydiaLegacyUICompatibilityNativeSession *) sessionForSource:(Source *)source
                                                       presenter:(id)presenter {
    NSString *key(nil);
    Database *database(database_);
    CydiaLegacyUICompatibilityNativeCaller *caller(caller_);
    id effectivePresenter(presenter ?: presenter_);
    if (!self.isActive || effectivePresenter != presenter_ ||
        !CurrentSource(database, source, &key) || caller == nil)
        return nil;
    return [self retainSession:[caller sessionForScope:@"Source" target:source
        packageIdentity:nil sourceKey:key presenter:effectivePresenter]];
}

- (CydiaLegacyUICompatibilityNativeSession *) sessionForApplicationWithPresenter:(id)presenter {
    CydiaLegacyUICompatibilityNativeCaller *caller(caller_);
    id effectivePresenter(presenter ?: presenter_);
    if (!self.isActive || effectivePresenter != presenter_ || caller == nil)
        return nil;
    return [self retainSession:[caller sessionForScope:@"CydiaObject" target:application_
        packageIdentity:nil sourceKey:nil presenter:effectivePresenter]];
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForPackageScope:(NSString *)scope
                memberName:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments {
    (void)scope;
    Database *database(database_);
    NSString *identity(nil);
    if (![self sessionIsOwnedAndActive:session] ||
        !CurrentPackage(database, target, &identity) ||
        ![identity isEqualToString:[session packageIdentity]])
        return nil;
    Package *package((Package *)target);
    if ([memberName isEqualToString:@"getField"] && [arguments count] == 1 &&
        SafeString([arguments objectAtIndex:0]))
        return CopyValue([package getField:[arguments objectAtIndex:0]]);
    if ([memberName isEqualToString:@"getRecord"] && [arguments count] == 0)
        return CopyValue([package getRecord]);
    if ([memberName isEqualToString:@"hasTag"] && [arguments count] == 1 &&
        SafeString([arguments objectAtIndex:0]))
        return @([package hasTag:[arguments objectAtIndex:0]]);

    if ([arguments count] != 0)
        return nil;
    if ([memberName isEqualToString:@"architecture"]) return CopyValue([package architecture]);
    if ([memberName isEqualToString:@"aptId"]) return CopyValue([package aptId]);
    if ([memberName isEqualToString:@"author"])
        return SnapshotMIMEAddress([package author], session);
    if ([memberName isEqualToString:@"baseId"]) return CopyValue([package baseId]);
    if ([memberName isEqualToString:@"depiction"]) return CopyValue([package depiction]);
    if ([memberName isEqualToString:@"dpkgId"]) return CopyValue([package dpkgId]);
    if ([memberName isEqualToString:@"essential"]) return @([package essential]);
    if ([memberName isEqualToString:@"homepage"]) return CopyValue([package homepage]);
    if ([memberName isEqualToString:@"icon"]) return [package icon];
    if ([memberName isEqualToString:@"id"]) return identity;
    if ([memberName isEqualToString:@"installed"]) return CopyValue([package installed]);
    if ([memberName isEqualToString:@"latest"]) return CopyValue([package latest]);
    if ([memberName isEqualToString:@"longDescription"]) return CopyValue([package longDescription]);
    if ([memberName isEqualToString:@"longSection"]) return CopyValue([package longSection]);
    if ([memberName isEqualToString:@"maintainer"])
        return SnapshotMIMEAddress([package maintainer], session);
    if ([memberName isEqualToString:@"md5sum"]) return CopyValue([package md5sum]);
    if ([memberName isEqualToString:@"mode"]) return CopyValue([package mode]);
    if ([memberName isEqualToString:@"multiArch"]) return CopyValue([package multiArch]);
    if ([memberName isEqualToString:@"name"]) return CopyValue([package name]);
    if ([memberName isEqualToString:@"relations"])
        return SnapshotPackageRelations(package, session);
    if ([memberName isEqualToString:@"section"]) return CopyValue([package section]);
    if ([memberName isEqualToString:@"selection"]) return CopyValue([package selection]);
    if ([memberName isEqualToString:@"shortDescription"]) return CopyValue([package shortDescription]);
    if ([memberName isEqualToString:@"shortSection"]) return CopyValue([package shortSection]);
    if ([memberName isEqualToString:@"simpleSection"]) return CopyValue([package simpleSection]);
    if ([memberName isEqualToString:@"size"]) return @([package size]);
    if ([memberName isEqualToString:@"source"]) return [package source];
    if ([memberName isEqualToString:@"state"]) return CopyValue([package state]);
    if ([memberName isEqualToString:@"support"]) return CopyValue([package support]);
    if ([memberName isEqualToString:@"tags"]) return CopyValue([package tags]);
    if ([memberName isEqualToString:@"upgraded"]) return @([package upgraded]);
    if ([memberName isEqualToString:@"warnings"]) return CopyValue([package warnings]);
    if ([memberName isEqualToString:@"applications"]) return CopyValue([package applications]);
    if ([memberName isEqualToString:@"purposes"]) return CopyValue([package purposes]);
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
 valueForNestedSnapshotMember:(NSString *)memberName
                       target:(CydiaLegacyUICompatibilityNativeSnapshot *)target
                    arguments:(NSArray *)arguments {
    Database *database(database_);
    NSString *identity(nil);
    /* Nested values are valid only while their parent Package session remains
     * canonical.  This second check catches a database-era reload even when a
     * caller still retains the old session/snapshot objects. */
    if (![self sessionIsOwnedAndActive:session] ||
        ![[session targetScope] isEqualToString:@"Package"] ||
        !CurrentPackage(database, (Package *)[session target], &identity) ||
        ![identity isEqualToString:[session packageIdentity]] ||
        !ExactClass(target, [CydiaLegacyUICompatibilityNativeSnapshot class]) ||
        ![target isBoundToSession:session] || [arguments count] != 0)
        return nil;

    switch ([target kind]) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
            if ([memberName isEqualToString:@"operator"])
                return [target operationOperator];
            if ([memberName isEqualToString:@"value"])
                return [target operationValue];
            break;
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            if ([memberName isEqualToString:@"package"])
                return [target clausePackage];
            if ([memberName isEqualToString:@"version"])
                return [target clauseVersion];
            break;
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            if ([memberName isEqualToString:@"clauses"])
                return [target relationClauses];
            if ([memberName isEqualToString:@"relationship"])
                return [target relationRelationship];
            break;
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
            if ([memberName isEqualToString:@"address"])
                return [target mimeAddressAddress];
            if ([memberName isEqualToString:@"name"])
                return [target mimeAddressName];
            break;
    }
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForSourceMember:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments {
    Database *database(database_);
    NSString *key(nil);
    if (![self sessionIsOwnedAndActive:session] ||
        !CurrentSource(database, target, &key) ||
        ![key isEqualToString:[session sourceKey]])
        return nil;
    Source *source((Source *)target);
    if ([memberName isEqualToString:@"getField"] && [arguments count] == 1 &&
        SafeString([arguments objectAtIndex:0]))
        return CopyValue([source getField:[arguments objectAtIndex:0]]);
    if ([arguments count] != 0)
        return nil;
    if ([memberName isEqualToString:@"baseuri"]) return CopyValue([source baseuri]);
    if ([memberName isEqualToString:@"distribution"]) return CopyValue([source distribution]);
    if ([memberName isEqualToString:@"host"]) return CopyValue([source host]);
    if ([memberName isEqualToString:@"key"]) return key;
    if ([memberName isEqualToString:@"iconuri"]) return CopyValue([source iconuri]);
    if ([memberName isEqualToString:@"label"]) return CopyValue([source label]);
    if ([memberName isEqualToString:@"name"]) return CopyValue([source name]);
    if ([memberName isEqualToString:@"origin"]) return CopyValue([source origin]);
    if ([memberName isEqualToString:@"rooturi"]) return CopyValue([source rooturi]);
    if ([memberName isEqualToString:@"sections"]) return CopyValue([source sections]);
    if ([memberName isEqualToString:@"shortDescription"]) return CopyValue([source shortDescription]);
    if ([memberName isEqualToString:@"trusted"]) return @([source trusted]);
    if ([memberName isEqualToString:@"type"]) return CopyValue([source type]);
    if ([memberName isEqualToString:@"version"]) return CopyValue([source version]);
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForGlobalMember:(NSString *)memberName
                  arguments:(NSArray *)arguments {
    if (![self sessionIsOwnedAndActive:session] || application_ == nil ||
        [session target] != application_)
        return nil;
    Cydia *application(application_);
    id presenter(presenter_);
    Database *database(database_);

    if ([memberName isEqualToString:@"getMetadataKeys"]) {
        if ([arguments count] != 0 || application == nil)
            return nil;
        NSDictionary *values(Values_);
        if (presenter == nil || [session presenter] != presenter ||
            ![values isKindOfClass:[NSDictionary class]])
            return nil;
        @synchronized (values) {
            if (![self sessionIsOwnedAndActive:session] ||
                application_ != application || [session target] != application ||
                presenter_ != presenter || [session presenter] != presenter ||
                Values_ != values)
                return nil;
            return CopyMetadataKeys(values);
        }
    }

    if ([memberName isEqualToString:@"getMetadataValue"]) {
        if ([arguments count] != 1 || application == nil)
            return nil;
        NSString *key(CydiaLegacyUICompatibilityCopyMetadataKey(
            [arguments objectAtIndex:0]));
        if (key == nil)
            return nil;
        NSDictionary *values(Values_);
        if (presenter == nil || [session presenter] != presenter ||
            ![values isKindOfClass:[NSDictionary class]])
            return nil;
        @synchronized (values) {
            if (![self sessionIsOwnedAndActive:session] ||
                application_ != application || [session target] != application ||
                presenter_ != presenter || [session presenter] != presenter ||
                Values_ != values)
                return nil;
            return CopyMetadataReadValue([values objectForKey:key]);
        }
    }

    if ([memberName isEqualToString:@"getPackageById"]) {
        if ([arguments count] != 1 ||
            ![[arguments objectAtIndex:0] isKindOfClass:[NSString class]])
            return nil;
        Package *package(CanonicalPackageForIdentifier(database,
            [arguments objectAtIndex:0]));
        return package ?: [NSNull null];
    }

    if ([memberName isEqualToString:@"substitutePackageNames"]) {
        if ([arguments count] != 1 ||
            ![[arguments objectAtIndex:0] isKindOfClass:[NSString class]])
            return nil;
        NSString *message([arguments objectAtIndex:0]);
        if (database == nil || ![database hasPackages])
            return message;

        NSMutableArray *words([[message componentsSeparatedByString:@" "] mutableCopy]);
        for (NSUInteger index(0); index != [words count]; ++index) {
            NSString *word([words objectAtIndex:index]);
            Package *package([database packageWithName:word]);
            NSString *name(OwnedPackageDisplayName(package));
            if (name != nil)
                [words replaceObjectAtIndex:index withObject:name];
        }
        return [words componentsJoinedByString:@" "];
    }

    if ([arguments count] != 0)
        return nil;
    if ([memberName isEqualToString:@"getAllSources"])
        return CopyValue([database sources]);
    if ([memberName isEqualToString:@"getInstalledPackages"]) {
        NSMutableArray *installed([NSMutableArray array]);
        for (Package *package in [database packages])
            if ([package installed] != nil)
                [installed addObject:package];
        return [installed copy];
    }
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForSessionMember:(NSString *)memberName
                   arguments:(NSArray *)arguments {
    if (![self sessionIsOwnedAndActive:session] || application_ == nil ||
        [session target] != application_ ||
        ![memberName isEqualToString:@"getSessionValue"] ||
        [arguments count] != 1 ||
        ![[arguments objectAtIndex:0] isKindOfClass:[NSString class]])
        return nil;
    NSMutableDictionary *values(SessionData_);
    if (values == nil)
        return nil;
    @synchronized (values) {
        return CopySessionValue([values objectForKey:[arguments objectAtIndex:0]]);
    }
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
        requestPackageMutation:(NSString *)memberName
                          target:(id)target
                 packageIdentity:(NSString *)packageIdentity
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter {
    Database *database(database_);
    NSString *identity(nil);
    if (![self sessionIsOwnedAndActive:session] || !IsPackageMutation(memberName) ||
        [arguments count] != 0 ||
        !CurrentPackage(database, target, &identity) ||
        ![identity isEqualToString:packageIdentity])
        return NO;
    Cydia *application(application_);
    if (application == nil || presenter != [session presenter] || presenter != presenter_)
        return NO;
    return OnMain(^BOOL {
        NSString *currentIdentity(nil);
        if (![self sessionIsOwnedAndActive:session] ||
            application_ != application || database_ != database ||
            presenter_ != presenter || [session presenter] != presenter ||
            !CurrentPackage(database, (Package *)target, &currentIdentity) ||
            ![currentIdentity isEqualToString:packageIdentity])
            return NO;
        if ([memberName isEqualToString:@"clear"])
            [(id<CydiaDelegate>)application clearPackage:(Package *)target];
        else if ([memberName isEqualToString:@"install"])
            [(id<CydiaDelegate>)application installPackage:(Package *)target];
        else if ([memberName isEqualToString:@"remove"])
            [(id<CydiaDelegate>)application removePackage:(Package *)target];
        else
            return NO;
        return YES;
    });
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
         requestSourceMutation:(NSString *)memberName
                          target:(id)target
                        sourceKey:(NSString *)sourceKey
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter {
    Database *database(database_);
    NSString *key(nil);
    if (![self sessionIsOwnedAndActive:session] ||
        !CurrentSource(database, target, &key) ||
        ![key isEqualToString:sourceKey] || !CydiaManagedSourceKeyIsOwned(key))
        return NO;
    Source *source((Source *)target);
    if (application_ == nil || presenter != [session presenter] || presenter != presenter_)
        return NO;
    if ([memberName isEqualToString:@"addSection"] ||
        [memberName isEqualToString:@"removeSection"]) {
        if ([arguments count] != 1 || !SafeString([arguments objectAtIndex:0]))
            return NO;
        NSString *section([[arguments objectAtIndex:0] copy]);
        NSString *sourceName([source name] ?: key);
        NSString *message([NSString stringWithFormat:@"%@ — %@", sourceName, section]);
        NSString *actionTitle([memberName isEqualToString:@"addSection"] ?
            UCLocalize("ADD") : UCLocalize("REMOVE"));
        __weak CydiaLegacyUICompatibilityNativeProvider *weakSelf(self);
        __weak CydiaLegacyUICompatibilityNativeSession *weakSession(session);
        return PresentNativeConfirmation(presenter, message, actionTitle,
            session, source, [@"Source." stringByAppendingString:memberName], ^BOOL {
            CydiaLegacyUICompatibilityNativeProvider *strongSelf(weakSelf);
            CydiaLegacyUICompatibilityNativeSession *strongSession(weakSession);
            NSString *currentKey(nil);
            if (strongSelf == nil || strongSession == nil ||
                ![strongSelf sessionIsOwnedAndActive:strongSession] ||
                !CurrentSource(strongSelf->database_, source, &currentKey) ||
                ![currentKey isEqualToString:sourceKey] ||
                !CydiaManagedSourceKeyIsOwned(currentKey) ||
                !CydiaCanEditManagedSources() ||
                strongSelf->application_ == nil || strongSelf->presenter_ != presenter ||
                [strongSession presenter] != presenter)
                return NO;
            const bool updated([memberName isEqualToString:@"addSection"]
                ? [source _addSection:section] : [source _removeSection:section]);
            if (!updated)
                return NO;
            [strongSelf->application_ _saveConfig];
            return YES;
        });
    }
    if ([memberName isEqualToString:@"remove"] && [arguments count] == 0)
        return PresentNativeConfirmation(presenter, [source name] ?: key,
            UCLocalize("REMOVE"), session, source, @"Source.remove", ^BOOL {
            CydiaLegacyUICompatibilityNativeProvider *strongSelf(self);
            NSString *currentKey(nil);
            if (![strongSelf sessionIsOwnedAndActive:session] ||
                !CurrentSource(strongSelf->database_, source, &currentKey) ||
                ![currentKey isEqualToString:sourceKey] ||
                !CydiaManagedSourceKeyIsOwned(currentKey) ||
                !CydiaCanEditManagedSources() ||
                strongSelf->application_ == nil || strongSelf->presenter_ != presenter ||
                [session presenter] != presenter)
                return NO;
            [source _remove];
            [strongSelf->application_ syncData];
            return YES;
        });
    return NO;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
    requestApplicationMutation:(NSString *)memberName
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter {
    Cydia *application(application_);
    Database *database(database_);
    if (![self sessionIsOwnedAndActive:session] || [session target] != application_ ||
        application == nil || database == nil || presenter != [session presenter] ||
        presenter != presenter_)
        return NO;
    if ([memberName isEqualToString:@"installPackages"] && [arguments count] == 1) {
        NSArray *packageSnapshot(CopyPackageMutationSnapshot(
            [arguments objectAtIndex:0], database));
        if (packageSnapshot == nil)
            return NO;
        return OnMain(^BOOL {
            NSArray *packages(nil);
            if (![self sessionIsOwnedAndActive:session] ||
                application_ != application || database_ != database ||
                presenter_ != presenter || [session presenter] != presenter ||
                !RevalidatePackageMutationSnapshot(packageSnapshot, database,
                    &packages))
                return NO;
            [(id<CydiaDelegate>)application installPackages:packages];
            return YES;
        });
    }
    if ([memberName isEqualToString:@"refreshSources"] && [arguments count] == 0)
        return PresentNativeConfirmation(presenter, nil, UCLocalize("CONFIRM"),
            session, application, @"CydiaObject.refreshSources", ^BOOL {
            CydiaLegacyUICompatibilityNativeProvider *strongSelf(self);
            if (![strongSelf sessionIsOwnedAndActive:session] ||
                strongSelf->application_ != application || strongSelf->presenter_ != presenter ||
                [session presenter] != presenter)
                return NO;
            [strongSelf->application_ syncData];
            return YES;
        });
    if ([memberName isEqualToString:@"saveConfig"] && [arguments count] == 0)
        return PresentNativeConfirmation(presenter, nil, UCLocalize("CONFIRM"),
            session, application, @"CydiaObject.saveConfig", ^BOOL {
            CydiaLegacyUICompatibilityNativeProvider *strongSelf(self);
            if (![strongSelf sessionIsOwnedAndActive:session] ||
                strongSelf->application_ != application || strongSelf->presenter_ != presenter ||
                [session presenter] != presenter)
                return NO;
            [strongSelf->application_ _saveConfig];
            return YES;
        });
    if ([memberName isEqualToString:@"addTrivialSource"] && [arguments count] == 1 &&
        SafeSourceURL([arguments objectAtIndex:0]) && CydiaCanEditManagedSources()) {
        NSString *candidate([[arguments objectAtIndex:0] copy]);
        return OnMain(^BOOL {
            if (![self sessionIsOwnedAndActive:session]) return NO;
            /* VerifySource may present the legacy invalid-URL alert.  Keep
             * validation and any resulting UIKit work on the main thread. */
            NSString *href(VerifySource(candidate));
            if (href == nil)
                return NO;
            NSString *message([href copy]);
            __weak CydiaLegacyUICompatibilityNativeProvider *weakSelf(self);
            __weak CydiaLegacyUICompatibilityNativeSession *weakSession(session);
            return PresentNativeConfirmation(presenter, message, UCLocalize("ADD"),
                session, application, @"CydiaObject.addTrivialSource", ^BOOL {
                CydiaLegacyUICompatibilityNativeProvider *strongSelf(weakSelf);
                CydiaLegacyUICompatibilityNativeSession *strongSession(weakSession);
                if (strongSelf == nil || strongSession == nil ||
                    ![strongSelf sessionIsOwnedAndActive:strongSession] ||
                    strongSelf->application_ != application || strongSelf->presenter_ != presenter ||
                    [strongSession presenter] != presenter ||
                    !CydiaCanEditManagedSources())
                    return NO;
                [strongSelf->application_ addTrivialSource:href];
                [strongSelf->application_ syncData];
                return YES;
            });
        });
    }
    if ([memberName isEqualToString:@"addSource"] && [arguments count] == 3 &&
        SafeSourceURL([arguments objectAtIndex:0]) && SafeSourceText([arguments objectAtIndex:1]) &&
        StringsOnly([arguments objectAtIndex:2]) && CydiaCanEditManagedSources()) {
        NSDictionary *source(CopySourceMutationPayload(
            [arguments objectAtIndex:0], [arguments objectAtIndex:1],
            [arguments objectAtIndex:2]));
        if (source == nil)
            return NO;
        return PresentNativeConfirmation(presenter, [source objectForKey:@"URI"],
            UCLocalize("ADD"), session, application, @"CydiaObject.addSource", ^BOOL {
            CydiaLegacyUICompatibilityNativeProvider *strongSelf(self);
            if (![strongSelf sessionIsOwnedAndActive:session] ||
                strongSelf->application_ != application || strongSelf->presenter_ != presenter ||
                [session presenter] != presenter ||
                !CydiaCanEditManagedSources())
                return NO;
            [strongSelf->application_ addSource:source];
            [strongSelf->application_ syncData];
            return YES;
        });
    }
    return NO;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
   requestMetadataMutationForKey:(NSString *)key
                            value:(id)value
                          removing:(BOOL)removing
                         presenter:(id)presenter {
    Cydia *application(application_);
    Database *database(database_);
    NSString *canonicalKey(CydiaLegacyUICompatibilityCopyMetadataKey(key));
    id canonicalValue(nil);
    BOOL canonicalRemoving(NO);
    if (![self sessionIsOwnedAndActive:session] ||
        [session target] != application_ || application == nil ||
        database == nil || presenter != [session presenter] ||
        presenter != presenter_ || canonicalKey == nil ||
        !CydiaLegacyUICompatibilityCopyMetadataValue(value, &canonicalValue,
            &canonicalRemoving) || canonicalRemoving != removing ||
        (!canonicalRemoving && canonicalValue == nil) ||
        ![Values_ isKindOfClass:[NSMutableDictionary class]])
        return NO;

    /* UIKit invokes an alert action once, but keep an explicit gate as well:
     * copied/replayed action blocks must never commit metadata twice. */
    NSObject *commitGate([[NSObject alloc] init]);
    __block BOOL committed(NO);
    __weak CydiaLegacyUICompatibilityNativeProvider *weakSelf(self);
    __weak CydiaLegacyUICompatibilityNativeSession *weakSession(session);
    return OnMain(^BOOL {
        if (![self sessionIsOwnedAndActive:session] ||
            ![NSThread isMainThread] || [session target] != application ||
            application_ != application || database_ != database ||
            presenter_ != presenter || [session presenter] != presenter ||
            ![Values_ isKindOfClass:[NSMutableDictionary class]])
            return NO;
        return PresentNativeConfirmation(presenter, canonicalKey,
            UCLocalize("CONFIRM"), session, application, @"CydiaObject.setMetadataValue", ^BOOL {
        if (![NSThread isMainThread])
            return NO;
        @synchronized (commitGate) {
            if (committed)
                return NO;
            committed = YES;
        }
        CydiaLegacyUICompatibilityNativeProvider *strongSelf(weakSelf);
        CydiaLegacyUICompatibilityNativeSession *strongSession(weakSession);
        __strong Cydia *strongApplication(strongSelf == nil ? nil :
            strongSelf->application_);
        NSMutableDictionary *values(Values_);
        if (strongSelf == nil || strongSession == nil ||
            ![strongSelf sessionIsOwnedAndActive:strongSession] ||
            ![NSThread isMainThread] || [strongSession target] != strongApplication ||
            strongApplication == nil || strongApplication != application ||
            strongSelf->database_ == nil || strongSelf->database_ != database ||
            strongSelf->presenter_ == nil || strongSelf->presenter_ != presenter ||
            [strongSession presenter] != presenter || values == nil ||
            ![values isKindOfClass:[NSMutableDictionary class]])
            return NO;
        @synchronized (values) {
            if (canonicalRemoving)
                [values removeObjectForKey:canonicalKey];
            else
                [values setObject:canonicalValue forKey:canonicalKey];
        }
        [strongApplication _saveConfig];
        return YES;
        }, canonicalRemoving ? @"metadata-remove" : @"metadata-set");
    });
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
           sourceKeyExists:(NSString *)sourceKey {
    Database *database(database_);
    return [self sessionIsOwnedAndActive:session] && SafeSourceKey(sourceKey) &&
        database != nil &&
        [database sourceWithKey:sourceKey] != nil;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      handoffRouteDescriptor:(CydiaUIRouteDescriptor *)descriptor
                      context:(CydiaUIRouteContext *)context {
    (void)session;
    Cydia *application(application_);
    if (![self sessionIsOwnedAndActive:session] || application == nil ||
        descriptor == nil || context == nil || context != [session context] ||
        [context inProcessCapability] != [caller_ capability])
        return NO;
    NSURL *url([descriptor originalURL]);
    CydiaUIRouteDispatchResult *route(CydiaUIDispatchRouteURL(url, context,
        ^BOOL(NSString *sourceKey) {
            return [self legacyNativeSession:session sourceKeyExists:sourceKey];
        }));
    if (![route isAllowed] ||
        ![[[route descriptor] originalURL] isEqual:[descriptor originalURL]])
        return NO;
    return OnMain(^BOOL {
        CydiaLegacyUICompatibilityNativeCaller *currentCaller(caller_);
        if (![self sessionIsOwnedAndActive:session] ||
            context != [session context] || currentCaller == nil ||
            [context inProcessCapability] != [currentCaller capability])
            return NO;
        return [application openCydiaURL:url context:context];
    });
}

- (void) invalidate {
    CydiaLegacyUICompatibilityNativeCaller *caller(nil);
    @synchronized (self) {
        if (!active_)
            return;
        active_ = NO;
        caller = caller_;
        caller_ = nil;
        [sessions_ removeAllObjects];
    }
    if (caller != nil)
        [caller invalidate];
}

@end
