/* Cydia - iPhone UIKit Front-End for Debian APT
 * Private libapt-pkg acquire status adapters.
 */

#ifndef Cydia_DatabaseStatus_H
#define Cydia_DatabaseStatus_H

#include <Foundation/Foundation.h>

#include <apt-pkg/acquire.h>

#include <set>
#include <string>

@class Database;
@protocol FetchDelegate;
@protocol ProgressDelegate;

class CancelStatus :
    public pkgAcquireStatus
{
  private:
    bool cancelled_;

  public:
    CancelStatus();
    virtual bool MediaChange(std::string media, std::string drive);
    virtual void IMSHit(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner) = 0;
    virtual bool Pulse(pkgAcquire *Owner);
    bool WasCancelled() const;
};

class CydiaStatus :
    public CancelStatus
{
  private:
    __weak NSObject<ProgressDelegate> *delegate_;

  public:
    CydiaStatus();
    void setDelegate(NSObject<ProgressDelegate> *delegate);

    virtual void Fetch(pkgAcquire::ItemDesc &desc);
    virtual void Done(pkgAcquire::ItemDesc &desc);
    virtual void Fail(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner);
    virtual void Start();
    virtual void Stop();
};

class SourceStatus :
    public CancelStatus
{
  private:
    __weak NSObject<FetchDelegate> *delegate_;
    __weak Database *database_;
    std::set<std::string> fetches_;

  public:
    SourceStatus(NSObject<FetchDelegate> *delegate, Database *database);
    void Set(bool fetch, const std::string &uri);
    void Set(bool fetch, pkgAcquire::Item *item);
    void Log(const char *tag, pkgAcquire::Item *item);

    virtual void Fetch(pkgAcquire::ItemDesc &desc);
    virtual void Done(pkgAcquire::ItemDesc &desc);
    virtual void Fail(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner);
    virtual void Stop();
};

#endif //Cydia_DatabaseStatus_H
