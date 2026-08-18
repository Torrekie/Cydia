#ifndef Cydia_Profile_HPP
#define Cydia_Profile_HPP

#include "CyteKit/UCPlatform.h"

#include <sys/time.h>

#include <cstdint>
#include <iomanip>
#include <iostream>
#include <vector>

class ProfileTime;
extern std::vector<ProfileTime *> times_;

static _finline uint64_t ProfileTimestamp() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000000 + tv.tv_usec;
}

class ProfileTime {
  private:
    const char *name_;
    uint64_t total_;
    uint64_t count_;

  public:
    ProfileTime(const char *name) :
        name_(name),
        total_(0),
        count_(0)
    {
        times_.push_back(this);
    }

    void AddTime(uint64_t time) {
        total_ += time;
        ++count_;
    }

    void Print() {
        if (total_ != 0)
            std::cerr << std::setw(7) << count_ << ", " << std::setw(8) << total_ << " : " << name_ << std::endl;
        total_ = 0;
        count_ = 0;
    }
};

class ProfileTimer {
  private:
    ProfileTime &time_;
    uint64_t start_;

  public:
    ProfileTimer(ProfileTime &time) :
        time_(time),
        start_(ProfileTimestamp())
    {
    }

    ~ProfileTimer() {
        time_.AddTime(ProfileTimestamp() - start_);
    }
};

void PrintTimes();

#if defined(ProfileTimes) && ProfileTimes
#ifndef _profile
#define _profile(name) { \
    static ProfileTime name(#name); \
    ProfileTimer _ ## name(name);
#define _end }
#endif
#else
#ifndef _profile
#define _profile(name) {
#define _end }
#endif
#endif

#endif//Cydia_Profile_HPP
