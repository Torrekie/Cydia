/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/DatabaseStatus.h"

#include "Cydia/Database.h"

#include "Cydia/ProgressEvent.h"
#include "CyteKit/Localize.h"

#include <algorithm>
#include <iterator>
#include <vector>

#include <cstdio>

#include <apt-pkg/acquire-item.h>

#define lprintf(args...) fprintf(stderr, args)

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";

CancelStatus::CancelStatus() :
    cancelled_(false)
{
}

bool CancelStatus::MediaChange(std::string media, std::string drive) {
    return false;
}

void CancelStatus::IMSHit(pkgAcquire::ItemDesc &desc) {
    Done(desc);
}

bool CancelStatus::Pulse(pkgAcquire *Owner) {
    if (pkgAcquireStatus::Pulse(Owner) && Pulse_(Owner))
        return true;

    cancelled_ = true;
    return false;
}

bool CancelStatus::WasCancelled() const {
    return cancelled_;
}

CydiaStatus::CydiaStatus() :
    delegate_(nil)
{
}

void CydiaStatus::setDelegate(NSObject<ProgressDelegate> *delegate) {
    delegate_ = delegate;
}

void CydiaStatus::Fetch(pkgAcquire::ItemDesc &desc) {
    NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
    CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:UCLocalize("DOWNLOADING_"), name] ofType:kCydiaProgressEventTypeStatus forItemDesc:desc]);
    [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
}

void CydiaStatus::Done(pkgAcquire::ItemDesc &desc) {
    NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
    CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:Colon_, UCLocalize("DONE"), name] ofType:kCydiaProgressEventTypeStatus forItemDesc:desc]);
    [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
}

void CydiaStatus::Fail(pkgAcquire::ItemDesc &desc) {
    if (
        desc.Owner->Status == pkgAcquire::Item::StatIdle ||
        desc.Owner->Status == pkgAcquire::Item::StatDone
    )
        return;

    std::string &error(desc.Owner->ErrorText);
    if (error.empty())
        return;

    CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:kCydiaProgressEventTypeError forItemDesc:desc]);
    [delegate_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
}

bool CydiaStatus::Pulse_(pkgAcquire *Owner) {
    double percent(
        double(CurrentBytes + CurrentItems) /
        double(TotalBytes + TotalItems)
    );

    [delegate_ performSelectorOnMainThread:@selector(setProgressStatus:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithDouble:percent], @"Percent",

        [NSNumber numberWithDouble:CurrentBytes], @"Current",
        [NSNumber numberWithDouble:TotalBytes], @"Total",
        [NSNumber numberWithDouble:CurrentCPS], @"Speed",
    nil] waitUntilDone:YES];

    return ![delegate_ isProgressCancelled];
}

void CydiaStatus::Start() {
    pkgAcquireStatus::Start();
    [delegate_ performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:YES] waitUntilDone:YES];
}

void CydiaStatus::Stop() {
    pkgAcquireStatus::Stop();
    [delegate_ performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:NO] waitUntilDone:YES];
    [delegate_ performSelectorOnMainThread:@selector(setProgressStatus:) withObject:nil waitUntilDone:YES];
}

SourceStatus::SourceStatus(NSObject<FetchDelegate> *delegate, Database *database) :
    delegate_(delegate),
    database_(database)
{
}

void SourceStatus::Set(bool fetch, const std::string &uri) {
    if (fetch) {
        if (!fetches_.insert(uri).second)
            return;
    } else {
        if (fetches_.erase(uri) == 0)
            return;
    }

    auto slash(uri.rfind('/'));
    if (slash != std::string::npos)
        [database_ setFetch:fetch forURI:uri.substr(0, slash).c_str()];
}

void SourceStatus::Set(bool fetch, pkgAcquire::Item *item) {
    Set(fetch, item->DescURI());
}

void SourceStatus::Log(const char *tag, pkgAcquire::Item *item) {
}

void SourceStatus::Fetch(pkgAcquire::ItemDesc &desc) {
    Log("Fetch", desc.Owner);
    Set(true, desc.Owner);
}

void SourceStatus::Done(pkgAcquire::ItemDesc &desc) {
    Log("Done", desc.Owner);
    Set(false, desc.Owner);
}

void SourceStatus::Fail(pkgAcquire::ItemDesc &desc) {
    Log("Fail", desc.Owner);
    Set(false, desc.Owner);
}

bool SourceStatus::Pulse_(pkgAcquire *Owner) {
    std::set<std::string> fetches;
    for (pkgAcquire::ItemCIterator item(Owner->ItemsBegin()); item != Owner->ItemsEnd(); ++item) {
        bool fetch;
        if ((*item)->QueueCounter == 0)
            fetch = false;
        else switch ((*item)->Status) {
            case pkgAcquire::Item::StatFetching:
                fetches.insert((*item)->DescURI());
                fetch = true;
            break;

            default:
                fetch = false;
            break;
        }

        Log(fetch ? "Pulse<true>" : "Pulse<false>", *item);
        Set(fetch, *item);
    }

    std::vector<std::string> stops;
    std::set_difference(fetches_.begin(), fetches_.end(), fetches.begin(), fetches.end(), std::back_insert_iterator<std::vector<std::string>>(stops));
    for (std::vector<std::string>::const_iterator stop(stops.begin()); stop != stops.end(); ++stop)
        Set(false, *stop);

    return ![delegate_ isSourceCancelled];
}

void SourceStatus::Stop() {
    pkgAcquireStatus::Stop();
    [database_ resetFetch];
}
