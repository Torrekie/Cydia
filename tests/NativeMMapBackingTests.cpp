// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual vendored APT objects, including Darwin's heap fallback.
#include <apt-pkg/error.h>
#include <apt-pkg/mmap.h>

#include <cstdio>
#include <cstdlib>
#include <new>

namespace {
void *tracked = nullptr;
bool heapBacking = false;
unsigned frees = 0;
unsigned unmaps = 0;

void Require(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "mmap backing: %s\n", message);
        std::exit(1);
    }
}

void Track(DynamicMMap &map, bool heap) {
    Require(map.validData(), "allocation failed");
    tracked = map.Data();
    heapBacking = heap;
    frees = unmaps = 0;
}

void Check(bool heap) {
    tracked = nullptr;
    Require(frees == (heap ? 1u : 0u), "incorrect heap deallocation count");
    Require(unmaps == (heap ? 0u : 1u), "incorrect mapping deallocation count");
    Require(!_error->PendingError(), "APT reported an allocation error");
}
}

extern "C" void __real_free(void *);
extern "C" int __real_munmap(void *, size_t);

extern "C" void __wrap_free(void *address) {
    if (address == tracked && tracked != nullptr) {
        ++frees;
        // Report a mismatch without passing mapped storage to the allocator.
        if (!heapBacking)
            return;
    }
    __real_free(address);
}

extern "C" int __wrap_munmap(void *address, size_t length) {
    if (address == tracked && tracked != nullptr) {
        ++unmaps;
        // Report a mismatch without invalidating the allocator's VM records.
        if (heapBacking)
            return 0;
    }
    return __real_munmap(address, length);
}

int main() {
    {
        // Explicit Fallback selects the same calloc path used by Darwin when
        // a moveable cache cannot use Linux mremap.
        DynamicMMap map(MMap::Fallback, 4096, 0);
        Track(map, true);
    }
    Check(true);
    {
        DynamicMMap map(0, 4096, 0);
        Track(map, false);
    }
    Check(false);
    {
        DynamicMMap map(MMap::Fallback | MMap::Moveable, 4096, 4096, 8192);
        Require(map.validData(), "growable allocation failed");
        Require(map.RawAllocate(sizeof(DynamicMMap::Pool)) == 0,
                "pool reservation did not start at the backing base");
        auto *pool = new (map.Data()) DynamicMMap::Pool{};
        map.UsePools(*pool, 1);
        static_cast<unsigned char *>(map.Data())[4095] = 0x5a;
        Require(map.RawAllocate(4096) == sizeof(DynamicMMap::Pool),
                "growth did not preserve the allocation offset");
        Require(map.Size() == 4096 + sizeof(DynamicMMap::Pool),
                "growth did not retain the data size");
        const auto *bytes = static_cast<const unsigned char *>(map.Data());
        Require(bytes[4095] == 0x5a && bytes[4096] == 0 && bytes[8191] == 0,
                "growth did not preserve data and zero the new space");
        Track(map, true);
    }
    Check(true);
    std::puts("mmap backing: fallback, mapped, and grown fallback passed");
}
