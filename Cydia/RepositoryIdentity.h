/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RepositoryIdentity_H
#define Cydia_RepositoryIdentity_H
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *CydiaRepositoryUserAgent(void);
FOUNDATION_EXPORT NSString *CydiaRepositoryDownloadUserAgent(void);
FOUNDATION_EXPORT NSString *CydiaRepositoryUserAgentForIdentity(NSString *identity, NSString *customUserAgent, BOOL download);
FOUNDATION_EXPORT BOOL CydiaValidCustomRepositoryUserAgent(NSString *value);
NS_ASSUME_NONNULL_END
#endif
