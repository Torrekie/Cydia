#ifndef Cydia_PackageMetadata_HPP
#define Cydia_PackageMetadata_HPP

#include "CyteKit/UCPlatform.h"

#include <vector>
#include <Cytore.hpp>

#include <Foundation/Foundation.h>

#include <cstddef>
#include <cstdint>

extern "C" uint32_t hashlittle(const void *key, size_t length, uint32_t initval = 0);

union SplitHash {
    uint32_t u32;
    uint16_t u16[2];
};

struct PackageValue :
    Cytore::Block
{
    Cytore::Offset<PackageValue> next_;

    uint32_t index_ : 23;
    uint32_t subscribed_ : 1;
    uint32_t : 8;

    int32_t first_;
    int32_t last_;

    uint16_t vhash_;
    uint16_t nhash_;

    char version_[8];
    char name_[];
} _packed;

struct MetaValue :
    Cytore::Block
{
    uint32_t active_;
    Cytore::Offset<PackageValue> packages_[1 << 16];
} _packed;

extern Cytore::File<MetaValue> MetaFile_;

PackageValue *PackageFind(const char *name, size_t length, bool *fail = NULL);
void PackageImport(const void *key, const void *value, void *context);

#endif//Cydia_PackageMetadata_HPP
