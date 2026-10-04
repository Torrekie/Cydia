/* Cydia Refurbished bounded repository-depiction compatibility facade.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDepictionJavaScriptFacade.h"

namespace {

BOOL ValidOrigin(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]] || [URL baseURL] != nil ||
        [[URL user] length] != 0 || [[URL password] length] != 0 ||
        [[URL host] length] == 0)
        return NO;
    NSString *scheme([[URL scheme] lowercaseString]);
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

NSInteger EffectivePort(NSURL *URL) {
    NSNumber *port([URL port]);
    if (port != nil)
        return [port integerValue];
    return [[[URL scheme] lowercaseString] isEqualToString:@"https"] ? 443 : 80;
}

BOOL SameOrigin(NSURL *first, NSURL *second) {
    return ValidOrigin(first) && ValidOrigin(second) &&
        [[[first scheme] lowercaseString] isEqualToString:
            [[second scheme] lowercaseString]] &&
        [[[first host] lowercaseString] isEqualToString:
            [[second host] lowercaseString]] &&
        EffectivePort(first) == EffectivePort(second);
}

NSString *OwnedToken(void) {
    NSString *token([[[NSUUID alloc] init] UUIDString]);
    return [token length] == 0 ? @"cydia-depiction-binding" : token;
}

NSString *JSONForPayload(NSDictionary *payload) {
    NSError *error(nil);
    NSData *data([NSJSONSerialization dataWithJSONObject:payload options:0 error:&error]);
    if (data == nil || error != nil)
        return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

} // namespace


@interface CydiaPackageDepictionJavaScriptFacade () {
    NSDictionary *_snapshot;
    NSString *_bindingToken;
    __weak WKWebView *_webView;
    NSUInteger _generation;
    BOOL _revoked;
    BOOL _lastMessageAccepted;
    BOOL _installed;
}
@end


@implementation CydiaPackageDepictionJavaScriptFacade

- (instancetype)initWithSnapshot:(NSDictionary *)snapshot
                            origin:(NSURL *)origin
                  packageIdentity:(NSString *)packageIdentity {
    if (![snapshot isKindOfClass:[NSDictionary class]] || !ValidOrigin(origin) ||
        ![packageIdentity isKindOfClass:[NSString class]] ||
        [packageIdentity length] == 0)
        return nil;
    if ((self = [super init]) != nil) {
        _snapshot = [[NSDictionary alloc] initWithDictionary:snapshot copyItems:YES];
        _origin = [origin copy];
        _packageIdentity = [packageIdentity copy];
        _bindingToken = OwnedToken();
        _generation = 1;
        _revoked = NO;
        _lastMessageAccepted = NO;
        _installed = NO;
    }
    return self;
}

- (NSUInteger)generation {
    @synchronized (self) { return _generation; }
}

- (BOOL)isRevoked {
    @synchronized (self) { return _revoked; }
}

- (BOOL)lastMessageAccepted {
    @synchronized (self) { return _lastMessageAccepted; }
}

+ (NSString *)scriptForSnapshot:(NSDictionary *)snapshot
                          origin:(NSURL *)origin
                packageIdentity:(NSString *)packageIdentity
                      generation:(NSUInteger)generation
                   bindingToken:(NSString *)bindingToken {
    if (![snapshot isKindOfClass:[NSDictionary class]] || !ValidOrigin(origin) ||
        ![packageIdentity isKindOfClass:[NSString class]] ||
        [packageIdentity length] == 0 ||
        ![bindingToken isKindOfClass:[NSString class]] ||
        [bindingToken length] == 0 || generation == 0)
        return nil;

    NSDictionary *payload(@{
        @"snapshot": snapshot,
        @"origin": [NSString stringWithFormat:@"%@://%@:%ld",
                     [[origin scheme] lowercaseString], [origin host],
                     (long) EffectivePort(origin)],
        @"packageIdentity": packageIdentity,
        @"generation": @(generation),
        @"binding": bindingToken,
    });
    NSString *json(JSONForPayload(payload));
    if (json == nil)
        return nil;

    /* The script is intentionally self-contained and uses only ES5-era
     * operations available to the iOS 12 WebKit.  It creates one immutable
     * data reader; no selector, device/global value, or
     * mutation callback is reachable from repository HTML. */
    NSString *prefix =
        @"(function(){'use strict';var p=";
    NSString *body =
        @";var bad=function(v){return v===null||typeof v==='undefined';};"
         "var own=function(o,k){return Object.prototype.hasOwnProperty.call(o,k);};"
         "var freeze=function(v){if(!v||typeof v!=='object'||Object.isFrozen(v))return v;"
         "Object.keys(v).forEach(function(k){if(k!=='__proto__'&&k!=='constructor'&&k!=='prototype')freeze(v[k]);});"
         "return Object.freeze(v);};"
         "var copy=function(v){if(bad(v))return null;if(typeof v!=='object')return v;"
         "if(Array.isArray(v))return v.map(copy);var o={};Object.keys(v).forEach(function(k){"
         "if(k!=='__proto__'&&k!=='constructor'&&k!=='prototype')o[k]=copy(v[k]);});return o;};"
         "var sourceKeys=['baseuri','distribution','host','key','iconuri','label','name','origin','rooturi','sections','shortDescription','trusted','type','version'];"
         "var project=function(o,d,keys){keys.forEach(function(k){if(own(d,k))o[k]=copy(d[k]);});};"
         "var nested=function(d,kind){if(!d||typeof d!=='object')return null;var o={};"
         "if(kind==='operation'){if(own(d,'operator'))o.operator=copy(d.operator);"
         "if(own(d,'value'))o.value=copy(d.value);}"
         "else if(kind==='clause'){if(own(d,'package'))o.package=copy(d.package);"
         "if(own(d,'version'))o.version=d.version===null?null:nested(d.version,'operation');}"
         "else if(kind==='relation'){if(own(d,'relationship'))o.relationship=copy(d.relationship);"
         "var cs=[];if(Array.isArray(d.clauses))d.clauses.forEach(function(x){var c=nested(x,'clause');if(c)cs.push(c);});o.clauses=cs;}"
         "else if(kind==='address'){if(own(d,'address'))o.address=copy(d.address);"
         "if(own(d,'name'))o.name=copy(d.name);}return freeze(o);};"
         "var make=function(d,kind){d=d&&typeof d==='object'?d:{};var o=copy(d.values||{});"
         "var fields=copy(d.fields||{});var hasTags=Array.isArray(d.tags);"
         "var tags=hasTags?d.tags.slice():[];"
         "if(kind==='package'){o.getField=function(k){return own(fields,k)?fields[k]:undefined;};"
         "o.getRecord=function(){return own(d,'record')?d.record:undefined;};"
         "o.hasTag=function(k){return typeof k==='string'&&tags.indexOf(k)!==-1;};"
         "if(hasTags)o.tags=tags.slice();if(own(d,'applications'))o.applications=copy(d.applications);"
         "if(own(d,'purposes'))o.purposes=copy(d.purposes);"
         "if(d.author&&typeof d.author==='object')o.author=nested(d.author,'address');"
         "if(d.maintainer&&typeof d.maintainer==='object')o.maintainer=nested(d.maintainer,'address');"
         "o.relations=[];if(Array.isArray(d.relations))d.relations.forEach(function(x){var r=nested(x,'relation');if(r)o.relations.push(r);});}"
         "else if(kind==='source'){project(o,d,sourceKeys);o.getField=function(k){"
         "var sf=d.record&&typeof d.record==='object'?d.record:{};return own(sf,k)?sf[k]:undefined;};}"
         "if(d.source&&typeof d.source==='object')o.source=make(d.source,'source');"
         "return freeze(o);};"
         "var current=make(p.snapshot&&p.snapshot.package,'package');"
         "var source=p.snapshot&&p.snapshot.source?make(p.snapshot.source,'source'):null;"
         "var identity=p.snapshot&&p.snapshot.package&&p.snapshot.package.values?"
         "p.snapshot.package.values.id:null;"
         "var samePackage=function(k){return typeof k==='string'&&"
         "(k===identity||k===(p.snapshot.package&&p.snapshot.package.values&&p.snapshot.package.values.aptId)||"
         "k===(p.snapshot.package&&p.snapshot.package.values&&p.snapshot.package.values.dpkgId));};"
         "var safeReachable=function(value){if(typeof value!=='string')return false;"
         "var m=/^(https?):\\/\\/([^\\/?:#]+)(?::([0-9]+))?(?:[\\/]|$)/i.exec(value);"
         "if(!m)return false;var base=/^([a-z]+):\\/\\/([^:/]+)(?::([0-9]+))?/i.exec(p.origin);"
         "if(!base||m[1].toLowerCase()!==base[1].toLowerCase()||m[2].toLowerCase()!==base[2].toLowerCase())return false;"
         "var mp=m[3]?parseInt(m[3],10):(m[1].toLowerCase()==='https'?443:80);"
         "var bp=base[3]?parseInt(base[3],10):(base[1].toLowerCase()==='https'?443:80);return mp===bp;};"
         "var format=function(f,a){if(typeof f!=='string'||f.length>4096||!Array.isArray(a)||a.length>64)return undefined;"
         "var i=0,out='';for(var n=0;n<f.length;n++){var c=f.charAt(n);if(c!=='%'){out+=c;continue;}"
         "if(n+1>=f.length)return undefined;var next=f.charAt(++n);if(next==='%'){out+='%';continue;}"
         "if(next!=='@'||i>=a.length)return undefined;var v=a[i++];if(bad(v))v='';"
         "if(typeof v==='object')return undefined;out+=String(v);}return i===a.length?out:undefined;};"
         "var localize=function(k,v,t){if(typeof k!=='string'||k.length===0)return undefined;"
         "var tables=p.snapshot&&p.snapshot.localization||{};var table=typeof t==='string'&&tables[t]?tables[t]:tables[''];"
         "if(table&&own(table,k))return table[k];return typeof v==='string'&&v.length?v:k;};"
         "var bridge=function(action,value){try{if(window.webkit&&window.webkit.messageHandlers&&"
         "window.webkit.messageHandlers.cydiaDepictionBridge)window.webkit.messageHandlers.cydiaDepictionBridge.postMessage({"
         "action:action,value:value,generation:p.generation,binding:p.binding});}catch(e){}};"
         "var c={getPackageById:function(k){return samePackage(k)?current:null;},"
         "package:current,source:source,format:format,localize:localize,"
         "getLocaleIdentifier:function(){return p.snapshot&&p.snapshot.localeIdentifier||undefined;},"
         "getPreferredLanguages:function(){var x=p.snapshot&&p.snapshot.preferredLanguages;return Array.isArray(x)?x.slice():[];},"
         "supports:function(k){var x=p.snapshot&&p.snapshot.supports;return Array.isArray(x)&&typeof k==='string'&&x.indexOf(k)!==-1;},"
         "isReachable:function(u){bridge('isReachable',u);return safeReachable(u);}};"
         "try{Object.defineProperty(window,'cydia',{value:freeze(c),writable:false,configurable:false,enumerable:true});}catch(e){}})();";
    return [NSString stringWithFormat:@"%@%@%@", prefix, json, body];
}

- (void)installOnConfiguration:(WKWebViewConfiguration *)configuration {
    if (configuration == nil || [self isRevoked] || _installed)
        return;
    WKUserContentController *controller([configuration userContentController]);
    NSString *script([[self class] scriptForSnapshot:_snapshot origin:_origin
        packageIdentity:_packageIdentity generation:_generation bindingToken:_bindingToken]);
    if (controller == nil || script == nil)
        return;
    WKUserScript *userScript([[WKUserScript alloc] initWithSource:script
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]);
    [controller addUserScript:userScript];
    [controller addScriptMessageHandler:self name:@"cydiaDepictionBridge"];
    _installed = YES;
}

- (void)bindToWebView:(WKWebView *)webView {
    @synchronized (self) {
        _webView = webView;
    }
}

- (void)rotateForReloadOnConfiguration:(WKWebViewConfiguration *)configuration {
    if (configuration == nil)
        return;
    WKUserContentController *controller([configuration userContentController]);
    [controller removeScriptMessageHandlerForName:@"cydiaDepictionBridge"];
    [controller removeAllUserScripts];
    @synchronized (self) {
        _revoked = NO;
        ++_generation;
        if (_generation == 0)
            _generation = 1;
        _bindingToken = OwnedToken();
        _lastMessageAccepted = NO;
        _installed = NO;
    }
    [self installOnConfiguration:configuration];
}

- (void)revokeFromConfiguration:(WKWebViewConfiguration *)configuration {
    WKUserContentController *controller([configuration userContentController]);
    if (controller != nil) {
        [controller removeScriptMessageHandlerForName:@"cydiaDepictionBridge"];
        [controller removeAllUserScripts];
    }
    @synchronized (self) {
        _revoked = YES;
        ++_generation;
        _lastMessageAccepted = NO;
        _installed = NO;
        _webView = nil;
    }
}

+ (BOOL)allowlistedReachabilityURL:(NSURL *)URL origin:(NSURL *)origin {
    return SameOrigin(URL, origin);
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    BOOL accepted(NO);
    NSDictionary *body([message.body isKindOfClass:[NSDictionary class]] ?
        (NSDictionary *) message.body : nil);
    WKFrameInfo *frame([message frameInfo]);
    WKSecurityOrigin *securityOrigin([frame securityOrigin]);
    NSNumber *generation([body objectForKey:@"generation"]);
    NSString *binding([body objectForKey:@"binding"]);
    NSString *action([body objectForKey:@"action"]);
    NSString *value([body objectForKey:@"value"]);
    NSURL *valueURL([NSURL URLWithString:value]);
    NSString *protocol([[securityOrigin protocol] lowercaseString]);
    NSString *host([[securityOrigin host] lowercaseString]);
    NSInteger port([securityOrigin port]);
    BOOL originMatches([protocol isEqualToString:[[_origin scheme] lowercaseString]] &&
        [host isEqualToString:[[_origin host] lowercaseString]] &&
        port == EffectivePort(_origin));
    @synchronized (self) {
        accepted = !_revoked && _installed && [message name] != nil &&
            _webView != nil && [message webView] == _webView &&
            [frame isMainFrame] && originMatches &&
            [generation isKindOfClass:[NSNumber class]] &&
            [generation unsignedIntegerValue] == _generation &&
            [binding isKindOfClass:[NSString class]] &&
            [binding isEqualToString:_bindingToken] &&
            [action isEqualToString:@"isReachable"] &&
            [value isKindOfClass:[NSString class]] &&
            [[self class] allowlistedReachabilityURL:valueURL origin:_origin];
        _lastMessageAccepted = accepted;
    }
}

@end
