/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Refurbished work Copyright (C) 2026    Torrekie
 */

#ifndef Cydia_HomeSplitDisclosure_H
#define Cydia_HomeSplitDisclosure_H

@class UIButton;
@class UITableViewCell;

/* The split-row host delegates disclosure rendering to public UIKit APIs. */
UITableViewCell *CydiaHomeSystemDisclosureAccessory(void);
void CydiaHomeApplySplitButtonInsets(UIButton *button);

#endif
