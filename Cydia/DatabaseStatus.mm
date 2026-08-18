/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/DatabaseStatus.h"
#include "Cydia/DatabaseStatusInternal.hpp"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/Database.h"
#include "Cydia/ProgressEvent.h"
#include "CyteKit/Localize.h"

#include <apt-pkg/acquire-item.h>

#include <algorithm>
#include <iterator>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <cstdio>

#define lprintf(args...) fprintf(stderr, args)

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";

namespace CydiaAPT {
namespace Internal {

void *NativeAcquireStatus(CydiaAPT::AcquireStatus &status) {
    return &status.implementation().raw();
}

AcquireStatus::~AcquireStatus() {
}

void AcquireStatus::setDelegate(NSObject *delegate) {
    (void) delegate;
}

namespace {

class CancelStatus :
    public AcquireStatus,
    public pkgAcquireStatus
{
  private:
    bool cancelled_;

  protected:
    virtual bool Pulse_(pkgAcquire *owner) = 0;

  public:
    CancelStatus() : cancelled_(false) {
    }

    virtual pkgAcquireStatus &raw() {
        return *this;
    }

    virtual bool wasCancelled() const {
        return cancelled_;
    }

    virtual bool MediaChange(std::string media, std::string drive) {
        (void) media;
        (void) drive;
        return false;
    }

    virtual void IMSHit(pkgAcquire::ItemDesc &desc) {
        Done(desc);
    }

    virtual bool Pulse(pkgAcquire *owner) {
        if (pkgAcquireStatus::Pulse(owner) && Pulse_(owner))
            return true;
        cancelled_ = true;
        return false;
    }
};

class ProgressStatus : public CancelStatus {
  private:
    __weak NSObject<ProgressDelegate> *delegate_;

  public:
    ProgressStatus() : delegate_(nil) {
    }

    virtual void setDelegate(NSObject *delegate) {
        delegate_ = static_cast<NSObject<ProgressDelegate> *>(delegate);
    }

    virtual void Fetch(pkgAcquire::ItemDesc &desc) {
        NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
        AcquireItemData item{desc.Description, desc.URI};
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:UCLocalize("DOWNLOADING_"), name] ofType:kCydiaProgressEventTypeStatus forItem:item]);
        [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual void Done(pkgAcquire::ItemDesc &desc) {
        NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
        AcquireItemData item{desc.Description, desc.URI};
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:Colon_, UCLocalize("DONE"), name] ofType:kCydiaProgressEventTypeStatus forItem:item]);
        [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual void Fail(pkgAcquire::ItemDesc &desc) {
        if (desc.Owner->Status == pkgAcquire::Item::StatIdle ||
            desc.Owner->Status == pkgAcquire::Item::StatDone)
            return;

        std::string &error(desc.Owner->ErrorText);
        if (error.empty())
            return;

        AcquireItemData item{desc.Description, desc.URI};
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:kCydiaProgressEventTypeError forItem:item]);
        [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual bool Pulse_(pkgAcquire *owner) {
        (void) owner;
        double percent(double(CurrentBytes + CurrentItems) / double(TotalBytes + TotalItems));
        [delegate_ performSelectorOnMainThread:@selector(setProgressStatus:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithDouble:percent], @"Percent",
            [NSNumber numberWithDouble:CurrentBytes], @"Current",
            [NSNumber numberWithDouble:TotalBytes], @"Total",
            [NSNumber numberWithDouble:CurrentCPS], @"Speed",
        nil] waitUntilDone:YES];
        return ![delegate_ isProgressCancelled];
    }

    virtual void Start() {
        pkgAcquireStatus::Start();
        [delegate_ performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:YES] waitUntilDone:YES];
    }

    virtual void Stop() {
        pkgAcquireStatus::Stop();
        [delegate_ performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:NO] waitUntilDone:YES];
        [delegate_ performSelectorOnMainThread:@selector(setProgressStatus:) withObject:nil waitUntilDone:YES];
    }
};

class SourceStatus : public CancelStatus {
  private:
    __weak NSObject<FetchDelegate> *delegate_;
    __weak Database *database_;
    std::set<std::string> fetches_;

    void Set(bool fetch, const std::string &uri) {
        if (fetch) {
            if (!fetches_.insert(uri).second)
                return;
        } else if (fetches_.erase(uri) == 0)
            return;

        const std::string::size_type slash(uri.rfind('/'));
        if (slash != std::string::npos)
            [database_ setFetch:fetch forURI:uri.substr(0, slash).c_str()];
    }

    void Set(bool fetch, pkgAcquire::Item *item) {
        Set(fetch, item->DescURI());
    }

  public:
    SourceStatus(NSObject<FetchDelegate> *delegate, Database *database) :
        delegate_(delegate),
        database_(database)
    {
    }

    virtual void Fetch(pkgAcquire::ItemDesc &desc) {
        Set(true, desc.Owner);
    }

    virtual void Done(pkgAcquire::ItemDesc &desc) {
        Set(false, desc.Owner);
    }

    virtual void Fail(pkgAcquire::ItemDesc &desc) {
        Set(false, desc.Owner);
    }

    virtual bool Pulse_(pkgAcquire *owner) {
        std::set<std::string> fetches;
        for (pkgAcquire::ItemCIterator item(owner->ItemsBegin()); item != owner->ItemsEnd(); ++item) {
            bool fetch(false);
            if ((*item)->QueueCounter != 0 && (*item)->Status == pkgAcquire::Item::StatFetching) {
                fetches.insert((*item)->DescURI());
                fetch = true;
            }
            Set(fetch, *item);
        }

        std::vector<std::string> stops;
        std::set_difference(fetches_.begin(), fetches_.end(), fetches.begin(), fetches.end(), std::back_insert_iterator<std::vector<std::string> >(stops));
        for (std::vector<std::string>::const_iterator stop(stops.begin()); stop != stops.end(); ++stop)
            Set(false, *stop);
        return ![delegate_ isSourceCancelled];
    }

    virtual void Stop() {
        pkgAcquireStatus::Stop();
        [database_ resetFetch];
    }
};

} // namespace

std::unique_ptr<AcquireStatus> CreateProgressStatus() {
    return std::unique_ptr<AcquireStatus>(new ProgressStatus());
}

std::unique_ptr<AcquireStatus> CreateSourceStatus(NSObject *delegate, Database *database) {
    return std::unique_ptr<AcquireStatus>(new SourceStatus(static_cast<NSObject<FetchDelegate> *>(delegate), database));
}

} // namespace Internal

AcquireStatus::AcquireStatus(std::unique_ptr<Internal::AcquireStatus> implementation) :
    implementation_(std::move(implementation))
{
}

AcquireStatus::~AcquireStatus() {
}

Internal::AcquireStatus &AcquireStatus::implementation() {
    return *implementation_;
}

bool AcquireStatus::wasCancelled() const {
    return implementation_->wasCancelled();
}

ProgressStatus::ProgressStatus() :
    AcquireStatus(Internal::CreateProgressStatus())
{
}

void ProgressStatus::setDelegate(NSObject<ProgressDelegate> *delegate) {
    implementation().setDelegate(delegate);
}

SourceStatus::SourceStatus(NSObject<FetchDelegate> *delegate, Database *database) :
    AcquireStatus(Internal::CreateSourceStatus(delegate, database))
{
}

} // namespace CydiaAPT
