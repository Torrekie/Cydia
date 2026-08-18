#include "Cydia/PackageMetadata.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <new>

Cytore::File<MetaValue> MetaFile_;

static PackageValue *PackageAllocate_(size_t length) {
    if (length > std::numeric_limits<size_t>::max() - sizeof(PackageValue) - 1)
        return NULL;

    void *storage(::operator new(sizeof(PackageValue) + length + 1, std::nothrow));
    if (storage == NULL)
        return NULL;

    return new (storage) PackageValue();
}

PackageValue *PackageFind(const char *name, size_t length, bool *fail) {
    SplitHash nhash = { hashlittle(name, length) };

    Cytore::Offset<PackageValue> *offset(&MetaFile_->packages_[nhash.u16[0]]);
    for (;;) {
        PackageValue *metadata;
        if (offset->IsNull()) {
            *offset = MetaFile_.New<PackageValue>(length + 1);
            if (offset->IsNull()) {
                // Keep running with transient metadata when the persistent file
                // cannot grow, while telling import callers not to trust it.
                metadata = PackageAllocate_(length);
                if (fail != NULL)
                    *fail = true;
                if (metadata == NULL)
                    return NULL;
            } else {
                metadata = &MetaFile_.Get(*offset);
            }

            memcpy(metadata->name_, name, length);
            metadata->name_[length] = '\0';
            metadata->nhash_ = nhash.u16[1];
            return metadata;
        }

        metadata = &MetaFile_.Get(*offset);
        if (metadata->nhash_ == nhash.u16[1] &&
            strncmp(metadata->name_, name, length) == 0 &&
            metadata->name_[length] == '\0')
            return metadata;

        offset = &metadata->next_;
    }
}

void PackageImport(const void *key, const void *value, void *context) {
    bool &fail(*reinterpret_cast<bool *>(context));

    char buffer[1024];
    if (!CFStringGetCString(reinterpret_cast<CFStringRef>(key), buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        NSLog(@"failed to import package %@", key);
        return;
    }

    PackageValue *metadata(PackageFind(buffer, strlen(buffer), &fail));
    if (metadata == NULL) {
        fail = true;
        NSLog(@"failed to allocate metadata for package %@", key);
        return;
    }

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
