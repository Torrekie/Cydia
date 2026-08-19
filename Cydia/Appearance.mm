/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#include "Cydia/Appearance.h"

UIColor *whiteIfNotDark(bool white) {
    return white ? UIColor.cydiaBackgroundColor : UIColor.cydiaLabelColor;
}
