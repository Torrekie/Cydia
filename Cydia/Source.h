#ifndef Cydia_Source_H
#define Cydia_Source_H

#include "Cydia/CYString.hpp"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>

#include <apt-pkg/acquire.h>
#include <apt-pkg/sourcelist.h>

#include <set>
#include <string>

@class Database;

@protocol SourceDelegate
- (void) setFetch:(NSNumber *)fetch;
@end

extern _H<NSMutableDictionary> Sources_;

@interface Source : NSObject {
    unsigned era_;
    __weak Database *database_;
    metaIndex *index_;

    CYString depiction_;
    CYString description_;
    CYString label_;
    CYString origin_;
    CYString support_;

    CYString uri_;
    CYString distribution_;
    CYString type_;
    CYString base_;
    CYString version_;

    _H<NSString> host_;
    _H<NSString> authority_;

    CYString defaultIcon_;

    _H<NSMutableDictionary> record_;
    BOOL trusted_;

    std::set<std::string> fetches_;
    std::set<std::string> files_;
    __weak NSObject<SourceDelegate> *delegate_;
}

- (Source *) initWithMetaIndex:(metaIndex *)index forDatabase:(Database *)database inPool:(CYPool *)pool withAcquire:(pkgAcquire *)acquire;

- (NSString *) getField:(NSString *)name;
- (NSArray *) sections;
- (bool) addSection:(NSString *)section;
- (bool) removeSection:(NSString *)section;
- (bool) remove;

- (NSComparisonResult) compareByName:(Source *)source;

- (NSString *) depictionForPackage:(NSString *)package;
- (NSString *) supportForPackage:(NSString *)package;

- (metaIndex *) metaIndex;
- (NSDictionary *) record;
- (BOOL) trusted;

- (NSString *) rooturi;
- (NSString *) distribution;
- (NSString *) type;
- (NSString *) baseuri;
- (NSString *) iconuri;

- (NSString *) key;
- (NSString *) host;

- (NSString *) name;
- (NSString *) shortDescription;
- (NSString *) label;
- (NSString *) origin;
- (NSString *) version;

- (NSString *) defaultIcon;
- (NSURL *) iconURL;

- (void) setFetch:(bool)fetch forURI:(const char *)uri;
- (void) resetFetch;
- (void) setDelegate:(NSObject<SourceDelegate> *)delegate;
- (bool) fetch;

@end

#endif//Cydia_Source_H
