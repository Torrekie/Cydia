#include "Cydia/PackageMetadata.hpp"

#include <algorithm>
#include <cstring>

Cytore::File<MetaValue> MetaFile_;

PackageValue *PackageFind(const char *name, size_t length, bool *fail) {
    SplitHash nhash = { hashlittle(name, length) };

    PackageValue *metadata;

    Cytore::Offset<PackageValue> *offset(&MetaFile_->packages_[nhash.u16[0]]);
    for (;; offset = &metadata->next_) { if (offset->IsNull()) {
        *offset = MetaFile_.New<PackageValue>(length + 1);
        metadata = &MetaFile_.Get(*offset);

        if (metadata == NULL) {
            if (fail != NULL)
                *fail = true;

            metadata = new PackageValue();
            memset(metadata, 0, sizeof(*metadata));
        }

        memcpy(metadata->name_, name, length);
        metadata->name_[length] = '\0';
        metadata->nhash_ = nhash.u16[1];
    } else {
        metadata = &MetaFile_.Get(*offset);
        if (metadata->nhash_ != nhash.u16[1])
            continue;
        if (strncmp(metadata->name_, name, length) != 0)
            continue;
        if (metadata->name_[length] != '\0')
            continue;
    } break; }

    return metadata;
}

void PackageImport(const void *key, const void *value, void *context) {
    bool &fail(*reinterpret_cast<bool *>(context));

    char buffer[1024];
    if (!CFStringGetCString(reinterpret_cast<CFStringRef>(key), buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        NSLog(@"failed to import package %@", key);
        return;
    }

    PackageValue *metadata(PackageFind(buffer, strlen(buffer), &fail));
    NSDictionary *package((__bridge NSDictionary *) value);

    if (NSNumber *subscribed = [package objectForKey:@"IsSubscribed"])
        if ([subscribed boolValue] && !metadata->subscribed_)
            metadata->subscribed_ = true;

    if (NSDate *date = [package objectForKey:@"FirstSeen"]) {
        time_t time([date timeIntervalSince1970]);
        if (metadata->first_ > time || metadata->first_ == 0)
            metadata->first_ = time;
    }

    NSDate *date([package objectForKey:@"LastSeen"]);
    NSString *version([package objectForKey:@"LastVersion"]);

    if (date != nil && version != nil) {
        time_t time([date timeIntervalSince1970]);
        if (metadata->last_ < time || metadata->last_ == 0)
            if (CFStringGetCString((__bridge CFStringRef) version, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                size_t length(strlen(buffer));
                uint16_t vhash(hashlittle(buffer, length));

                size_t capped(std::min<size_t>(8, length));
                char *latest(buffer + length - capped);

                strncpy(metadata->version_, latest, sizeof(metadata->version_));
                metadata->vhash_ = vhash;

                metadata->last_ = time;
            }
    }
}
