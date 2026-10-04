/* Cydia Refurbished native FAQ controller.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_FAQController_H
#define Cydia_FAQController_H

#include "Cydia/HomeGuideController.h"

NS_ASSUME_NONNULL_BEGIN

/* Bundled first-party questions and answer pages; old native identifiers are
 * retained as aliases and every child opens at its corresponding anchor. */
@interface FAQController : HomeGuideController

- (instancetype)init;
- (nullable instancetype)initWithQuestionIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_FAQController_H
